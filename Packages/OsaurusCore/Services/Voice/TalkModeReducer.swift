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
    var segmentDurations: [Int: TimeInterval] = [:]
    var endpointDecided = false
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
    var tentativeReplyState: TalkModeState?
    var spoken = TalkEchoTranscripts()
    var echoRejectedSegments = 0
    var now: TimeInterval = 0
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
    case final(segment: Int, text: String, at: TimeInterval? = nil)
    case agentSpoke(text: String, at: TimeInterval)
    case endpoint(segment: Int)
    case tick(TimeInterval)
    case firstAudio(epoch: UInt64)
    case replyFinished(epoch: UInt64, at: TimeInterval)
}

enum TalkModeEffect: Equatable {
    case cancelReply
    case pauseReply
    case resumeReply
    case send(text: String, epoch: UInt64, speechEnd: TimeInterval)
}

enum TalkModeReducer {
    static func reduce(_ previous: TalkModeSnapshot, _ event: TalkModeEvent,
                       config: TalkModeConfiguration, echo: TalkEchoPolicy = .init()) -> (TalkModeSnapshot, [TalkModeEffect]) {
        var s = previous
        var effects: [TalkModeEffect] = []
        if !config.bargeInEnabled {
            s.candidateStart = nil
            s.candidateSegment = nil
            if s.tentativeReplyState != nil { restoreReply(&s, effects: &effects) }
        }
        switch event {
        case .agentSpoke(let text, let at):
            guard s.state != .off else { break }
            s.now = max(s.now, at)
            s.spoken.record(text, at: at, policy: echo)
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
            if s.tentativeReplyState != nil {
                s.tentativeReplyState = nil
                s.epoch += 1
                break // Preserve the user's in-flight ASR if the reply failed.
            }
            let candidate = s.candidateSegment
            let start = s.candidateStart
            s = listeningSnapshot(s)
            if let candidate, let start {
                s.candidateSegment = candidate
                s.candidateStart = start
                acceptCandidate(&s)
            }
        case .recognitionFailed(let segment):
            guard s.state != .off, s.segments.contains(segment) else { break }
            if s.tentativeReplyState != nil {
                discardSegment(&s, segment: segment, effects: &effects)
                break
            }
            // A failed segment contributes no text; keep any newer speech intact.
            s.transcripts[segment] = ""
            s.caption = s.transcript ?? ""
            if s.segment == segment, s.state == .userSpeaking || s.state == .endOfTurn {
                s = listeningSnapshot(s)
            }
        case .speechStarted(let segment, let now):
            guard s.state != .off, now >= s.ignoreUntil else { break }
            if (s.state == .thinking || s.state == .speaking) && !config.bargeInEnabled { break }
            s.now = max(s.now, now)
            if s.state == .thinking || s.state == .speaking {
                s.candidateSegment = segment
                s.candidateStart = now
            } else {
                if s.segment != segment {
                    if s.tentativeReplyState == nil { s.epoch += 1 }
                    if s.state != .endOfTurn {
                        s.speechDuration = 0
                        s.segmentDurations = [:]
                        s.segments = []
                        s.transcripts = [:]
                        s.caption = ""
                    }
                    s.segments.append(segment)
                }
                s.segment = segment
                s.speechStart = now
                s.speechEnd = nil
                s.endpointDecided = false
                s.state = .userSpeaking
            }
        case .speechEnded(let segment, let now):
            guard s.state != .off, s.segment == segment || s.candidateSegment == segment else { break }
            s.now = max(s.now, now)
            if s.candidateSegment == segment {
                if let start = s.candidateStart,
                   now - start >= echo.bargeInSeconds(aec: s.aecActive, configuredMs: config.bargeInMinSpeechMs) {
                    beginTentative(&s, effects: &effects)
                } else {
                    s.candidateStart = nil
                    s.candidateSegment = nil
                }
            }
            guard s.segment == segment, s.state == .userSpeaking else { break }
            let duration = max(0, now - (s.speechStart ?? now))
            s.speechDuration += duration
            s.segmentDurations[segment, default: 0] += duration
            s.speechStart = nil
            s.speechEnd = now
            s.state = .endOfTurn
        case .partial(let segment, let text):
            guard s.segment == segment, s.state == .userSpeaking || s.state == .endOfTurn else { break }
            s.caption = text
        case .final(let segment, let text, let at):
            guard s.segments.contains(segment), s.transcripts[segment] == nil,
                  s.state == .userSpeaking || s.state == .endOfTurn else { break }
            s.now = max(s.now, at ?? s.now)
            if s.spoken.isEcho(text, at: s.now, policy: echo) {
                s.echoRejectedSegments += 1
                discardSegment(&s, segment: segment, effects: &effects)
                break
            }
            s.transcripts[segment] = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if s.tentativeReplyState != nil, s.speechDuration >= 0.3, hasMeaningfulText(text) {
                s.tentativeReplyState = nil
                s.epoch += 1
                effects.append(.cancelReply)
            }
            s.caption = s.segments.compactMap { s.transcripts[$0] }.joined(separator: " ")
        case .endpoint(let segment):
            if s.segment == segment, s.state == .endOfTurn { s.endpointDecided = true }
        case .tick(let now):
            guard s.state != .off else { break }
            s.now = max(s.now, now)
            if let start = s.candidateStart, s.candidateSegment != nil,
               now - start >= echo.bargeInSeconds(aec: s.aecActive, configuredMs: config.bargeInMinSpeechMs) {
                beginTentative(&s, effects: &effects)
            }
            if s.state == .endOfTurn, let end = s.speechEnd,
               (s.endpointDecided || now - end >= Double(config.endOfTurnSilenceMs) / 1000), let text = s.transcript {
                if s.speechDuration >= 0.3 && hasMeaningfulText(text) {
                    if s.tentativeReplyState != nil {
                        s.tentativeReplyState = nil
                        s.epoch += 1
                        effects.append(.cancelReply)
                    }
                    s.state = .thinking
                    effects.append(.send(text: text, epoch: s.epoch, speechEnd: end))
                } else {
                    restoreReply(&s, effects: &effects)
                }
                s.segment = nil
            }
        case .firstAudio(let epoch):
            guard epoch == s.epoch else { break }
            if s.tentativeReplyState == .thinking {
                s.tentativeReplyState = .speaking
                effects.append(.pauseReply)
            } else if s.state == .thinking { s.state = .speaking }
        case .replyFinished(let epoch, let now):
            guard epoch == s.epoch else { break }
            if s.tentativeReplyState != nil {
                s.tentativeReplyState = .listening
                break
            }
            guard s.state == .thinking || s.state == .speaking else { break }
            s.now = max(s.now, now)
            if s.candidateSegment != nil {
                // Playback can drain while a user is already starting to talk.
                // Keep that onset even when the sustained-speech timer has not fired.
                acceptCandidate(&s)
                break
            }
            s.state = .listening
            s.caption = ""
            s.candidateStart = nil
            s.candidateSegment = nil
        }
        return (s, effects)
    }

    private static func listeningSnapshot(_ s: TalkModeSnapshot) -> TalkModeSnapshot {
        var next = TalkModeSnapshot(state: .listening, epoch: s.epoch + 1, aecActive: s.aecActive)
        next.spoken = s.spoken
        next.echoRejectedSegments = s.echoRejectedSegments
        next.now = s.now
        return next
    }

    private static func beginTentative(_ s: inout TalkModeSnapshot, effects: inout [TalkModeEffect]) {
        let prior = s.state
        let epoch = s.epoch
        acceptCandidate(&s)
        s.epoch = epoch // Keep chat/TTS subscriptions alive until final ASR decides.
        s.tentativeReplyState = prior
        if prior == .speaking { effects.append(.pauseReply) }
    }

    private static func restoreReply(_ s: inout TalkModeSnapshot, effects: inout [TalkModeEffect]) {
        let prior = s.tentativeReplyState
        s.state = prior ?? .listening
        s.tentativeReplyState = nil
        s.segment = nil
        s.speechStart = nil
        s.speechEnd = nil
        s.speechDuration = 0
        s.segmentDurations = [:]
        s.endpointDecided = false
        s.segments = []
        s.transcripts = [:]
        s.caption = ""
        if prior == .speaking { effects.append(.resumeReply) }
    }

    private static func discardSegment(_ s: inout TalkModeSnapshot, segment: Int,
                                       effects: inout [TalkModeEffect]) {
        s.segments.removeAll { $0 == segment }
        s.transcripts[segment] = nil
        s.speechDuration = max(0, s.speechDuration - (s.segmentDurations.removeValue(forKey: segment) ?? 0))
        if s.segments.isEmpty { restoreReply(&s, effects: &effects) }
        else {
            s.caption = s.segments.compactMap { s.transcripts[$0] }.joined(separator: " ")
            if s.segment == segment { s.segment = s.segments.last }
        }
    }

    private static func acceptCandidate(_ s: inout TalkModeSnapshot) {
        s.epoch += 1
        s.state = .userSpeaking
        s.segment = s.candidateSegment
        s.speechStart = s.candidateStart
        s.speechEnd = nil
        s.speechDuration = 0
        s.segmentDurations = [:]
        s.endpointDecided = false
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
        TalkEchoPolicy().threshold(aec: aecActive, protected: playback)
    }
}

public struct TalkTurnLatency: Codable, Equatable, Sendable {
    public let epoch: UInt64
    public let speechEnd: TimeInterval
    public var endOfTurnDecidedMs: Double?
    public var smartTurnChecks: Int?
    public var smartTurnProbability: Float?
    public var endOfTurnReason: String?
    public var asrFinalMs: Double?
    public var sendIssuedMs: Double?
    public var firstStreamDeltaMs: Double?
    public var firstReasoningMs: Double?
    public var firstVisibleTokenMs: Double?
    public var firstSentenceReleasedMs: Double?
    /// Sum of reasoning phases: first reasoning delta until visible content or turn termination.
    public var reasoningDurationMs: Double?
    public var reasoningDeltaCount: Int? = 0
    // Monotonic phase start, excluded from exported measurements.
    private var reasoningStart: TimeInterval?
    /// Compatibility alias for firstVisibleTokenMs (raw content, before display pacing).
    public var firstTokenMs: Double?
    public var firstAudioMs: Double?
    /// Null-sink confirmed barge-in to synchronous stop; hardware async stop is unmeasured.
    public var bargeInToStopMs: Double?

    init(epoch: UInt64, speechEnd: TimeInterval) {
        self.epoch = epoch; self.speechEnd = speechEnd
    }
    private enum CodingKeys: String, CodingKey {
        case epoch, speechEnd, endOfTurnDecidedMs, asrFinalMs, sendIssuedMs
        case firstStreamDeltaMs, firstReasoningMs, firstVisibleTokenMs, firstTokenMs
        case firstSentenceReleasedMs, firstAudioMs, bargeInToStopMs
        case reasoningDurationMs, reasoningDeltaCount, smartTurnChecks, smartTurnProbability, endOfTurnReason
    }
    mutating func observe(_ event: TalkStreamTimingEvent) {
        switch event {
        case .delta(let at):
            if firstStreamDeltaMs == nil { firstStreamDeltaMs = (at - speechEnd) * 1000 }
        case .reasoning(let at):
            if firstReasoningMs == nil { firstReasoningMs = (at - speechEnd) * 1000 }
            if reasoningStart == nil { reasoningStart = at }
            reasoningDeltaCount = (reasoningDeltaCount ?? 0) + 1
        }
    }
    mutating func visible(at: TimeInterval) {
        if firstVisibleTokenMs == nil {
            firstVisibleTokenMs = (at - speechEnd) * 1000
            firstTokenMs = firstVisibleTokenMs
        }
        finishReasoning(at: at)
    }
    mutating func finishReasoning(at: TimeInterval) {
        if let start = reasoningStart {
            reasoningDurationMs = (reasoningDurationMs ?? 0) + max(0, at - start) * 1000
            reasoningStart = nil
        } else if reasoningDeltaCount == 0 {
            reasoningDurationMs = 0
        }
    }
}

/// Observation only; never changes channel routing or text.
enum TalkStreamTimingEvent {
    case delta(at: TimeInterval)
    case reasoning(at: TimeInterval)
}

/// Segment timestamps survive speculative result delivery and are pruned when
/// the reducer accepts a new utterance. All required segments must be measured.
struct TalkCaptureTiming {
    var endpoints: [Int: TimeInterval] = [:]
    var finals: [Int: TimeInterval] = [:]
    var observations: [Int: TalkEndpointObservation] = [:]
    mutating func retain(_ segments: [Int]) {
        endpoints = endpoints.filter { segments.contains($0.key) }
        finals = finals.filter { segments.contains($0.key) }
        observations = observations.filter { segments.contains($0.key) }
    }
    func apply(segments: [Int], to turn: inout TalkTurnLatency) {
        if !segments.isEmpty, segments.allSatisfy({ observations[$0] != nil }) {
            turn.smartTurnChecks = segments.compactMap { observations[$0]?.checks }.reduce(0, +)
            turn.smartTurnProbability = segments.compactMap { observations[$0]?.probability }.last
            turn.endOfTurnReason = segments.last.flatMap { observations[$0]?.reason.rawValue }
        }
        if !segments.isEmpty, segments.allSatisfy({ endpoints[$0] != nil }),
           let end = segments.compactMap({ endpoints[$0] }).max() {
            turn.endOfTurnDecidedMs = (end - turn.speechEnd) * 1000
        }
        if !segments.isEmpty, segments.allSatisfy({ finals[$0] != nil }),
           let final = segments.compactMap({ finals[$0] }).max() {
            turn.asrFinalMs = (final - turn.speechEnd) * 1000
        }
    }
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
        let values = turns.compactMap { $0[keyPath: keyPath] }.filter { $0.isFinite && $0 >= 0 }.sorted()
        guard !values.isEmpty else { return nil }
        return (values[max(0, Int(ceil(Double(values.count) * 0.5)) - 1)],
                values[max(0, Int(ceil(Double(values.count) * 0.9)) - 1)])
    }
}

/// Shared with the capture worker. Changing playback state affects the next VAD
/// evaluation without tearing down capture (the barge-in onset stays buffered).
final class TalkSpeechGate: @unchecked Sendable {
    private let lock = NSLock()
    private let policy: TalkEchoPolicy
    private var aec = false
    private var playback = false
    private var protectedUntil: TimeInterval = 0
    private var floor = TalkEchoFloor()
    private var outputRMS: Float = 0
    private var outputAt: TimeInterval = 0
    private var ignoreUntil: TimeInterval = 0
    let silenceSeconds: Double
    let smartTurnDirectory: URL?
    let smartTurnCheckSeconds: Double
    let fallbackSilenceSeconds: Double
    init(silenceMs: Int, smartTurnDirectory: URL? = nil, smartTurnCheckMs: Int = 250,
         fallbackSilenceMs: Int? = nil, echo: TalkEchoPolicy = .init()) {
        policy = echo
        silenceSeconds = Double(silenceMs) / 1000
        self.smartTurnDirectory = smartTurnDirectory
        smartTurnCheckSeconds = Double(smartTurnCheckMs) / 1000
        fallbackSilenceSeconds = Double(fallbackSilenceMs ?? silenceMs) / 1000
    }
    func beginReply() { lock.withLock { floor.reset() } }
    func updateOutputRMS(_ rms: Float, at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.withLock { outputRMS = rms; outputAt = time }
    }
    func update(aec: Bool, playback: Bool, ignoreUntil: TimeInterval,
                at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.withLock {
            if self.playback && !playback { protectedUntil = time + policy.cooldownSeconds }
            self.aec = aec
            self.playback = playback
            self.ignoreUntil = ignoreUntil
        }
    }
    func detects(_ probability: Float, micRMS: Float = 0, at time: TimeInterval) -> Bool {
        lock.withLock {
            let threshold = policy.threshold(aec: aec, protected: playback || time < protectedUntil)
            let detected = floor.detects(probability: probability, micRMS: micRMS,
                outputRMS: time - outputAt <= 0.1 ? outputRMS : 0,
                playback: playback, threshold: threshold, at: time, policy: policy)
            return time >= ignoreUntil && detected
        }
    }

}

enum TalkCaptureEvent: Sendable {
    case endOfTurnDecided(segment: Int, at: TimeInterval, observation: TalkEndpointObservation = .init())
    case activity(segment: Int, active: Bool, at: TimeInterval)
    case partial(segment: Int, text: String)
    case final(segment: Int, text: String, at: TimeInterval?)
    case failed(String)
    case recognitionFailed(segment: Int, message: String)
    case aecChanged(Bool)
    case smartTurnUnavailable(String)
}


/// Hardware-independent route decisions, shared by startup and coalesced rebuilds.
enum TalkAudioPolicy {
    static func needsRebuild(running: Bool, inputUnchanged: Bool) -> Bool { !running || !inputUnchanged }
    static func canUseAEC(requested: Bool, selectedInput: UInt32?, defaultInput: UInt32?) -> Bool {
        requested && (selectedInput == nil || selectedInput == defaultInput)
    }
    static func aecOffReason(requested: Bool, failure: String? = nil) -> String {
        if let failure { return "Apple voice processing failed: " + failure }
        return requested ? "Selected input cannot share Apple voice processing with the default output"
            : "Disabled in Talk Mode settings"
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
    mutating func update(active: Bool, silence: Double, endSilence: Double, sampleCount: Int, semanticComplete: Bool = false, speculationSilence: Double = 0.275) -> Action {
        if sampleCount >= 16_000 * 120 {
            let reuse = speculative && !active
            speculative = false
            return .finalize(reuse: reuse)
        }
        if active {
            if speculative { speculative = false; return .cancelSpeculation }
            return .none
        }
        if semanticComplete || silence >= endSilence {
            let reuse = speculative
            speculative = false
            return .finalize(reuse: reuse)
        }
        if silence >= speculationSilence && !speculative { speculative = true; return .speculate }
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
    struct Delivery: Equatable { let segment: Int; let final: Bool; let result: Result; var completedAt: TimeInterval? = nil }
    private struct Entry { let segment: Int; var kind: Kind; var result: Result?; var completedAt: TimeInterval? }
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
        if let result = entry.result { return complete(id, result: result, at: entry.completedAt) }
        return nil
    }
    mutating func complete(_ id: UUID, result: Result, at: TimeInterval? = nil) -> Delivery? {
        guard var entry = entries[id] else { return nil }
        if entry.kind == .speculative {
            entry.result = result
            entry.completedAt = at
            entries[id] = entry
            return nil
        }
        entries[id] = nil
        return Delivery(segment: entry.segment, final: entry.kind == .final, result: result, completedAt: at)
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
