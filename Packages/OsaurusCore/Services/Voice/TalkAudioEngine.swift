import AVFoundation
import CoreAudio
import Foundation

/// Talk-only duplex graph: voice processing sees the very same mixer output
/// that renders TTS. Legacy dictation and read-aloud retain their own engines.
final class TalkAudioEngine: TTSStreamPlayer, @unchecked Sendable {
    private let queue = DispatchQueue(label: "ai.osaurus.talk.audio", qos: .userInitiated)
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000,
                                       channels: 1, interleaved: false)!
    private var generation: UInt64 = 0
    private var meter = TTSOutputMeter()
    private var lastMeterTime: TimeInterval = 0
    private var levelHandler: (@Sendable (Float) -> Void)?
    private var observer: NSObjectProtocol?

    func setOutputLevelHandler(_ handler: @escaping @Sendable (Float) -> Void) {
        queue.sync { levelHandler = handler }
    }

    func start(voiceProcessing: Bool, deviceID: AudioDeviceID?,
               capture: @escaping @Sendable ([Float], Float) -> Void,
               routeChanged: @escaping @Sendable () -> Void) async throws -> (AVAudioFormat, Bool) {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    if voiceProcessing {
                        do {
                            let format = try self.configure(aec: true, deviceID: deviceID, capture: capture)
                            self.observeRoute(routeChanged)
                            continuation.resume(returning: (format, true))
                            return
                        } catch {
                            // A failed voice-processing graph must be discarded before retrying.
                            self.shutdownLocked()
                        }
                    }
                    let format = try self.configure(aec: false, deviceID: deviceID, capture: capture)
                    self.observeRoute(routeChanged)
                    continuation.resume(returning: (format, false))
                } catch {
                    self.shutdownLocked()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func configure(aec: Bool, deviceID: AudioDeviceID?,
                           capture: @escaping @Sendable ([Float], Float) -> Void) throws -> AVAudioFormat {
        let engine = AVAudioEngine()
        self.engine = engine
        let input = engine.inputNode
        if var deviceID, let unit = input.audioUnit {
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                              kAudioUnitScope_Global, 0, &deviceID,
                                              UInt32(MemoryLayout<AudioDeviceID>.size))
            guard status == noErr else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
            }
        }
        if aec { try input.setVoiceProcessingEnabled(true) }
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw NSError(domain: "TalkAudioEngine", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "The selected microphone is unavailable."])
        }
        let player = AVAudioPlayerNode()
        self.player = player
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, _ in
            guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
            let samples = Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
            let rms = samples.withUnsafeBufferPointer { TTSOutputMeter.rms($0) }
            capture(samples, min(1, rms * 10))
        }
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
            let rms = TTSOutputMeter.rms(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
            self?.queue.async { [weak self] in
                guard let self else { return }
                let now = ProcessInfo.processInfo.systemUptime
                guard now - self.lastMeterTime >= 1.0 / 30 else { return }
                self.lastMeterTime = now
                self.levelHandler?(self.meter.update(rms: rms))
            }
        }
        engine.prepare()
        try engine.start()
        // The worker receives one channel from the tap, even for multichannel devices.
        return AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inputFormat.sampleRate,
                             channels: 1, interleaved: false)!
    }

    private func observeRoute(_ changed: @escaping @Sendable () -> Void) {
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                          object: engine, queue: nil) { _ in changed() }
    }

    func prepareAndPlay() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                guard let engine = self.engine, engine.isRunning, let player = self.player else {
                    continuation.resume(throwing: NSError(domain: "TalkAudioEngine", code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "Talk audio stopped. Restart talk mode after changing audio devices."]))
                    return
                }
                player.play()
                continuation.resume()
            }
        }
    }

    func schedulePlayed(samples: [Float], completion: @escaping @Sendable (Bool) -> Void) {
        queue.async {
            guard let player = self.player, player.isPlaying,
                  let buffer = AVAudioPCMBuffer(pcmFormat: self.format, frameCapacity: AVAudioFrameCount(samples.count)),
                  let data = buffer.floatChannelData?[0] else { completion(false); return }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { source in
                if let base = source.baseAddress { data.update(from: base, count: samples.count) }
            }
            let generation = self.generation
            player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak owner = self] _ in
                guard let owner else { completion(false); return }
                owner.queue.async { [weak owner] in completion(owner?.generation == generation) }
            }
        }
    }

    func cancelPlayback() {
        queue.sync {
            generation += 1
            player?.stop()
            player?.reset()
            _ = meter.update(rms: 0)
            levelHandler?(0)
            // Keep microphone capture and the AEC graph running across barge-in.
        }
    }

    func shutdown() async {
        await withCheckedContinuation { continuation in
            queue.async { self.shutdownLocked(); continuation.resume() }
        }
    }

    private func shutdownLocked() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        generation += 1
        player?.stop()
        engine?.stop()
        engine = nil
        player = nil
        levelHandler?(0)
    }
}
