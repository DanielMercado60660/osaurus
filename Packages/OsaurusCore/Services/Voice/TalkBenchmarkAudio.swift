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
    private var generation = 0
    private var playing = false
    private var pending: [UUID: @Sendable (Bool) -> Void] = [:]
    private var outputEnd = DispatchTime.now()
    private var meter = TTSOutputMeter()
    private var level: (@Sendable (Float) -> Void)?

    func start(capture: @escaping @Sendable ([Float], Float) -> Void) {
        queue.sync {
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

    var isRendering: Bool { queue.sync { playing && !pending.isEmpty } }

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
            let epoch = self.generation
            let id = UUID()
            self.pending[id] = completion
            let start = max(self.outputEnd.uptimeNanoseconds, DispatchTime.now().uptimeNanoseconds)
            self.outputEnd = DispatchTime(uptimeNanoseconds: start + UInt64(Double(samples.count) / 24_000 * 1_000_000_000))
            let rms = samples.withUnsafeBufferPointer { TTSOutputMeter.rms($0) }
            self.queue.asyncAfter(deadline: DispatchTime(uptimeNanoseconds: start)) {
                guard self.generation == epoch else { return }
                self.level?(self.meter.update(rms: rms))
            }
            self.queue.asyncAfter(deadline: self.outputEnd) {
                guard self.generation == epoch, let callback = self.pending.removeValue(forKey: id) else { return }
                callback(true)
                if self.pending.isEmpty { self.level?(0) }
            }
        }
    }
    private func cancelLocked() {
        generation += 1
        playing = false
        outputEnd = .now()
        let callbacks = pending.values
        pending.removeAll()
        meter = TTSOutputMeter()
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
