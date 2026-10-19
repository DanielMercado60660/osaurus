import AppKit
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

    // Presentation observation does not control capture, synthesis or playback.
    let avatarEvents = PassthroughSubject<(UUID, AvatarTalkEvent), Never>()
    private var restartWithoutWindow = false
    private(set) var usesCompanion = false

    private func publishAvatar(_ event: AvatarTalkEvent) {
        if let agentID { avatarEvents.send((agentID, event)) }
    }

    private let logger = Logger(subsystem: "ai.osaurus", category: "talk.mode")
    private var snapshot = TalkModeSnapshot()
    private var session: ChatSession?
    private var duplex: TalkAudioEngine?
    private var gate: TalkSpeechGate?
    private var stream: TTSStreamHandle?
    private var replyEpoch: UInt64?
    private var captureSubscription: AnyCancellable?
    private var chatSubscription: AnyCancellable?
    private var captionSubscription: AnyCancellable?
    private var ttsSubscription: AnyCancellable?
    private var configurationSubscription: AnyCancellable?
    private var startup: Task<Void, Never>?
    private var ticker: Task<Void, Never>?
    private var shouldResumeVAD = false
    private var restartRequest = TalkRestartRequest()
    private var benchmarkTask: Task<Void, Never>?
    private var benchmarkFinished = false
    private var benchmarkInterruptedRendering = false

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
        TalkModeHotKey.shared.register {
            if AvatarOverlayWindowService.shared.isVisible {
                AvatarOverlayWindowService.shared.toggleTalk()
            } else { TalkModeController.shared.toggle() }
        }
        initializeBenchmark()
    }

    func owns(_ session: ChatSession) -> Bool { isActive && self.session === session }

    func toggle(agentID requestedAgentID: UUID? = nil, windowID requestedWindowID: UUID? = nil, withoutWindow: Bool = false) {
        if isStopping {
            restartWithoutWindow = withoutWindow
            restartRequest.queue(agentID: requestedAgentID ?? agentID, windowID: requestedWindowID ?? windowID)
            return
        }
        if isActive { stop(); return }
        lastError = nil
        let manager = ChatWindowManager.shared
        let focused = (requestedWindowID ?? manager.lastFocusedWindowId).flatMap { manager.windowState(id: $0) }
        let id = requestedAgentID ?? focused?.activeAgent.id ?? AgentManager.shared.activeAgent.id
        guard configuration.enabledAgentIds.contains(id) || TalkBenchmarkConfiguration.inputRequested else {
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
        let revealWindow = !withoutWindow && !TalkBenchmarkConfiguration.inputRequested
        let target: UUID
        if let focused, focused.activeAgent.id == id {
            target = focused.windowId
            if revealWindow { manager.showWindow(id: target) }
        } else if let existing = manager.findWindows(byAgentId: id).first {
            target = existing.id
            if revealWindow { manager.showWindow(id: target) }
        } else {
            target = manager.createWindow(agentId: id, showImmediately: revealWindow)
        }
        guard let session = manager.windowState(id: target)?.session else { return }
        guard session.isAvailableForDispatchReattachment else {
            lastError = "Stop the current turn before starting talk mode."
            ToastManager.shared.error("Chat is busy", message: lastError!)
            return
        }
        self.session = session
        usesCompanion = withoutWindow
        agentID = id
        windowID = target
        lastError = nil
        TTSService.shared.stop()
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
                if ProcessInfo.processInfo.physicalMemory <= 16 << 30 {
                    let components = await SpeechModelMemory.talkComponents()
                    let decision = await ModelRuntime.shared.talkMemoryDecision(
                        modelName: session.selectedModel, local: session.selectedModelIsLocal, auxiliary: components)
                    try Task.checkCancellation()
                    if let message = decision.message {
                        self.logger.info("talk memory advisory=\(decision.outcome, privacy: .public) projected=\(decision.projectedBytes ?? 0)")
                        ToastManager.shared.info("Talk mode memory", message: message)
                    }
                }
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
                if !aec && self.configuration.echoCancellationEnabled && !duplex.usesFileInput {
                    ToastManager.shared.info("Talk mode", message: "Echo cancellation is unavailable for this audio route; using the selected microphone and default speaker.")
                }
                self.startTicker()
                if let config = try TalkBenchmarkConfiguration.parse(ProcessInfo.processInfo.environment) {
                    self.benchmarkTask = Task { await self.runBenchmark(config, duplex: duplex) }
                }
            } catch {
                if !Task.isCancelled { self.fail(error.localizedDescription) }
            }
        }
    }

    /// Dismissing or switching the companion also cancels a queued headless restart.
    func dismissCompanion() {
        if restartWithoutWindow { restartRequest = TalkRestartRequest() }
        if usesCompanion { stop() }
    }

    public func stop() {
        guard isActive, !isStopping else { return }
        isStopping = true
        isStarting = false
        let startup = self.startup
        startup?.cancel()
        benchmarkTask?.cancel()
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
            if self.shouldResumeVAD {
                self.shouldResumeVAD = false
                await VADService.shared.resumeAfterChat()
            }
            self.isStopping = false
            if let request = self.restartRequest.take() {
                self.toggle(agentID: request.agentID, windowID: request.windowID, withoutWindow: self.restartWithoutWindow)
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
                    if let message = self.session?.lastStreamError { self.recoverTurn(message) }
                    else { self.stream?.finish() }
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
        case .recognitionFailed(let segment, let message):
            publishAvatar(.reaction(.oops))
            lastError = message
            ToastManager.shared.error("Could not transcribe this turn", message: message)
            dispatch(.recognitionFailed(segment: segment))
        case .aecChanged(let active):
            let wasActive = aecActive
            aecActive = active
            dispatch(.aecChanged(active))
            if wasActive && !active {
                ToastManager.shared.info("Talk mode", message: "Echo cancellation is unavailable on the new route; talk mode is still listening.")
            }
        }
    }

    private func dispatch(_ event: TalkModeEvent) {
        let (next, effects) = TalkModeReducer.reduce(snapshot, event, config: configuration)
        if effects.contains(where: { if case .cancelReply = $0 { true } else { false } }),
           replyEpoch != nil, next.state == .userSpeaking || next.state == .endOfTurn {
            publishAvatar(.reaction(.surprised))
        }
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
        publishAvatar(.cleared)
        let start = ProcessInfo.processInfo.systemUptime
        let epoch = replyEpoch
        chatSubscription = nil
        ttsSubscription = nil
        captionSubscription = nil
        if epoch != nil, snapshot.state == .userSpeaking || snapshot.state == .endOfTurn,
           duplex?.isBenchmarkRendering == true {
            benchmarkInterruptedRendering = true
        }
        stream?.cancel()
        stream = nil
        let stopped = ProcessInfo.processInfo.systemUptime
        if let epoch, duplex?.usesFileInput == true,
           snapshot.state == .userSpeaking || snapshot.state == .endOfTurn {
            let ms = (stopped - start) * 1000
            latency.update(epoch: epoch) { $0.bargeInToStopMs = ms }
            logger.info("epoch=\(epoch) barge_in_to_player_stop_ms=\(ms)")
        }
        if epoch != nil { session?.stop() }
        replyEpoch = nil
    }

    private func send(_ text: String, epoch: UInt64, speechEnd: TimeInterval) {
        guard let session, let duplex else { return }
        guard session.isAvailableForDispatchReattachment else { recoverTurn("The previous chat turn is still settling. Please try again."); return }
        replyEpoch = epoch
        publishAvatar(.began(epoch))
        latency.begin(epoch: epoch, speechEnd: speechEnd)
        let handle = TTSService.shared.beginTalkStream(id: "talk-\(epoch)", duplex: duplex,
            voiceOverride: agentID.flatMap { AgentManager.shared.agent(for: $0)?.ttsVoice })
        stream = handle
        captionSubscription = handle.playedChunks.sink { [weak self] text in
            guard let self, self.replyEpoch == epoch, self.snapshot.epoch == epoch else { return }
            self.publishAvatar(.playback(text, epoch))
        }
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
                self.publishAvatar(.finished(epoch))
                self.publishAvatar(.reaction(.happy))
                self.replyEpoch = nil
                self.chatSubscription = nil
                self.dispatch(.replyFinished(epoch: epoch, at: now))
            case .cancelled: self.recoverTurn(nil)
            case .failed(_, let message): self.recoverTurn(message)
            }
        }
        chatSubscription = session.rawAssistantDeltas.sink { [weak self, weak handle] event in
            guard let self, self.replyEpoch == epoch, self.snapshot.epoch == epoch else { return }
            switch event {
            case .delta(_, let text):
                self.publishAvatar(.delta(text, epoch))
                if self.latency.turns.last?.firstTokenMs == nil {
                    let ms = (ProcessInfo.processInfo.systemUptime - speechEnd) * 1000
                    self.latency.update(epoch: epoch) { $0.firstTokenMs = ms }
                    self.logger.info("epoch=\(epoch) end_of_speech_to_first_token_ms=\(ms)")
                }
                handle?.enqueue(text: text)
            case .finished:
                if let message = session.lastStreamError { self.recoverTurn(message) }
                else { handle?.finish() }
            case .cancelled:
                self.recoverTurn(nil)
            }
        }
        session.send(text, directUserSend: true)
        if session.isAvailableForDispatchReattachment { recoverTurn(session.lastStreamError ?? "The chat did not accept the voice turn.") }
    }

    private func initializeBenchmark() {
        guard TalkBenchmarkConfiguration.inputRequested else { return }
        Task {
            do {
                guard let config = try TalkBenchmarkConfiguration.parse(ProcessInfo.processInfo.environment),
                      let selection = config.autostart else { return }
                let id: UUID
                switch selection { case .default: id = Agent.defaultId; case .id(let value): id = value }
                guard AgentManager.shared.agent(for: id) != nil else { throw TalkBenchmarkError("Unknown AUTOSTART agent: \(id)") }
                try await benchmarkWait(timeoutMs: config.timeoutMs, checkLifecycle: false) { TTSService.shared.isModelReady }
                toggle(agentID: id)
                try await benchmarkWait(timeoutMs: config.timeoutMs, checkLifecycle: false) { !self.isStarting }
                guard self.state != .off else { throw TalkBenchmarkError(self.lastError ?? "Talk startup failed") }
            } catch { finishBenchmark(error: error.localizedDescription, bargeInAttempted: false) }
        }
    }

    private func benchmarkWait(timeoutMs: Int, checkLifecycle: Bool = true, until predicate: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + Double(timeoutMs) / 1000
        while !predicate() {
            try Task.checkCancellation()
            if checkLifecycle && (state == .off || isStopping) { throw TalkBenchmarkError(lastError ?? "Talk stopped before input completed") }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw TalkBenchmarkError("Timed out waiting for talk startup, recognition, or reply") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func runBenchmark(_ config: TalkBenchmarkConfiguration, duplex: TalkAudioEngine) async {
        var bargeInAttempted = false
        do {
            // Fresh history for this run; epochs still come from the real reducer.
            latency = TalkLatencyHistory()
            for (index, url) in config.inputs.enumerated() {
                let previousTurns = latency.turns.count
                try await duplex.playInput(url, leadingMs: index == 1 && config.bargeInAfterMs != nil ? 0 : config.leadingSilenceMs,
                                           trailingMs: config.trailingSilenceMs)
                if index == 0, config.inputs.count > 1, let delay = config.bargeInAfterMs {
                    try await benchmarkWait(timeoutMs: config.timeoutMs) {
                        self.latency.turns.count > previousTurns && self.latency.turns.last?.firstAudioMs != nil
                    }
                    if let turn = latency.turns.last, let firstAudioMs = turn.firstAudioMs {
                        let remaining = turn.speechEnd + (firstAudioMs + Double(delay)) / 1000 - ProcessInfo.processInfo.systemUptime
                        if remaining > 0 { try await Task.sleep(for: .seconds(remaining)) }
                    }
                    // Only call it an attempted playback interruption if audio is still playing.
                    bargeInAttempted = state == .speaking && duplex.isBenchmarkRendering
                } else {
                    try await benchmarkWait(timeoutMs: config.timeoutMs) {
                        self.latency.turns.count > previousTurns && self.state == .listening
                            && self.session?.isAvailableForDispatchReattachment == true
                    }
                }
            }
            finishBenchmark(error: lastError, bargeInAttempted: bargeInAttempted)
        } catch { finishBenchmark(error: lastError ?? error.localizedDescription, bargeInAttempted: bargeInAttempted) }
    }

    private func finishBenchmark(error: String?, bargeInAttempted: Bool) {
        guard !benchmarkFinished else { return }
        benchmarkFinished = true
        // The history stays compatible with the T03 summarizer. A sidecar records
        // failures/missed barge-in separately; missing samples are never zero-filled.
        let env = ProcessInfo.processInfo.environment
        if let path = env["OSAURUS_TALK_METRICS_OUT"], path.hasPrefix("/") {
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(latency.turns).write(to: URL(fileURLWithPath: path), options: .atomic)
                let status: [String: Any] = ["error": error as Any? ?? NSNull(),
                    "bargeInAttempted": bargeInAttempted,
                    "bargeInObserved": benchmarkInterruptedRendering && latency.turns.contains { $0.bargeInToStopMs != nil },
                    "inputCount": env["OSAURUS_TALK_INPUT_WAV"]?.split(separator: ",").count ?? 0,
                    "evidence": "Real VAD/ASR/chat/TTS; paced null sink. First audio is buffer completion; barge-in is confirmed interruption to sink stop. No acoustic proof."]
                try JSONSerialization.data(withJSONObject: status, options: [.prettyPrinted, .sortedKeys])
                    .write(to: URL(fileURLWithPath: path + ".status.json"), options: .atomic)
            } catch { NSLog("[TalkBenchmark] Cannot write metrics: %@", error.localizedDescription) }
        }
        if let error { NSLog("[TalkBenchmark] Failed: %@", error) }
        stop()
        Task {
            while isStopping { try? await Task.sleep(for: .milliseconds(20)) }
            NSApplication.shared.terminate(nil)
        }
    }

    private func recoverTurn(_ message: String?) {
        publishAvatar(.reaction(.oops))
        if let message {
            lastError = message
            ToastManager.shared.error("Talk reply interrupted", message: message)
        }
        dispatch(.turnFailed(epoch: snapshot.epoch))
    }

    private func fail(_ message: String) {
        publishAvatar(.reaction(.oops))
        lastError = message
        logger.error("talk failed: \(message, privacy: .public)")
        ToastManager.shared.error("Talk mode stopped", message: message)
        stop()
    }
}

extension Notification.Name {
    static let talkModeWillStart = Notification.Name("TalkModeWillStart")
}
