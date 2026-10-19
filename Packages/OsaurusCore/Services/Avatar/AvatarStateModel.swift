import Combine
import Foundation

@MainActor
protocol AvatarAudioLevelSource {
    var isSpeaking: Bool { get }
    var outputLevel: Float { get }
}

@MainActor
struct DefaultAvatarAudioLevelSource: AvatarAudioLevelSource {
    var isSpeaking: Bool {
        TTSService.shared.playingMessageId != nil || TalkModeController.shared.state == .speaking
    }
    var outputLevel: Float { TTSService.shared.outputLevel }
}

/// One model per visible surface. Sampling is owned by the view's cancellable
/// task, so hidden windows and removed empty states do no ongoing source work.
@MainActor
final class AvatarStateModel: ObservableObject {
    @Published private(set) var mood: AvatarMood = .idle
    @Published private(set) var agent: Agent = .default
    private let audio: any AvatarAudioLevelSource

    init(audio: (any AvatarAudioLevelSource)? = nil) {
        self.audio = audio ?? DefaultAvatarAudioLevelSource()
    }

    func update(_ inputs: AvatarInputs, elapsed: TimeInterval) {
        let next = AvatarMoodReducer.reduce(previous: mood, inputs: inputs, elapsed: elapsed)
        if next != mood { mood = next }
    }

    func sample(agentID: UUID?, windowID: UUID?, elapsed: TimeInterval) {
        let manager = ChatWindowManager.shared
        let state = (windowID ?? manager.lastFocusedWindowId).flatMap { manager.windowState(id: $0) }
        let session = state?.session
        let selectedAgent =
            agentID.flatMap { AgentManager.shared.agent(for: $0) }
            ?? state?.activeAgent ?? AgentManager.shared.activeAgent
        if agent != selectedAgent { agent = selectedAgent }
        // An empty state in a different window must not mirror the focused agent.
        let matchesSession = agentID == nil || session?.agentId == agentID
        let streaming = matchesSession && session?.isStreaming == true
        var hasText = false
        if streaming, let session {
            // Only inspect this user turn, never a previous completed answer.
            for turn in session.turns.reversed() {
                if turn.role == .user { break }
                if turn.role == .assistant
                    && !turn.visibleContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                {
                    hasText = true
                    break
                }
            }
        }
        let vad = VADService.shared
        let speech = SpeechService.shared
        let voiceError: Bool = if case .error = vad.state { true } else { false }
        update(
            AvatarInputs(
                isSpeaking: audio.isSpeaking,
                speakingLevel: audio.outputLevel,
                isListening: vad.state == .listening || speech.isSpeechDetected
                    || (TalkModeController.shared.agentID == selectedAgent.id
                        && TalkModeController.shared.state == .listening),
                listeningLevel: max(vad.audioLevel, speech.audioLevel),
                isStreaming: streaming,
                hasVisibleText: hasText,
                hasError: voiceError || (matchesSession && session?.lastStreamError != nil)
            ),
            elapsed: elapsed
        )
    }
}
