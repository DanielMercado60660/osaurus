import Combine
import Foundation

/// Shared across chat windows so leaving the empty state cannot cancel setup.
/// Model tasks themselves remain owned by the existing download managers.
@MainActor
final class MakeItYoursSetup: ObservableObject {
    static let shared = MakeItYoursSetup()
    @Published private(set) var requestingMicrophone = false
    @Published private(set) var errors: [UUID: String] = [:]

    func enableTalk(for agentID: UUID) {
        guard !requestingMicrophone else { return }
        errors[agentID] = nil
        requestingMicrophone = true
        Task {
            defer { requestingMicrophone = false }
            guard await SpeechService.shared.requestMicrophonePermission() else {
                errors[agentID] = "Microphone access was denied or restricted. Allow Osaurus in System Settings → Privacy & Security → Microphone, then retry."
                return
            }
            // Load after the permission await: do not overwrite settings edited
            // in another window, and keep the clicked agent even if chat switches.
            var config = TalkModeConfigurationStore.load()
            if !config.enabledAgentIds.contains(agentID) { config.enabledAgentIds.append(agentID) }
            do {
                try TalkModeConfigurationStore.saveThrowing(config)
            } catch {
                errors[agentID] = error.localizedDescription
                return
            }
            let speech = SpeechModelManager.shared
            guard let model = speech.selectedModel else {
                errors[agentID] = "No Parakeet speech model is available. Check Voice → Voice Setup."
                return
            }
            if speech.effectiveDownloadState(for: model) != .completed {
                speech.downloadModel(model)
            }
            TTSService.shared.ensureModelLoaded()
        }
    }
}
