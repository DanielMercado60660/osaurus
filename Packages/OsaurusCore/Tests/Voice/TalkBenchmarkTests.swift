import AVFoundation
import Foundation
import Testing
@testable import OsaurusCore

struct TalkBenchmarkTests {
    @Test func absentInputIsInert() throws {
        #expect(try TalkBenchmarkConfiguration.parse([:]) == nil)
        #expect(try TalkBenchmarkConfiguration.parse(["OSAURUS_TALK_AUTOSTART": "bad"]) == nil)
    }

    @Test func defaultsAndAgentSelection() throws {
        let config = try #require(try TalkBenchmarkConfiguration.parse(["OSAURUS_TALK_INPUT_WAV": "/tmp/one.wav,/tmp/two words.wav", "OSAURUS_TALK_AUTOSTART": "default"]))
        #expect(config.inputs.map(\.path) == ["/tmp/one.wav", "/tmp/two words.wav"])
        #expect(config.autostart == .default)
        #expect(config.leadingSilenceMs == 500 && config.trailingSilenceMs == 1200)
        #expect(config.bargeInAfterMs == nil && config.metricsURL == nil)
        let id = UUID()
        let custom = try #require(try TalkBenchmarkConfiguration.parse([
            "OSAURUS_TALK_INPUT_WAV": "/tmp/a.wav", "OSAURUS_TALK_AUTOSTART": id.uuidString,
            "OSAURUS_TALK_BARGE_IN_AFTER_MS": "800", "OSAURUS_TALK_LEADING_SILENCE_MS": "0",
            "OSAURUS_TALK_TRAILING_SILENCE_MS": "2000", "OSAURUS_TALK_METRICS_OUT": "/tmp/out.json"]))
        #expect(custom.autostart == .id(id) && custom.bargeInAfterMs == 800)
        #expect(custom.leadingSilenceMs == 0 && custom.trailingSilenceMs == 2000)
        #expect(custom.metricsURL?.path == "/tmp/out.json")
    }

    @Test func rejectsMalformedEnvironment() {
        for input in ["", "a.wav", "/tmp/a.wav,", ",/tmp/a.wav"] {
            #expect(throws: TalkBenchmarkError.self) { try TalkBenchmarkConfiguration.parse(["OSAURUS_TALK_INPUT_WAV": input]) }
        }
        for (key, value) in [("AUTOSTART", "oops"), ("METRICS_OUT", "relative.json"), ("LEADING_SILENCE_MS", "-1"),
                             ("TRAILING_SILENCE_MS", "nan"), ("BARGE_IN_AFTER_MS", "1.5"), ("TIMEOUT_MS", "0"),
                             ("LEADING_SILENCE_MS", "30001")] {
            #expect(throws: TalkBenchmarkError.self) {
                try TalkBenchmarkConfiguration.parse(["OSAURUS_TALK_INPUT_WAV": "/tmp/a.wav", "OSAURUS_TALK_" + key: value])
            }
        }
    }

    @Test func framesPreserveSamplesAndPadding() {
        let samples = (1...641).map(Float.init)
        let pacer = TalkWAVFramePacer(sampleCount: samples.count, leadingSilenceMs: 1, trailingSilenceMs: 21)
        let frames = (0..<pacer.frameCount).flatMap { pacer.frame($0, samples: samples) }
        #expect(pacer.frameCount == 4)
        #expect(Array(frames.prefix(16)) == Array(repeating: Float(0), count: 16))
        #expect(Array(frames[16..<657]) == samples)
        #expect(frames.dropFirst(657).allSatisfy { $0 == 0 })
        #expect(pacer.deadlineSeconds(afterFrame: 3) == 0.080)
    }

    @Test func timingMathDoesNotDrift() {
        for count in [0, 1, 319, 320, 321, 16_000, 1_920_000] {
            let pacer = TalkWAVFramePacer(sampleCount: count, leadingSilenceMs: 0, trailingSilenceMs: 0)
            #expect(pacer.frameCount == (count + 319) / 320)
            if pacer.frameCount > 0 {
                let duration = pacer.deadlineSeconds(afterFrame: pacer.frameCount - 1)
                #expect(duration >= Double(count) / 16_000)
                #expect(duration - Double(count) / 16_000 < 0.020)
            }
        }
    }

    @Test func nullSinkCompletesInOrderAndStops() async throws {
        let sink = TalkBenchmarkAudio()
        let record = BenchmarkRecord()
        sink.start { _, _ in }
        sink.setLevel { record.addLevel($0) }
        try sink.prepare()
        let start = ProcessInfo.processInfo.systemUptime
        sink.schedule(Array(repeating: 0.5, count: 800)) { record.add(1, $0) }
        sink.schedule(Array(repeating: 0.25, count: 800)) { record.add(2, $0) }
        try await Task.sleep(for: .milliseconds(150))
        #expect(record.results == [1, 2])
        #expect(record.successes == [true, true])
        #expect(record.lastTime - start >= 0.060)
        #expect(record.levels.contains { $0 > 0 })
        #expect(record.levels.last == 0)
        sink.schedule(Array(repeating: 0.5, count: 24_000)) { record.add(3, $0) }
        #expect(sink.isRendering)
        sink.cancel()
        #expect(!sink.isRendering)
        #expect(record.results == [1, 2, 3])
        #expect(record.successes.last == false)
        #expect(record.levels.last == 0)
        sink.shutdown()
        #expect(throws: TalkBenchmarkError.self) { try sink.prepare() }
    }

    @Test func wavInputUsesPacedFramesAndRejectsWrongRate() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("talk-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        func write(rate: Double) throws {
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 641)!
            buffer.frameLength = 641
            for i in 0..<641 { buffer.floatChannelData![0][i] = 0.25 }
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }
        try write(rate: 16_000)
        let record = BenchmarkRecord()
        let sink = TalkBenchmarkAudio()
        sink.start { samples, _ in record.capture(samples) }
        let start = ProcessInfo.processInfo.systemUptime
        try await sink.playInput(url, leadingMs: 20, trailingMs: 20)
        #expect(ProcessInfo.processInfo.systemUptime - start >= 0.080)
        // Resume can precede the capture callback by one queue hop.
        sink.cancel()
        #expect(record.captured.filter { $0 == 0.25 }.count == 641)
        try write(rate: 24_000)
        await #expect(throws: TalkBenchmarkError.self) { try await sink.playInput(url, leadingMs: 0, trailingMs: 0) }
        sink.shutdown()
    }
}

private final class BenchmarkRecord: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [Int] = []
    private var ok: [Bool] = []
    private var time: Double = 0
    private var values: [Float] = []
    private var input: [Float] = []
    var results: [Int] { lock.withLock { ids } }
    var successes: [Bool] { lock.withLock { ok } }
    var lastTime: Double { lock.withLock { time } }
    var levels: [Float] { lock.withLock { values } }
    var captured: [Float] { lock.withLock { input } }
    func add(_ id: Int, _ success: Bool) { lock.withLock { ids.append(id); ok.append(success); time = ProcessInfo.processInfo.systemUptime } }
    func addLevel(_ value: Float) { lock.withLock { values.append(value) } }
    func capture(_ samples: [Float]) { lock.withLock { input.append(contentsOf: samples) } }
}
