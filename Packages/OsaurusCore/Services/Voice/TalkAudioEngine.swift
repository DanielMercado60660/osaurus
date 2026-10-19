import AVFoundation
import CoreAudio
import Foundation

/// Talk-only capture/render graph. VPIO uses one duplex engine; when a selected
/// input cannot share the default output with AEC, capture gets its own engine.
final class TalkAudioEngine: TTSStreamPlayer, @unchecked Sendable {
    private let benchmark: TalkBenchmarkAudio? = TalkBenchmarkConfiguration.inputRequested ? TalkBenchmarkAudio() : nil
    var usesFileInput: Bool { benchmark != nil }
    var isBenchmarkRendering: Bool { benchmark?.isRendering ?? false }

    func playInput(_ url: URL, leadingMs: Int, trailingMs: Int) async throws {
        guard let benchmark else { throw TalkBenchmarkError("File input is not enabled") }
        try await benchmark.playInput(url, leadingMs: leadingMs, trailingMs: trailingMs)
    }

    private let queue = DispatchQueue(label: "ai.osaurus.talk.audio", qos: .userInitiated)
    private var engine: AVAudioEngine?
    private var captureEngine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000,
                                       channels: 1, interleaved: false)!
    private let captureFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                              channels: 1, interleaved: false)!
    private var inputFormat: AVAudioFormat?
    private var generation: UInt64 = 0
    private var graphGeneration: UInt64 = 0
    private var meter = TTSOutputMeter()
    private var lastMeterTime: TimeInterval = 0
    private var levelHandler: (@Sendable (Float) -> Void)?
    private var observers: [NSObjectProtocol] = []
    private lazy var recovery = TalkRouteRecovery(queue: queue)
    private var wantsPlayback = false
    private struct Pending {
        let id: UUID
        let samples: [Float]
        let completion: @Sendable (Bool) -> Void
    }
    private var pending: [Pending] = []

    func setOutputLevelHandler(_ handler: @escaping @Sendable (Float) -> Void) {
        if let benchmark { benchmark.setLevel(handler); return }
        queue.async { self.levelHandler = handler }
    }

    func start(voiceProcessing: Bool, deviceID: AudioDeviceID?,
               capture: @escaping @Sendable ([Float], Float) -> Void,
               routeChanged: @escaping @Sendable () -> Void,
               aecChanged: @escaping @Sendable (Bool) -> Void = { _ in }) async throws -> (AVAudioFormat, Bool) {
        if let benchmark {
            _ = try TalkBenchmarkConfiguration.parse(ProcessInfo.processInfo.environment)
            benchmark.start(capture: capture)
            return (captureFormat, false)
        }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let aec = try self.configureWithFallback(requested: voiceProcessing, deviceID: deviceID, capture: capture)
                    self.observeRoute(aec: aec, deviceID: deviceID, capture: capture,
                                      failed: routeChanged, aecChanged: aecChanged)
                    continuation.resume(returning: (self.captureFormat, aec))
                } catch {
                    self.shutdownLocked()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func defaultInputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != 0 else { return nil }
        return device
    }

    private func configureWithFallback(requested: Bool, deviceID: AudioDeviceID?,
                                       capture: @escaping @Sendable ([Float], Float) -> Void) throws -> Bool {
        // A non-default input would redirect VPIO's shared IO unit. Separate
        // capture/render engines preserve the default speaker without an aggregate.
        let useAEC = TalkAudioPolicy.canUseAEC(requested: requested, selectedInput: deviceID,
                                               defaultInput: Self.defaultInputDevice())
        if useAEC {
            do { try configure(aec: true, deviceID: deviceID, capture: capture); return true }
            catch { discardGraph() }
        }
        try configure(aec: false, deviceID: deviceID, capture: capture)
        return false
    }

    private func configure(aec: Bool, deviceID: AudioDeviceID?,
                           capture: @escaping @Sendable ([Float], Float) -> Void) throws {
        let output = AVAudioEngine()
        let inputEngine = aec ? output : AVAudioEngine()
        engine = output
        captureEngine = inputEngine
        let input = inputEngine.inputNode
        // Enabling VPIO can recreate the IO unit, so select the device afterwards.
        if aec { try input.setVoiceProcessingEnabled(true) }
        if var deviceID, let unit = input.audioUnit {
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global, 0, &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
            guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        }
        let initialFormat = input.outputFormat(forBus: 0)
        guard initialFormat.sampleRate > 0, initialFormat.channelCount > 0 else {
            throw TalkBenchmarkError("The selected microphone is unavailable.")
        }
        let player = AVAudioPlayerNode()
        self.player = player
        output.attach(player)
        output.connect(player, to: output.mainMixerNode, format: format)
        let resampler = TalkCaptureResampler()
        input.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in
            // Sample rate is resolved from each actual buffer, including VPIO's
            // startup renegotiation. The worker always receives mono 16 kHz.
            let samples = resampler.convert(buffer)
            guard !samples.isEmpty else { return }
            let rms = samples.withUnsafeBufferPointer { TTSOutputMeter.rms($0) }
            capture(samples, min(1, rms * 10))
        }
        let graph = graphGeneration
        output.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
            let rms = TTSOutputMeter.rms(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
            self?.queue.async { [weak self] in
                guard let self, self.graphGeneration == graph else { return }
                let now = ProcessInfo.processInfo.systemUptime
                guard now - self.lastMeterTime >= 1.0 / 30 else { return }
                self.lastMeterTime = now
                self.levelHandler?(self.meter.update(rms: rms))
            }
        }
        output.prepare()
        try output.start()
        if inputEngine !== output { inputEngine.prepare(); try inputEngine.start() }
        inputFormat = input.outputFormat(forBus: 0)
        if wantsPlayback { player.play() }
    }

    private func observeRoute(aec: Bool, deviceID: AudioDeviceID?,
                              capture: @escaping @Sendable ([Float], Float) -> Void,
                              failed: @escaping @Sendable () -> Void,
                              aecChanged: @escaping @Sendable (Bool) -> Void) {
        let graph = graphGeneration
        let graphs = captureEngine === engine ? [engine] : [engine, captureEngine]
        for object in graphs.compactMap({ $0 }) {
            observers.append(NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                object: object, queue: nil) { [weak self] _ in
                self?.queue.async { [weak self] in
                    guard let self, self.graphGeneration == graph else { return }
                    let current = self.captureEngine?.inputNode.outputFormat(forBus: 0)
                    guard TalkAudioPolicy.needsRebuild(running: self.engine?.isRunning == true && self.captureEngine?.isRunning == true,
                                                       inputUnchanged: current == self.inputFormat) else { return }
                    self.recovery.request { [weak self] in
                        guard let self, self.graphGeneration == graph else { return }
                        do {
                            self.discardGraph()
                            let nextAEC = try self.configureWithFallback(requested: aec, deviceID: deviceID, capture: capture)
                            self.observeRoute(aec: nextAEC, deviceID: deviceID, capture: capture,
                                              failed: failed, aecChanged: aecChanged)
                            // Old node callbacks are invalid, but reply generation
                            // and pending PCM survive. Replay each outstanding buffer once.
                            for item in self.pending { self.schedule(item) }
                            aecChanged(nextAEC)
                        } catch { self.shutdownLocked(); failed() }
                    }
                }
            })
        }
    }

    func prepareAndPlay() async throws {
        if let benchmark { try benchmark.prepare(); return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                guard let player = self.player, self.engine != nil else {
                    continuation.resume(throwing: TalkBenchmarkError("Talk audio is unavailable.")); return
                }
                self.wantsPlayback = true
                // A stopped graph with a pending rebuild will resume this player.
                if self.engine?.isRunning == true { player.play() }
                continuation.resume()
            }
        }
    }

    func schedulePlayed(samples: [Float], completion: @escaping @Sendable (Bool) -> Void) {
        if let benchmark { benchmark.schedule(samples, completion: completion); return }
        queue.async {
            guard self.engine != nil, self.wantsPlayback else { completion(false); return }
            let item = Pending(id: UUID(), samples: samples, completion: completion)
            self.pending.append(item)
            if self.engine?.isRunning == true { self.schedule(item) }
        }
    }

    private func schedule(_ item: Pending) {
        guard let player,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(item.samples.count)),
              let data = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(item.samples.count)
        item.samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress { data.update(from: base, count: item.samples.count) }
        }
        let generation = generation
        let graph = graphGeneration
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            self?.queue.async { [weak self] in
                guard let self, self.generation == generation, self.graphGeneration == graph,
                      self.engine?.isRunning == true,
                      let index = self.pending.firstIndex(where: { $0.id == item.id }) else { return }
                self.pending.remove(at: index).completion(true)
            }
        }
    }

    func cancelPlayback() {
        if let benchmark { benchmark.cancel(); return }
        queue.async { self.cancelLocked() }
    }

    private func cancelLocked() {
        generation += 1
        wantsPlayback = false
        player?.stop()
        player?.reset()
        let cancelled = pending
        pending.removeAll()
        for item in cancelled { item.completion(false) }
        _ = meter.update(rms: 0)
        levelHandler?(0)
    }

    func shutdown() async {
        if let benchmark { benchmark.shutdown(); return }
        await withCheckedContinuation { continuation in
            queue.async { self.shutdownLocked(); continuation.resume() }
        }
    }

    private func discardGraph() {
        graphGeneration += 1
        recovery.cancel()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        player?.stop()
        captureEngine?.stop()
        engine?.stop()
        captureEngine = nil
        engine = nil
        player = nil
    }

    private func shutdownLocked() { cancelLocked(); discardGraph() }
}

/// Owned by one input tap. Recreates the converter only when the buffer's real
/// format changes; never feeds the same input twice to AVAudioConverter.
final class TalkCaptureResampler: @unchecked Sendable {
    private var source: AVAudioFormat?
    private var converter: AVAudioConverter?
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                       channels: 1, interleaved: false)!
    func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard buffer.frameLength > 0, buffer.format.sampleRate > 0 else { return [] }
        if source != buffer.format {
            source = buffer.format
            converter = AVAudioConverter(from: buffer.format, to: target)
        }
        guard let converter,
              let output = AVAudioPCMBuffer(pcmFormat: target,
                frameCapacity: AVAudioFrameCount(ceil(Double(buffer.frameLength) * 16_000 / buffer.format.sampleRate)) + 32) else { return [] }
        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let data = output.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: data, count: Int(output.frameLength)))
    }
}
