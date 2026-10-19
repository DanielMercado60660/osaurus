import Foundation

/// Developer harness only. Compiled in Release for comparable measurements;
/// absent INPUT_WAV means the normal audio path is completely unchanged.
struct TalkBenchmarkConfiguration: Sendable {
    enum AgentSelection: Equatable, Sendable { case `default`, id(UUID) }
    let inputs: [URL]
    let autostart: AgentSelection?
    let metricsURL: URL?
    let leadingSilenceMs: Int
    let trailingSilenceMs: Int
    let bargeInAfterMs: Int?
    let timeoutMs: Int

    static var inputRequested: Bool { ProcessInfo.processInfo.environment["OSAURUS_TALK_INPUT_WAV"] != nil }

    static func parse(_ env: [String: String]) throws -> Self? {
        guard let input = env["OSAURUS_TALK_INPUT_WAV"] else { return nil }
        func path(_ value: String, key: String) throws -> URL {
            guard value.hasPrefix("/"), !value.contains("\n") else { throw TalkBenchmarkError("\(key) requires an absolute path") }
            return URL(fileURLWithPath: value)
        }
        let parts = input.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty, parts.count <= 50 else { throw TalkBenchmarkError("INPUT_WAV requires 1...50 files") }
        let inputs = try parts.map { try path($0, key: "INPUT_WAV") }
        let autostart: AgentSelection?
        if let value = env["OSAURUS_TALK_AUTOSTART"] {
            if value == "default" { autostart = .default }
            else if let id = UUID(uuidString: value) { autostart = .id(id) }
            else { throw TalkBenchmarkError("AUTOSTART must be default or an agent UUID") }
        } else { autostart = nil }
        func milliseconds(_ key: String, default fallback: Int, range: ClosedRange<Int>) throws -> Int {
            guard let value = env["OSAURUS_TALK_" + key] else { return fallback }
            guard let number = Int(value), range.contains(number) else {
                throw TalkBenchmarkError("OSAURUS_TALK_\(key) must be an integer in \(range)")
            }
            return number
        }
        return try Self(inputs: inputs, autostart: autostart,
            metricsURL: env["OSAURUS_TALK_METRICS_OUT"].map { try path($0, key: "METRICS_OUT") },
            leadingSilenceMs: milliseconds("LEADING_SILENCE_MS", default: 500, range: 0...30_000),
            trailingSilenceMs: milliseconds("TRAILING_SILENCE_MS", default: 1200, range: 0...30_000),
            bargeInAfterMs: env["OSAURUS_TALK_BARGE_IN_AFTER_MS"] == nil ? nil : milliseconds("BARGE_IN_AFTER_MS", default: 800, range: 0...30_000),
            timeoutMs: milliseconds("TIMEOUT_MS", default: 180_000, range: 1000...3_600_000))
    }
}

struct TalkBenchmarkError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Integer sample arithmetic avoids accumulating rounding error. The final
/// frame is padded to 20 ms; every sample is delivered exactly once.
struct TalkWAVFramePacer: Sendable {
    static let sampleRate = 16_000
    static let frameMilliseconds = 20
    static let frameSamples = sampleRate * frameMilliseconds / 1000
    let sampleCount: Int
    let leadingSamples: Int
    let trailingSamples: Int
    init(sampleCount: Int, leadingSilenceMs: Int, trailingSilenceMs: Int) {
        precondition(sampleCount >= 0 && leadingSilenceMs >= 0 && trailingSilenceMs >= 0)
        self.sampleCount = sampleCount
        leadingSamples = leadingSilenceMs * 16
        trailingSamples = trailingSilenceMs * 16
    }
    var frameCount: Int { (leadingSamples + sampleCount + trailingSamples + Self.frameSamples - 1) / Self.frameSamples }
    func deadlineSeconds(afterFrame frame: Int) -> Double { Double(frame + 1) * Double(Self.frameMilliseconds) / 1000 }
    func frame(_ index: Int, samples: [Float]) -> [Float] {
        precondition(samples.count == sampleCount && index >= 0 && index < frameCount)
        let start = index * Self.frameSamples - leadingSamples
        return (0..<Self.frameSamples).map { offset in
            let source = start + offset
            return source >= 0 && source < sampleCount ? samples[source] : 0
        }
    }
}
