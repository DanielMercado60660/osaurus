import AppKit
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
    @Published private(set) var reaction: AvatarReaction?
    @Published private(set) var microAction: AvatarMicroAction?
    @Published private(set) var gaze = CGPoint.zero
    @Published private(set) var assistantCaption = ""
    private var reactions = AvatarReactionScheduler()
    private var idle = AvatarIdleScheduler()
    private var captions = AvatarCaptionState()
    private var subscription: AnyCancellable?
    private let audio: any AvatarAudioLevelSource

    init(audio: (any AvatarAudioLevelSource)? = nil) {
        self.audio = audio ?? DefaultAvatarAudioLevelSource()
        subscription = TalkModeController.shared.avatarEvents.sink { [weak self] id, event in
            guard let self, id == self.agent.id else { return }
            let now = ProcessInfo.processInfo.systemUptime
            switch event {
            case .reaction(let reaction): self.reactions.trigger(reaction, at: now)
            case .began(let epoch): self.captions.begin(epoch: epoch)
            case .delta(let text, let epoch): self.captions.append(text, epoch: epoch)
            case .playback(let text, let epoch): self.captions.playback(text, epoch: epoch)
            case .finished(let epoch): self.captions.finish(epoch: epoch, at: now)
            case .cleared: self.captions.clear()
            }
        }
    }

    func update(_ inputs: AvatarInputs, elapsed: TimeInterval) {
        let next = AvatarMoodReducer.reduce(previous: mood, inputs: inputs, elapsed: elapsed)
        if next != mood { mood = next }
    }

    func sample(agentID: UUID?, windowID: UUID?, elapsed: TimeInterval, mouseOrigin: CGPoint? = nil) {
        let manager = ChatWindowManager.shared
        let talk = TalkModeController.shared
        let talkWindow = talk.isActive && (agentID == nil || agentID == talk.agentID) ? talk.windowID : nil
        let state = (windowID ?? talkWindow ?? manager.lastFocusedWindowId).flatMap { manager.windowState(id: $0) }
        let session = state?.session
        let selectedAgent =
            agentID.flatMap { AgentManager.shared.agent(for: $0) }
            ?? state?.activeAgent ?? AgentManager.shared.activeAgent
        if agent.id != selectedAgent.id {
            reactions = AvatarReactionScheduler()
            idle = AvatarIdleScheduler()
            captions.clear()
        }
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
        let ownsAudio = TalkAudioPolicy.speakingBelongsToSurface(
            talkActive: TalkModeController.shared.isActive,
            owner: TalkModeController.shared.agentID, surface: selectedAgent.id)
        update(
            AvatarInputs(
                isSpeaking: ownsAudio && audio.isSpeaking,
                speakingLevel: ownsAudio ? audio.outputLevel : 0,
                isListening: talk.isActive
                    ? (talk.agentID == selectedAgent.id && [.listening, .userSpeaking, .endOfTurn].contains(talk.state))
                    : (vad.state == .listening || speech.isSpeechDetected),
                listeningLevel: max(vad.audioLevel, speech.audioLevel),
                isStreaming: streaming || (talk.agentID == selectedAgent.id && talk.state == .thinking),
                hasVisibleText: talk.agentID == selectedAgent.id && talk.isActive ? false : hasText,
                hasError: voiceError || (matchesSession && session?.lastStreamError != nil)
            ),
            elapsed: elapsed
        )
        let now = ProcessInfo.processInfo.systemUptime
        reactions.expire(at: now)
        reaction = reactions.visible(over: mood, at: now)
        idle.update(idle: mood == .idle && reaction == nil, at: now, random: { Double.random(in: 0...1) })
        microAction = idle.action
        assistantCaption = captions.visible(at: now)
        if mood == .idle, let origin = mouseOrigin {
            let mouse = NSEvent.mouseLocation
            let target = CGPoint(x: max(-1, min(1, (mouse.x - origin.x) / 300)),
                                 y: max(-1, min(1, (origin.y - mouse.y) / 300)))
            gaze.x += (target.x - gaze.x) * 0.2
            gaze.y += (target.y - gaze.y) * 0.2
        } else { gaze = .zero }
    }
}
