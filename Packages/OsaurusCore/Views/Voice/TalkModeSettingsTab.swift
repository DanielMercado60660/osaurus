import AppKit
import SwiftUI

struct TalkModeSettingsTab: View {
    @ObservedObject private var agents = AgentManager.shared
    @State private var config = TalkModeConfigurationStore.load()
    @Environment(\.theme) private var theme
    @Environment(\.settingsLandingPending) private var pendingLanding

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("Talk Mode").font(.title2.bold())
                    Text("Hands-free conversation with your current agent. Toggle from chat or press ⌃⌥⌘T. Requires a configured microphone, speech model, and Text To Speech engine.")
                        .foregroundStyle(theme.secondaryText)
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Enabled for Agent").font(.headline)
                        ForEach(agents.agents) { agent in
                            Toggle(agent.name, isOn: Binding(
                                get: { config.enabledAgentIds.contains(agent.id) },
                                set: { enabled in
                                    config.enabledAgentIds.removeAll { $0 == agent.id }
                                    if enabled { config.enabledAgentIds.append(agent.id) }
                                }))
                        }
                    }
                    .settingsLandingAnchor("voice.talk.agents")
                    VStack(alignment: .leading) {
                        Text("End of Turn Silence").font(.headline)
                        Slider(value: Binding(get: { Double(config.endOfTurnSilenceMs) },
                                              set: { config.endOfTurnSilenceMs = Int($0) }),
                               in: 300...3000, step: 100)
                        Text("\(config.endOfTurnSilenceMs) ms")
                    }
                    .settingsLandingAnchor("voice.talk.silence")
                    Toggle("Allow Barge-In", isOn: $config.bargeInEnabled)
                        .settingsLandingAnchor("voice.talk.bargeIn")
                    Toggle("Echo Cancellation", isOn: $config.echoCancellationEnabled)
                        .settingsLandingAnchor("voice.talk.echo")
                    TalkThinkingSetting(isOn: $config.thinkBeforeSpeaking)
                        .settingsLandingAnchor("voice.talk.thinking")
                    Toggle("Show Captions", isOn: $config.showCaptions)
                        .settingsLandingAnchor("voice.talk.captions")
                    Text("Changes save automatically. Changing silence or echo cancellation stops an active conversation; toggle talk mode again to apply. If voice processing is unavailable, talk mode uses a higher speech threshold during playback and a 300 ms echo cooldown.")
                        .font(.caption).foregroundStyle(theme.secondaryText)
                }
                .padding(24)
            }
            .task(id: pendingLanding) {
                guard let id = pendingLanding, id.hasPrefix("voice.talk.") else { return }
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                withAnimation { proxy.scrollTo(id, anchor: .center) }
            }
        }
        .onAppear { config = TalkModeConfigurationStore.load() }
        // The empty-chat setup card can enable an agent while Settings stays
        // open. Refresh this editor so its next change preserves that update.
        .onReceive(NotificationCenter.default.publisher(for: .voiceConfigurationChanged)) { _ in
            config = TalkModeConfigurationStore.load()
        }
        .onChange(of: config) { _, value in TalkModeConfigurationStore.save(value) }
    }
}

/// Local observation avoids re-rendering the entire composer at caption cadence.
struct TalkModeComposerControl: View {
    let agentID: UUID?
    let windowID: UUID?
    @ObservedObject private var talk = TalkModeController.shared
    @State private var showMetrics = false

    private var ownsWindow: Bool { talk.windowID == windowID && talk.isActive }
    var body: some View {
        HStack(spacing: 8) {
            if ownsWindow {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(talk.isStarting ? "Starting…" : talk.isStopping ? "Stopping…" : stateLabel)
                        .font(.caption)
                    if talk.configuration.showCaptions && !talk.caption.isEmpty {
                        Text(talk.caption).font(.caption).lineLimit(2).frame(maxWidth: 220)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            #if DEBUG
            if ownsWindow {
                Button { showMetrics.toggle() } label: { Image(systemName: "gauge.with.dots.needle.33percent") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Talk latency metrics")
                    .popover(isPresented: $showMetrics) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Talk latency • \(talk.latency.turns.count) turns").font(.headline)
                            Text(talk.aecActive ? "Voice processing active" : "Echo fallback active")
                            Text(metric("First token", \.firstTokenMs))
                            Text(metric("First audio buffer", \.firstAudioMs))
                            Text(metric("Barge-in to player stop", \.bargeInToStopMs))
                            Text("Software timings; acoustic latency is unverified.").font(.caption)
                            Button("Copy latency JSON") {
                                if let data = try? JSONEncoder().encode(talk.latency.turns),
                                   let json = String(data: data, encoding: .utf8) {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(json, forType: .string)
                                }
                            }
                        }.padding()
                    }
            }
            #endif
            Button { talk.toggle(agentID: agentID, windowID: windowID) } label: {
                Image(systemName: ownsWindow ? "waveform.circle.fill" : "waveform.circle")
                    .font(.system(size: 20))
            }
            .buttonStyle(.plain)
            .disabled(talk.isStopping)
            .accessibilityLabel(talk.isActive ? "Stop talk mode" : "Start talk mode")
            .help("Talk mode (⌃⌥⌘T)")
        }
    }
    private func metric(_ title: String, _ key: KeyPath<TalkTurnLatency, Double?>) -> String {
        guard let values = talk.latency.percentiles(key) else { return "\(title): no samples" }
        return "\(title): p50 \(Int(values.p50)) ms / p90 \(Int(values.p90)) ms"
    }
    private var stateLabel: String {
        switch talk.state {
        case .off: "Off"
        case .listening: "Listening"
        case .userSpeaking: "Hearing you"
        case .endOfTurn: "Transcribing"
        case .thinking: "Thinking"
        case .speaking: "Speaking"
        }
    }
}

/// The most recently focused chat is the same surface used by the talk shortcut.
private struct TalkThinkingSetting: View {
    @Binding var isOn: Bool
    @ObservedObject private var windows = ChatWindowManager.shared
    @ObservedObject private var talk = TalkModeController.shared
    private var windowID: UUID? { talk.isActive ? talk.windowID : windows.lastFocusedWindowId }
    var body: some View {
        VStack(alignment: .leading) {
            Toggle("Think before speaking", isOn: $isOn)
            if let id = windowID, let state = windows.windowState(id: id) {
                TalkThinkingCaption(session: state.session)
            } else {
                Text("Off skips thinking when the model supports it. On uses the model's default. Open a chat to inspect its model.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct TalkThinkingCaption: View {
    @ObservedObject var session: ChatSession
    @State private var capability: LocalReasoningCapability.Capability?
    var body: some View {
        Text(TalkThinkingPolicy.caption(supportsThinking: capability?.supportsThinking,
                                       toggleable: capability?.isToggleableThinking == true))
            .font(.caption).foregroundStyle(.secondary)
            .task(id: session.selectedModel) {
                capability = nil
                guard session.selectedModelIsLocal, let id = session.selectedModel else { return }
                let resolved = await LocalReasoningCapability.resolveForDispatch(modelId: id)
                guard !Task.isCancelled, session.selectedModel == id else { return }
                capability = resolved
            }
    }
}
