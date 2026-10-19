import Foundation

/// Expressions decorate the base mood; they never replace its audio level.
enum AvatarReaction: String, CaseIterable, Sendable {
    case happy, oops, surprised
    var priority: Int { switch self { case .happy: 0; case .oops: 1; case .surprised: 2 } }
    var duration: TimeInterval { self == .surprised ? 0.9 : 1.8 }
}

struct AvatarReactionScheduler {
    private(set) var reaction: AvatarReaction?
    private(set) var expiresAt: TimeInterval = 0

    mutating func trigger(_ next: AvatarReaction, at now: TimeInterval) {
        expire(at: now)
        guard reaction == nil || next.priority >= reaction!.priority else { return }
        reaction = next
        expiresAt = now + next.duration
    }

    mutating func expire(at now: TimeInterval) {
        if now >= expiresAt { reaction = nil }
    }

    func visible(over mood: AvatarMood, at now: TimeInterval) -> AvatarReaction? {
        guard now < expiresAt else { return nil }
        // A celebration must not obscure a new response or a persistent error.
        if reaction == .happy, mood != .idle, !mood.isListening { return nil }
        return reaction
    }
}

enum AvatarMicroAction: String, CaseIterable, Sendable { case lookAround, stretch, tailWag }

struct AvatarIdleScheduler {
    private(set) var nextAt: TimeInterval?
    private(set) var action: AvatarMicroAction?
    private var endsAt: TimeInterval = 0

    /// Caller injects both time and randomness. A fresh idle interval starts
    /// after activity, so returning from a reply cannot fire an overdue action.
    mutating func update(idle: Bool, at now: TimeInterval, random: () -> Double) {
        guard idle else { nextAt = nil; action = nil; return }
        if action != nil {
            if now < endsAt { return }
            action = nil
        }
        if let nextAt, now >= nextAt {
            let unit = min(0.999999, max(0, random()))
            action = AvatarMicroAction.allCases[Int(unit * 3)]
            endsAt = now + 2.4
            self.nextAt = now + delay(random())
        } else if nextAt == nil {
            nextAt = now + delay(random())
        }
    }

    private func delay(_ unit: Double) -> TimeInterval { 20 + min(1, max(0, unit)) * 40 }
}

enum AvatarAccessory: String, CaseIterable, Sendable {
    case none, scarf, glasses, leaf

    static func mascot(_ id: String?) -> Self {
        switch id {
        case "blue", "red": .scarf
        case "purple", "orange": .glasses
        case "green", "yellow": .leaf
        default: .none
        }
    }
}

/// No time estimates from token counts. Only a playback event advances text.
struct AvatarCaptionState {
    private(set) var epoch: UInt64 = 0
    private(set) var streamedText = ""
    private(set) var text = ""
    private(set) var fadesAt: TimeInterval?
    private var acceptingPlayback = false

    mutating func begin(epoch: UInt64) {
        self = Self()
        self.epoch = epoch
        acceptingPlayback = true
    }
    mutating func append(_ delta: String, epoch: UInt64) {
        guard acceptingPlayback, self.epoch == epoch else { return }
        streamedText += delta
    }
    mutating func playback(_ text: String, epoch: UInt64) {
        guard acceptingPlayback, self.epoch == epoch else { return }
        self.text = text
        fadesAt = nil
    }
    mutating func finish(epoch: UInt64, at now: TimeInterval) {
        guard acceptingPlayback, self.epoch == epoch else { return }
        fadesAt = now + 2
        acceptingPlayback = false
    }
    mutating func clear() { text = ""; streamedText = ""; fadesAt = nil; acceptingPlayback = false }
    func visible(at now: TimeInterval) -> String {
        if let fadesAt, now >= fadesAt { return "" }
        return text
    }
}

extension AvatarMood {
    var isListening: Bool { if case .listening = self { true } else { false } }
    var frameInterval: TimeInterval { isSpeaking ? 1.0 / 30 : 0.1 }
}

/// Presentation-only events emitted by the talk controller, scoped to its agent.
enum AvatarTalkEvent {
    case reaction(AvatarReaction)
    case began(UInt64)
    case delta(String, UInt64)
    case playback(String, UInt64)
    case finished(UInt64)
    case cleared
}
