import AVFoundation
import Foundation

/// No AVAudioEngine/inputNode/outputNode is created in the benchmark path.
/// Capture and null rendering share a serial queue, like the real duplex graph.
final class TalkBenchmarkAudio: @unchecked Sendable {
    private let queue = DispatchQueue(label: "ai.osaurus.talk.benchmark.audio")
    private var timer: DispatchSourceTimer?
    private var samples: [Float] = []
    private var pacer: TalkWAVFramePacer?
    private var frame = 0
    private var inputDone: CheckedContinuation<Void, Error>?
    private var playing = false
    private struct Pending {
        let samples: [Float]
        var offset = 0
        let completion: @Sendable (Bool) -> Void
    }
    private var pending: [Pending] = []
    private var paused = false
    private var echoMixer: TalkBenchmarkEchoMixer?
    private var userOverlap = false
    private var rawLevel: (@Sendable (Float) -> Void)?
    private var meter = TTSOutputMeter()
    private var level: (@Sendable (Float) -> Void)?

    func start(echo: TalkBenchmarkEchoConfiguration? = nil, capture: @escaping @Sendable ([Float], Float) -> Void) {
        queue.sync {
            echoMixer = echo.map(TalkBenchmarkEchoMixer.init)
            let timer = DispatchSource.makeTimerSource(queue: queue)
            let interval = DispatchTimeInterval.milliseconds(TalkWAVFramePacer.frameMilliseconds)
            timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(1))
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                var chunk = [Float](repeating: 0, count: TalkWAVFramePacer.frameSamples)
                if let pacer = self.pacer {
                    chunk = pacer.frame(self.frame, samples: self.samples)
                    self.frame += 1
                    if self.frame == pacer.frameCount {
                        self.pacer = nil
                        self.samples = []
                        self.inputDone?.resume()
                        self.inputDone = nil
                    }
                }
                if chunk.contains(where: { $0 != 0 }) { self.userOverlap = true }
                let rendered = self.renderFrame()
                if var mixer = self.echoMixer {
                    chunk = mixer.mix(input: chunk, output24k: rendered)
                    self.echoMixer = mixer
                }
                capture(chunk, min(1, chunk.withUnsafeBufferPointer { TTSOutputMeter.rms($0) } * 10))
            }
            self.timer = timer
            timer.resume()
        }
    }

    func playInput(_ url: URL, leadingMs: Int, trailingMs: Int) async throws {
        // File decoding never blocks the main actor or capture clock.
        let samples = try await Task.detached(priority: .userInitiated) {
            let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
            guard url.pathExtension.lowercased() == "wav", file.processingFormat.sampleRate == 16_000,
                  file.processingFormat.channelCount == 1, file.length > 0, file.length <= 16_000 * 120,
                  let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
                throw TalkBenchmarkError("Input must be a nonempty 16 kHz mono WAV, at most 120 seconds: \(url.path)")
            }
            try file.read(into: buffer)
            guard let data = buffer.floatChannelData?[0] else { throw TalkBenchmarkError("Cannot decode \(url.path)") }
            return Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
        }.value
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
                queue.async {
                    guard self.timer != nil, self.inputDone == nil else {
                        done.resume(throwing: TalkBenchmarkError("Benchmark capture stopped or input overlaps")); return
                    }
                    self.samples = samples
                    self.pacer = TalkWAVFramePacer(sampleCount: samples.count, leadingSilenceMs: leadingMs, trailingSilenceMs: trailingMs)
                    self.frame = 0
                    self.inputDone = done
                }
            }
        } onCancel: { self.shutdown() }
    }

    var isRendering: Bool { queue.sync { playing && !paused && !pending.isEmpty } }
    var hasUserOverlap: Bool { queue.sync { userOverlap } }
    var echoMixedSamples: Int { queue.sync { echoMixer?.mixedSamples ?? 0 } }
    func resetUserOverlap() { queue.sync { userOverlap = false } }
    func setRawLevel(_ handler: @escaping @Sendable (Float) -> Void) { queue.sync { rawLevel = handler } }
    func pause() { queue.sync { paused = true; rawLevel?(0); level?(0) } }
    func resume() { queue.sync { paused = false } }

    func setLevel(_ handler: @escaping @Sendable (Float) -> Void) { queue.sync { level = handler } }
    func prepare() throws {
        try queue.sync {
            guard timer != nil else { throw TalkBenchmarkError("Benchmark audio stopped") }
            playing = true
        }
    }
    func schedule(_ samples: [Float], completion: @escaping @Sendable (Bool) -> Void) {
        queue.async {
            guard self.playing else { completion(false); return }
            self.pending.append(Pending(samples: samples, completion: completion))
        }
    }
    private func renderFrame() -> [Float] {
        var rendered: [Float] = []
        var completed: [@Sendable (Bool) -> Void] = []
        if playing && !paused {
            while rendered.count < 480 && !pending.isEmpty {
                let count = min(480 - rendered.count, pending[0].samples.count - pending[0].offset)
                let start = pending[0].offset
                rendered.append(contentsOf: pending[0].samples[start..<(start + count)])
                pending[0].offset += count
                if pending[0].offset == pending[0].samples.count {
                    completed.append(pending.removeFirst().completion)
                }
            }
        }
        rendered.append(contentsOf: repeatElement(Float(0), count: 480 - rendered.count))
        let rms = rendered.withUnsafeBufferPointer { TTSOutputMeter.rms($0) }
        rawLevel?(rms)
        level?(rms == 0 ? 0 : meter.update(rms: rms))
        for callback in completed { callback(true) }
        return rendered
    }
    private func cancelLocked() {
        playing = false
        paused = false
        let callbacks = pending.map(\.completion)
        pending.removeAll()
        meter = TTSOutputMeter()
        rawLevel?(0)
        level?(0)
        for callback in callbacks { callback(false) }
    }
    func cancel() { queue.sync { cancelLocked() } }
    func shutdown() {
        queue.sync {
            timer?.cancel(); timer = nil
            pacer = nil; samples = []
            inputDone?.resume(throwing: CancellationError()); inputDone = nil
            cancelLocked()
        }
    }
}
