import Combine
import Foundation
import os

@MainActor
public final class TalkModeController: ObservableObject {
    public static let shared = TalkModeController()
    @Published public private(set) var state: TalkModeState = .off
    @Published public private(set) var caption = ""
    @Published public private(set) var isStarting = false
    @Published public private(set) var isStopping = false
    @Published public private(set) var lastError: String?
    @Published public private(set) var configuration = TalkModeConfigurationStore.load()
    @Published public private(set) var aecActive = false
    public private(set) var latency = TalkLatencyHistory()
    public private(set) var agentID: UUID?
    public private(set) var windowID: UUID?
    public var isActive: Bool { state != .off || isStarting || isStopping }

    private let logger = Logger(subsystem: "ai.osaurus", category: "talk.mode")
    private var snapshot = TalkModeSnapshot()
    private var session: ChatSession?
    private var duplex: TalkAudioEngine?
    private var gate: TalkSpeechGate?
    private var stream: TTSStreamHandle?
    private var replyEpoch: UInt64?
    private var captureSubscription: AnyCancellable?
    private var chatSubscription: AnyCancellable?
    private var ttsSubscription: AnyCancellable?
    private var configurationSubscription: AnyCancellable?
    private var startup: Task<Void, Never>?
    private var ticker: Task<Void, Never>?
    private var shouldResumeVAD = false

    private init() {
        configurationSubscription = NotificationCenter.default.publisher(for: .voiceConfigurationChanged)
            .sink { [weak self] _ in
                guard let self else { return }
                let next = TalkModeConfigurationStore.load()
                let requiresRestart = next.endOfTurnSilenceMs != self.configuration.endOfTurnSilenceMs
                    || next.echoCancellationEnabled != self.configuration.echoCancellationEnabled
                self.configuration = next
                if self.isActive && (requiresRestart || self.agentID.map { !next.enabledAgentIds.contains($0) } == true) {
                    self.stop()
                }
            }
    }

    func initialize() {
        TalkModeHotKey.shared.register { TalkModeController.shared.toggle() }
    }

    func owns(_ session: ChatSession) -> Bool { isActive && self.session === session }

    func toggle(agentID requestedAgentID: UUID? = nil, windowID requestedWindowID: UUID? = nil) {
        if isActive { stop(); return }
        let manager = ChatWindowManager.shared
        let focused = (requestedWindowID ?? manager.lastFocusedWindowId).flatMap { manager.windowState(id: $0) }
        let id = requestedAgentID ?? focused?.activeAgent.id ?? AgentManager.shared.activeAgent.id
        guard configuration.enabledAgentIds.contains(id) else {
            lastError = "Enable this agent in Voice → Talk Mode first."
            ToastManager.shared.error("Talk mode is disabled", message: lastError!)
            return
        }
        guard TTSService.shared.isModelReady else {
            lastError = "Load the speech engine in Voice → Text To Speech before starting talk mode."
            ToastManager.shared.error("Speech engine is not ready", message: lastError!)
            return
        }
        guard TranscriptionModeService.shared.state == .idle else {
            lastError = "Finish Transcription Mode before starting talk mode."
            ToastManager.shared.error("Microphone is in use", message: lastError!)
            return
        }
        let target: UUID
        if let focused, focused.activeAgent.id == id {
            target = focused.windowId
            manager.showWindow(id: target)
        } else if let existing = manager.findWindows(byAgentId: id).first {
            target = existing.id
            manager.showWindow(id: target)
        } else {
            target = manager.createWindow(agentId: id)
        }
        guard let session = manager.windowState(id: target)?.session else { return }
        guard session.isAvailableForDispatchReattachment else {
            ToastManager.shared.error("Chat is busy", message: "Stop the current turn before starting talk mode.")
            return
        }
        self.session = session
        agentID = id
        windowID = target
        lastError = nil
        isStarting = true
        NotificationCenter.default.post(name: .talkModeWillStart, object: nil)
        shouldResumeVAD = VADService.shared.state == .listening || VADService.shared.state == .starting
        let duplex = TalkAudioEngine()
        let gate = TalkSpeechGate(silenceMs: configuration.endOfTurnSilenceMs)
        self.duplex = duplex
        self.gate = gate
        startup = Task { [weak self] in
            guard let self else { return }
            do {
                await VADService.shared.pause()
                _ = await SpeechService.shared.stopStreamingTranscription(force: true)
                try Task.checkCancellation()
                self.captureSubscription = SpeechService.shared.talkEvents.sink { [weak self] in self?.receiveCapture($0) }
                let aec = try await SpeechService.shared.startTalkTranscription(
                    duplex: duplex, gate: gate, echoCancellation: self.configuration.echoCancellationEnabled)
                try Task.checkCancellation()
                self.aecActive = aec
                self.isStarting = false
                self.dispatch(.start(aec: aec))
                self.logger.info("capture started aec=\(aec)")
                self.startTicker()
            } catch {
                if !Task.isCancelled { self.fail(error.localizedDescription) }
            }
        }
    }

    public func stop() {
        guard isActive, !isStopping else { return }
        isStopping = true
        isStarting = false
        let startup = self.startup
        startup?.cancel()
        ticker?.cancel()
        ticker = nil
        captureSubscription = nil
        dispatch(.stop)
        // stop also covers cancellation during startup, before the reducer is on.
        cancelReply()
        Task { [weak self] in
            await startup?.value
            await SpeechService.shared.stopTalkTranscription()
            guard let self else { return }
            self.startup = nil
            self.duplex = nil
            self.gate = nil
            self.session = nil
            self.agentID = nil
            self.windowID = nil
            self.aecActive = false
            self.isStopping = false
            if self.shouldResumeVAD {
                self.shouldResumeVAD = false
                await VADService.shared.resumeAfterChat()
            }
        }
    }

    private func startTicker() {
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
                guard let self, self.state != .off else { return }
                guard let windowID = self.windowID,
                      let window = ChatWindowManager.shared.windowState(id: windowID),
                      window.session === self.session, window.activeAgent.id == self.agentID else {
                    self.stop()
                    return
                }
                self.dispatch(.tick(ProcessInfo.processInfo.systemUptime))
                // A rejected send or a cancelled warm-up may never enter isStreaming.
                if self.replyEpoch != nil, self.session?.isAvailableForDispatchReattachment == true, self.stream != nil {
                    self.stream?.finish()
                }
            }
        }
    }

    private func receiveCapture(_ event: TalkCaptureEvent) {
        switch event {
        case .activity(let segment, let active, let time):
            dispatch(active ? .speechStarted(segment: segment, at: time) : .speechEnded(segment: segment, at: time))
        case .partial(let segment, let text): dispatch(.partial(segment: segment, text: text))
        case .final(let segment, let text): dispatch(.final(segment: segment, text: text))
        case .failed(let message): fail(message)
        }
    }

    private func dispatch(_ event: TalkModeEvent) {
        let (next, effects) = TalkModeReducer.reduce(snapshot, event, config: configuration)
        snapshot = next
        if state != next.state { state = next.state }
        if caption != next.caption { caption = next.caption }
        gate?.update(aec: next.aecActive, playback: next.state == .speaking, ignoreUntil: next.ignoreUntil)
        for effect in effects {
            switch effect {
            case .cancelReply: cancelReply()
            case .send(let text, let epoch, let speechEnd): send(text, epoch: epoch, speechEnd: speechEnd)
            }
        }
    }

    private func cancelReply() {
        let start = ProcessInfo.processInfo.systemUptime
        let epoch = replyEpoch
        chatSubscription = nil
        ttsSubscription = nil
        stream?.cancel()
        stream = nil
        let stopped = ProcessInfo.processInfo.systemUptime
        if let epoch, snapshot.state == .userSpeaking || snapshot.state == .endOfTurn {
            let ms = (stopped - start) * 1000
            latency.update(epoch: epoch) { $0.bargeInToStopMs = ms }
            logger.info("epoch=\(epoch) barge_in_to_player_stop_ms=\(ms)")
        }
        if epoch != nil { session?.stop() }
        replyEpoch = nil
    }

    private func send(_ text: String, epoch: UInt64, speechEnd: TimeInterval) {
        guard let session, let duplex else { return }
        guard session.isAvailableForDispatchReattachment else { fail("The chat is busy. Restart talk mode when the current turn settles."); return }
        replyEpoch = epoch
        latency.begin(epoch: epoch, speechEnd: speechEnd)
        let handle = TTSService.shared.beginTalkStream(id: "talk-\(epoch)", duplex: duplex,
            voiceOverride: agentID.flatMap { AgentManager.shared.agent(for: $0)?.ttsVoice })
        stream = handle
        ttsSubscription = handle.events.sink { [weak self] event in
            guard let self, self.replyEpoch == epoch, self.snapshot.epoch == epoch else { return }
            let now = ProcessInfo.processInfo.systemUptime
            switch event {
            case .firstAudio:
                let ms = (now - speechEnd) * 1000
                self.latency.update(epoch: epoch) { $0.firstAudioMs = ms }
                self.logger.info("epoch=\(epoch) end_of_speech_to_first_audio_ms=\(ms)")
                self.dispatch(.firstAudio(epoch: epoch))
            case .finished:
                self.replyEpoch = nil
                self.chatSubscription = nil
                self.dispatch(.replyFinished(epoch: epoch, at: now))
            case .cancelled: self.fail("Talk playback was interrupted by another audio request.")
            case .failed(_, let message): self.fail(message)
            }
        }
        chatSubscription = session.rawAssistantDeltas.sink { [weak self, weak handle] event in
            guard let self, self.replyEpoch == epoch, self.snapshot.epoch == epoch else { return }
            switch event {
            case .delta(_, let text):
                if self.latency.turns.last?.firstTokenMs == nil {
                    let ms = (ProcessInfo.processInfo.systemUptime - speechEnd) * 1000
                    self.latency.update(epoch: epoch) { $0.firstTokenMs = ms }
                    self.logger.info("epoch=\(epoch) end_of_speech_to_first_token_ms=\(ms)")
                }
                handle?.enqueue(text: text)
            case .finished:
                if let message = session.lastStreamError { self.fail(message) }
                else { handle?.finish() }
            case .cancelled:
                self.stop()
            }
        }
        session.send(text, directUserSend: true)
        if session.isAvailableForDispatchReattachment { fail(session.lastStreamError ?? "The chat did not accept the voice turn.") }
    }

    private func fail(_ message: String) {
        lastError = message
        logger.error("talk failed: \(message, privacy: .public)")
        ToastManager.shared.error("Talk mode stopped", message: message)
        stop()
    }
}

extension Notification.Name {
    static let talkModeWillStart = Notification.Name("TalkModeWillStart")
}
