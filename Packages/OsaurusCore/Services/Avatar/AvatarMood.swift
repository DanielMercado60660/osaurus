import Foundation

/// Renderer-independent presentation state. Levels are normalized to 0...1.
enum AvatarMood: Equatable, Sendable {
    case idle
    case listening(Float)
    case thinking
    case speaking(Float)
    case error

    var isSpeaking: Bool {
        if case .speaking = self { return true }
        return false
    }

    var accessibilityDescription: String {
        switch self {
        case .idle: "Idle"
        case .listening: "Listening"
        case .thinking: "Thinking"
        case .speaking: "Speaking"
        case .error: "Needs attention"
        }
    }
}

struct AvatarInputs: Sendable {
    var isSpeaking = false
    var speakingLevel: Float = 0
    var isListening = false
    var listeningLevel: Float = 0
    var isStreaming = false
    var hasVisibleText = false
    var hasError = false
}

enum AvatarMoodReducer {
    /// Activity wins over a stale error; an error is shown when otherwise idle.
    /// Exponential attack/release is elapsed-time based, independent of frame rate.
    static func reduce(previous: AvatarMood, inputs: AvatarInputs, elapsed: TimeInterval) -> AvatarMood {
        if inputs.isSpeaking {
            let old: Float = if case .speaking(let level) = previous { level } else { 0 }
            return .speaking(smooth(old, inputs.speakingLevel, elapsed))
        }
        if inputs.isListening {
            let old: Float = if case .listening(let level) = previous { level } else { 0 }
            return .listening(smooth(old, inputs.listeningLevel, elapsed))
        }
        if inputs.isStreaming && !inputs.hasVisibleText { return .thinking }
        if inputs.hasError { return .error }
        return .idle
    }

    private static func smooth(_ previous: Float, _ input: Float, _ elapsed: TimeInterval) -> Float {
        let target = input.isFinite ? min(1, max(0, input)) : 0
        let old = previous.isFinite ? min(1, max(0, previous)) : 0
        let dt = elapsed.isFinite ? max(0, elapsed) : 0
        let timeConstant = target > old ? 0.065 : 0.16
        let result = old + (target - old) * Float(1 - exp(-dt / timeConstant))
        return abs(result - target) < 0.001 ? target : result
    }
}
