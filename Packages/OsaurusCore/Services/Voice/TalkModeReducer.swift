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
    var segments: [Int] = []
    var transcripts: [Int: String] = [:]
    var transcript: String? {
        guard !segments.isEmpty, segments.allSatisfy({ transcripts[$0] != nil }) else { return nil }
        return segments.compactMap { transcripts[$0] }.filter { !$0.isEmpty }.joined(separator: " ")
    }
    var caption = ""
    var candidateSegment: Int?
    var candidateStart: TimeInterval?
    var ignoreUntil: TimeInterval = 0
    var aecActive = false
}

enum TalkModeEvent: Equatable {
    case start(aec: Bool)
    case stop
    case turnFailed(epoch: UInt64)
    case recognitionFailed(segment: Int)
    case aecChanged(Bool)
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
        case .aecChanged(let active):
            s.aecActive = active
        case .turnFailed(let epoch):
            guard s.state != .off, s.epoch == epoch else { break }
            effects = [.cancelReply]
            let candidate = s.candidateSegment
            let start = s.candidateStart
            s = TalkModeSnapshot(state: .listening, epoch: s.epoch + 1, aecActive: s.aecActive)
            if let candidate, let start {
                s.candidateSegment = candidate
                s.candidateStart = start
                acceptCandidate(&s)
            }
        case .recognitionFailed(let segment):
            guard s.state != .off, s.segments.contains(segment) else { break }
            // A failed segment contributes no text; keep any newer speech intact.
            s.transcripts[segment] = ""
            s.caption = s.transcript ?? ""
            if s.segment == segment, s.state == .userSpeaking || s.state == .endOfTurn {
                s = TalkModeSnapshot(state: .listening, epoch: s.epoch + 1, aecActive: s.aecActive)
            }
        case .speechStarted(let segment, let now):
            guard s.state != .off, now >= s.ignoreUntil else { break }
            if s.state == .thinking || s.state == .speaking {
                guard config.bargeInEnabled else { break }
                s.candidateSegment = segment
                s.candidateStart = now
            } else {
                if s.segment != segment {
                    s.epoch += 1
                    if s.state != .endOfTurn {
                        s.speechDuration = 0
                        s.segments = []
                        s.transcripts = [:]
                        s.caption = ""
                    }
                    s.segments.append(segment)
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
            guard s.segments.contains(segment), s.state == .userSpeaking || s.state == .endOfTurn else { break }
            s.transcripts[segment] = text.trimmingCharacters(in: .whitespacesAndNewlines)
            s.caption = s.segments.compactMap { s.transcripts[$0] }.joined(separator: " ")
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
        s.segments = s.segment.map { [$0] } ?? []
        s.transcripts = [:]
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
    /// Null-sink confirmed barge-in to synchronous stop; hardware async stop is unmeasured.
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
    case recognitionFailed(segment: Int, message: String)
    case aecChanged(Bool)
}


/// Hardware-independent route decisions, shared by startup and coalesced rebuilds.
enum TalkAudioPolicy {
    static func needsRebuild(running: Bool, inputUnchanged: Bool) -> Bool { !running || !inputUnchanged }
    static func canUseAEC(requested: Bool, selectedInput: UInt32?, defaultInput: UInt32?) -> Bool {
        requested && (selectedInput == nil || selectedInput == defaultInput)
    }
    static func speakingBelongsToSurface(talkActive: Bool, owner: UUID?, surface: UUID) -> Bool {
        !talkActive || owner == surface
    }
}

/// One speculative final per uninterrupted silence. Committing consumes the
/// speculation; renewed speech invalidates it without losing the utterance audio.
struct TalkFinalizationPolicy {
    private(set) var speculative = false
    enum Action: Equatable { case none, speculate, cancelSpeculation, finalize(reuse: Bool) }
    mutating func update(active: Bool, silence: Double, endSilence: Double, sampleCount: Int) -> Action {
        if sampleCount >= 16_000 * 120 {
            let reuse = speculative && !active
            speculative = false
            return .finalize(reuse: reuse)
        }
        if active {
            if speculative { speculative = false; return .cancelSpeculation }
            return .none
        }
        if silence >= endSilence {
            let reuse = speculative
            speculative = false
            return .finalize(reuse: reuse)
        }
        if silence >= 0.275 && !speculative { speculative = true; return .speculate }
        return .none
    }
}

/// Remember a toggle received during asynchronous capture teardown.
struct TalkRestartRequest {
    private(set) var pending = false
    private(set) var agentID: UUID?
    private(set) var windowID: UUID?
    mutating func queue(agentID: UUID?, windowID: UUID?) {
        pending = true; self.agentID = agentID; self.windowID = windowID
    }
    mutating func take() -> (agentID: UUID?, windowID: UUID?)? {
        guard pending else { return nil }
        defer { self = Self() }
        return (agentID, windowID)
    }
}

/// Recognition delivery is independent of task completion order. Speculation
/// cannot publish until silence commits, and invalidated jobs cannot publish.
struct TalkRecognitionLedger {
    enum Kind { case preview, speculative, final }
    enum Result: Equatable { case text(String), failure(String) }
    struct Delivery: Equatable { let segment: Int; let final: Bool; let result: Result }
    private struct Entry { let segment: Int; var kind: Kind; var result: Result? }
    private var entries: [UUID: Entry] = [:]
    private(set) var speculativeID: UUID?
    mutating func begin(segment: Int, kind: Kind) -> UUID {
        let id = UUID()
        entries[id] = Entry(segment: segment, kind: kind)
        if kind == .speculative { speculativeID = id }
        return id
    }
    mutating func cancelPreviews() -> [UUID] {
        let ids = entries.filter { $0.value.kind == .preview }.map(\.key)
        for id in ids { entries[id] = nil }
        return ids
    }
    mutating func cancelSpeculation() -> UUID? {
        guard let id = speculativeID else { return nil }
        entries[id] = nil
        speculativeID = nil
        return id
    }
    mutating func commitSpeculation() -> Delivery? {
        guard let id = speculativeID, var entry = entries[id] else { return nil }
        speculativeID = nil
        entry.kind = .final
        entries[id] = entry
        if let result = entry.result { return complete(id, result: result) }
        return nil
    }
    mutating func complete(_ id: UUID, result: Result) -> Delivery? {
        guard var entry = entries[id] else { return nil }
        if entry.kind == .speculative {
            entry.result = result
            entries[id] = entry
            return nil
        }
        entries[id] = nil
        return Delivery(segment: entry.segment, final: entry.kind == .final, result: result)
    }
}


/// Queue-confined debounce. A cancelled work item can still be dequeued by GCD;
/// the ticket also prevents that old closure from touching a rebuilt graph.
final class TalkRouteRecovery: @unchecked Sendable {
    private let queue: DispatchQueue
    private var ticket: UUID?
    private var work: DispatchWorkItem?
    init(queue: DispatchQueue) { self.queue = queue }
    func request(_ rebuild: @escaping @Sendable () -> Void) {
        cancel()
        let id = UUID()
        ticket = id
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.ticket == id else { return }
            self.ticket = nil
            self.work = nil
            rebuild()
        }
        self.work = work
        queue.asyncAfter(deadline: .now() + .milliseconds(300), execute: work)
    }
    func cancel() { ticket = nil; work?.cancel(); work = nil }
}
