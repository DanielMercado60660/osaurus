/// Pure policy; readiness errors belong to the selected talk/chat lifecycle.
enum WakeWordRoute: Equatable, Sendable {
    case companion, chat

    static func resolve(companionEnabled: Bool, talkEnabledForAgent: Bool) -> Self {
        companionEnabled && talkEnabledForAgent ? .companion : .chat
    }
}
