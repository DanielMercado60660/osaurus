import Foundation

public enum TalkModeState: String, Equatable, Sendable {
    case off, listening, userSpeaking, endOfTurn, thinking, speaking
}

/// Capture segment IDs survive ASR latency; reply epochs survive LLM/TTS cancellation.
/// All times are monotonic seconds supplied by the caller, never wall-clock dates.
struct TalkModeSnapshot: Equatable, Sendable {
    var state: TalkModeState = .off
    var epoch: UInt64 = 0
    var segment: Int?
    var speechStart: TimeInterval?
    var speechEnd: TimeInterval?
    var speechDuration: TimeInterval = 0
    var transcript: String?
    var caption = ""
    var candidateSegment: Int?
    var candidateStart: TimeInterval?
    var ignoreUntil: TimeInterval = 0
    var aecActive = false
}

enum TalkModeEvent: Equatable {
    case start(aec: Bool)
    case stop
    case speechStarted(segment: Int, at: TimeInterval)
    case speechEnded(segment: Int, at: TimeInterval)
    case partial(segment: Int, text: String)
    case final(segment: Int, text: String)
    case tick(TimeInterval)
    case firstAudio(epoch: UInt64)
    case replyFinished(epoch: UInt64, at: TimeInterval)
}

enum TalkModeEffect: Equatable {
    case cancelReply
    case send(text: String, epoch: UInt64, speechEnd: TimeInterval)
}

enum TalkModeReducer {
    static func reduce(_ previous: TalkModeSnapshot, _ event: TalkModeEvent,
                       config: TalkModeConfiguration) -> (TalkModeSnapshot, [TalkModeEffect]) {
        var s = previous
        var effects: [TalkModeEffect] = []
        if !config.bargeInEnabled {
            s.candidateStart = nil
            s.candidateSegment = nil
        }
        switch event {
        case .start(let aec):
            guard s.state == .off else { break }
            s = TalkModeSnapshot(state: .listening, epoch: s.epoch + 1, aecActive: aec)
        case .stop:
            effects = s.state == .off ? [] : [.cancelReply]
            s = TalkModeSnapshot(epoch: s.epoch + 1)
        case .speechStarted(let segment, let now):
            guard s.state != .off, now >= s.ignoreUntil else { break }
            if s.state == .thinking || s.state == .speaking {
                guard config.bargeInEnabled else { break }
                s.candidateSegment = segment
                s.candidateStart = now
            } else {
                if s.segment != segment {
                    s.epoch += 1
                    s.speechDuration = 0
                    s.transcript = nil
                    s.caption = ""
                }
                s.segment = segment
                s.speechStart = now
                s.speechEnd = nil
                s.state = .userSpeaking
            }
        case .speechEnded(let segment, let now):
            if s.candidateSegment == segment {
                if let start = s.candidateStart,
                   now - start >= Double(config.bargeInMinSpeechMs) / 1000 {
                    acceptCandidate(&s)
                    effects.append(.cancelReply)
                } else {
                    s.candidateStart = nil
                    s.candidateSegment = nil
                }
            }
            guard s.segment == segment, s.state == .userSpeaking else { break }
            s.speechDuration += max(0, now - (s.speechStart ?? now))
            s.speechStart = nil
            s.speechEnd = now
            s.state = .endOfTurn
        case .partial(let segment, let text):
            guard s.segment == segment, s.state == .userSpeaking || s.state == .endOfTurn else { break }
            s.caption = text
        case .final(let segment, let text):
            guard s.segment == segment, s.state == .userSpeaking || s.state == .endOfTurn else { break }
            s.transcript = text.trimmingCharacters(in: .whitespacesAndNewlines)
            s.caption = s.transcript ?? ""
        case .tick(let now):
            if let start = s.candidateStart, s.candidateSegment != nil,
               now - start >= Double(config.bargeInMinSpeechMs) / 1000 {
                acceptCandidate(&s)
                effects.append(.cancelReply)
            }
            if s.state == .endOfTurn, let end = s.speechEnd,
               now - end >= Double(config.endOfTurnSilenceMs) / 1000, let text = s.transcript {
                if s.speechDuration >= 0.3 && hasMeaningfulText(text) {
                    s.state = .thinking
                    effects.append(.send(text: text, epoch: s.epoch, speechEnd: end))
                } else {
                    s.state = .listening
                    s.caption = ""
                }
                s.segment = nil
            }
        case .firstAudio(let epoch):
            guard epoch == s.epoch, s.state == .thinking else { break }
            s.state = .speaking
        case .replyFinished(let epoch, let now):
            guard epoch == s.epoch, s.state == .thinking || s.state == .speaking else { break }
            if s.candidateSegment != nil {
                // Playback can drain while a user is already starting to talk.
                // Keep that onset even when the 160 ms barge timer has not fired.
                acceptCandidate(&s)
                break
            }
            let hadPlayback = s.state == .speaking
            s.state = .listening
            s.caption = ""
            s.candidateStart = nil
            s.candidateSegment = nil
            if hadPlayback && !s.aecActive { s.ignoreUntil = now + 0.3 }
        }
        return (s, effects)
    }

    private static func acceptCandidate(_ s: inout TalkModeSnapshot) {
        s.epoch += 1
        s.state = .userSpeaking
        s.segment = s.candidateSegment
        s.speechStart = s.candidateStart
        s.speechEnd = nil
        s.speechDuration = 0
        s.transcript = nil
        s.caption = ""
        s.candidateStart = nil
        s.candidateSegment = nil
    }

    static func hasMeaningfulText(_ text: String) -> Bool {
        let words = text.lowercased().split { !$0.isLetter && !$0.isNumber }
        return words.contains { !["uh", "um"].contains(String($0)) }
    }

    static func vadThreshold(aecActive: Bool, playback: Bool) -> Float {
        !aecActive && playback ? 0.75 : 0.5
    }
}

public struct TalkTurnLatency: Codable, Equatable, Sendable {
    public let epoch: UInt64
    public let speechEnd: TimeInterval
    public var firstTokenMs: Double?
    public var firstAudioMs: Double?
    /// Time from confirmed barge-in to synchronous player stop; not acoustic proof.
    public var bargeInToStopMs: Double?
}

public struct TalkLatencyHistory: Sendable {
    public private(set) var turns: [TalkTurnLatency] = []
    public init() {}
    mutating func begin(epoch: UInt64, speechEnd: TimeInterval) {
        turns.append(TalkTurnLatency(epoch: epoch, speechEnd: speechEnd))
        if turns.count > 50 { turns.removeFirst(turns.count - 50) }
    }
    mutating func update(epoch: UInt64, _ body: (inout TalkTurnLatency) -> Void) {
        guard let index = turns.firstIndex(where: { $0.epoch == epoch }) else { return }
        body(&turns[index])
    }
    public func percentiles(_ keyPath: KeyPath<TalkTurnLatency, Double?>) -> (p50: Double, p90: Double)? {
        let values = turns.compactMap { $0[keyPath: keyPath] }.sorted()
        guard !values.isEmpty else { return nil }
        return (values[max(0, Int(ceil(Double(values.count) * 0.5)) - 1)],
                values[max(0, Int(ceil(Double(values.count) * 0.9)) - 1)])
    }
}

/// Shared with the capture worker. Changing playback state affects the next VAD
/// evaluation without tearing down capture (the barge-in onset stays buffered).
final class TalkSpeechGate: @unchecked Sendable {
    private let lock = NSLock()
    private var threshold: Float = 0.5
    private var ignoreUntil: TimeInterval = 0
    let silenceSeconds: Double
    init(silenceMs: Int) { silenceSeconds = Double(silenceMs) / 1000 }
    func update(aec: Bool, playback: Bool, ignoreUntil: TimeInterval) {
        lock.withLock {
            threshold = TalkModeReducer.vadThreshold(aecActive: aec, playback: playback)
            self.ignoreUntil = ignoreUntil
        }
    }
    func detects(_ probability: Float, at time: TimeInterval) -> Bool {
        lock.withLock { time >= ignoreUntil && probability > threshold }
    }
}

enum TalkCaptureEvent: Sendable {
    case activity(segment: Int, active: Bool, at: TimeInterval)
    case partial(segment: Int, text: String)
    case final(segment: Int, text: String)
    case failed(String)
}
