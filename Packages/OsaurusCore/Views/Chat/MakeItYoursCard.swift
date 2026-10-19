import AppKit
import SwiftUI

struct MakeItYoursCard: View {
    let agentID: UUID
    @AppStorage("hasCompletedOnboarding") private var onboardingComplete = false
    @AppStorage("onboardingVersion") private var onboardingVersion = 0
    @AppStorage(MakeItYoursPreference.dismissedKey) private var dismissed = false
    @AppStorage(AnimatedAvatarSetting.defaultsKey) private var companionEnabled = false
    @ObservedObject private var setup = MakeItYoursSetup.shared
    @ObservedObject private var speech = SpeechModelManager.shared
    @ObservedObject private var microphone = SpeechService.shared
    @ObservedObject private var tts = TTSService.shared
    @ObservedObject private var phone = TailscalePhoneAccessService.shared
    @State private var talkConfig = TalkModeConfigurationStore.load()
    @Environment(\.theme) private var theme

    private var speechRow: MakeItYoursState.Row {
        guard let model = speech.selectedModel else { return .pending }
        switch speech.effectiveDownloadState(for: model) {
        case .notStarted: return .pending
        case .completed: return .done
        // FluidAudio's Parakeet manager currently reports no byte progress.
        case .downloading: return .inProgress(nil)
        case .failed(let error): return .failed("Parakeet: \(error)")
        }
    }

    private var voiceRow: MakeItYoursState.Row {
        switch tts.modelState {
        case .notReady: return .pending
        case .ready: return .done
        case .downloading(let fraction): return .inProgress(fraction)
        case .failed(let error): return .failed("PocketTTS: \(error)")
        }
    }

    private var phoneRow: MakeItYoursState.Row {
        switch phone.state.phase {
        case .running: return .done
        case .starting: return .inProgress(nil)
        case .failed: return .failed(phone.state.error ?? "Phone access failed")
        case .stopped, .needsLogin: return .pending
        }
    }

    private var state: MakeItYoursState {
        MakeItYoursState(
            onboardingComplete: onboardingComplete && onboardingVersion > 0
                && !OnboardingService.shared.shouldShowOnboarding,
            dismissed: dismissed, speech: speechRow, voice: voiceRow,
            microphoneGranted: microphone.microphonePermissionGranted,
            agentEnabled: talkConfig.enabledAgentIds.contains(agentID),
            requestingMicrophone: setup.requestingMicrophone,
            setupError: setup.errors[agentID], companionEnabled: companionEnabled, phone: phoneRow
        )
    }

    var body: some View {
        Group {
            if state.isVisible {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("Make it yours").font(.headline)
                        Spacer()
                        Button("Not now") { dismissed = true }
                            .buttonStyle(.plain)
                            .foregroundStyle(theme.secondaryText)
                            .settingsLandingAnchor("settings.chat.makeItYours")
                    }
                    row("Talk to it", icon: "waveform", status: state.talk,
                        detail: "Parakeet (~600 MB) + PocketTTS on this Mac. Talk shortcut: ⌃⌥⌘T.",
                        anchor: "voice.talk.agents",
                        allowsActionWhileBusy: !state.agentEnabled && !setup.requestingMicrophone) {
                        setup.enableTalk(for: agentID)
                    }
                    if case .inProgress = state.talk {
                        Text("Parakeet: \(modelStatus(speechRow)) · PocketTTS: \(modelStatus(voiceRow))")
                            .font(.caption).foregroundStyle(theme.secondaryText)
                    }
                    row("Show your companion", icon: "sparkles", status: state.companion,
                        detail: "An animated companion on your desktop.",
                        anchor: "settings.chat.animatedAvatar") {
                        companionEnabled = true
                        AvatarOverlayWindowService.shared.applyPreference()
                    }
                    row("Reach it from your phone", icon: "iphone", status: state.phone,
                        detail: phone.state.phase == .needsLogin
                            ? "Finish signing in to Tailscale in Settings."
                            : "Open Phone access to connect with Tailscale.",
                        anchor: "server.phoneAccess", allowsActionWhileBusy: true) { openPhoneSettings() }
                }
                .padding(20)
                .background(theme.secondaryBackground, in: RoundedRectangle(cornerRadius: 16))
                .frame(maxWidth: 520)
                .padding(.horizontal, 24)
                .padding(.top, 20)
            }
        }
        .onAppear { refreshConfiguration() }
        .onReceive(NotificationCenter.default.publisher(for: .voiceConfigurationChanged)) { _ in
            refreshConfiguration()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshConfiguration()
        }
    }

    private func refreshConfiguration() {
        talkConfig = TalkModeConfigurationStore.load()
        microphone.checkMicrophonePermission()
    }

    private func modelStatus(_ row: MakeItYoursState.Row) -> String {
        switch row {
        case .done: return "ready"
        case .inProgress(let fraction):
            if let fraction, fraction.isFinite { return "\(Int(min(1, max(0, fraction)) * 100))%" }
            return "preparing…"
        case .pending: return "not downloaded"
        case .failed: return "failed"
        }
    }

    private func row(_ title: String, icon: String, status: MakeItYoursState.Row,
                     detail: String, anchor: String, allowsActionWhileBusy: Bool = false,
                     action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: status == .done ? "checkmark.circle.fill" : icon)
                    .foregroundStyle(status == .done ? Color.green : theme.secondaryText)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    if status == .done {
                        Text("\(title) — Done").font(.subheadline.bold())
                    } else {
                        Button(action: action) { Text(title).fontWeight(.semibold) }
                            .buttonStyle(.borderedProminent)
                            .disabled(isBusy(status) && !allowsActionWhileBusy)
                            .settingsLandingAnchor(anchor)
                            .accessibilityHint(isFailed(status) ? "Retry setup" : detail)
                    }
                    Text(detail).font(.caption).foregroundStyle(theme.secondaryText)
                }
                Spacer(minLength: 0)
            }
            if case .inProgress(let fraction) = status {
                if let fraction {
                    ProgressView(value: fraction).accessibilityLabel("Combined model preparation")
                } else {
                    ProgressView().controlSize(.small).accessibilityLabel("Setup in progress")
                }
            }
            if case .failed(let error) = status {
                Text("\(error) Click \(title) to retry.").font(.caption).foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
    }

    private func isBusy(_ row: MakeItYoursState.Row) -> Bool {
        if case .inProgress = row { return true }; return false
    }
    private func isFailed(_ row: MakeItYoursState.Row) -> Bool {
        if case .failed = row { return true }; return false
    }

    private func openPhoneSettings() {
        guard let entry = SettingsSearchIndex.entries.first(where: { $0.id == "server.phoneAccess" }) else { return }
        ManagementStateManager.shared.serverSectionRequest = entry.subTab
        SettingsHighlightCoordinator.shared.request(entry.id)
        (NSApp.delegate as? AppDelegate)?.showManagementWindow(initialTab: entry.tab)
    }
}
