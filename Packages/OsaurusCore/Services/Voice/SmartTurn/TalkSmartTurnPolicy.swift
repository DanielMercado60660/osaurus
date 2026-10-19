import Foundation

/// One in-flight semantic check per uninterrupted silence, with stale result
/// rejection across speech resumption and segment rollover. Counts include
/// cancelled/failed attempts; probability is the last accepted result.
struct TalkSmartTurnPolicy {
    private var nextID = 0
    private(set) var pending: Int?
    private var lastCheckSilence: Double?
    private(set) var checks = 0
    private(set) var probability: Float?
    private(set) var complete = false

    mutating func resumeSpeech() {
        pending = nil
        lastCheckSilence = nil
        complete = false
    }
    mutating func request(silence: Double, speechDuration: Double, checkSilence: Double) -> Int? {
        guard speechDuration >= 0.3, silence >= checkSilence, pending == nil, !complete,
              lastCheckSilence.map({ silence - $0 >= 0.2 - 1e-9 }) ?? true else { return nil }
        nextID += 1
        pending = nextID
        checks += 1
        lastCheckSilence = silence
        return nextID
    }
    @discardableResult
    mutating func receive(id: Int, probability: Float, threshold: Float) -> Bool {
        guard pending == id, probability.isFinite, (0...1).contains(probability) else { return false }
        pending = nil
        self.probability = probability
        complete = probability >= threshold
        return true
    }
}

enum TalkEndOfTurnReason: String, Codable, Sendable { case smartTurn, silence }
struct TalkEndpointObservation: Sendable, Equatable {
    var checks: Int = 0
    var probability: Float?
    var reason: TalkEndOfTurnReason = .silence
}
