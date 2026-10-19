import Foundation
import FluidAudio

/// Artifact paths come from the pinned FluidAudio loader, not model-size or
/// admission allowlists. Use precisely the compiled models that loader uses.
enum SpeechModelMemory {
    static func sttRoots(modelID: String) -> [URL] {
        let version: AsrModelVersion = modelID == "v2" ? .v2 : .v3
        let directory = AsrModels.defaultCacheDirectory(for: version)
        let names = version == .v3 ? ModelNames.ASR.requiredModelsV3 : ModelNames.ASR.requiredModels
        return names.map { directory.appendingPathComponent($0) }
    }
    static var vadRoots: [URL] {
        let directory = MLModelConfigurationUtils.defaultModelsDirectory(for: .vad)
        return ModelNames.VAD.requiredModels.map { directory.appendingPathComponent($0) }
    }
    static func ttsRoots(directory: URL) -> [URL] {
        ModelNames.PocketTTS.requiredModels.map { directory.appendingPathComponent($0) }
    }

    @MainActor
    static func track(_ owner: AnyObject, kind: AuxiliaryModelResidency.Kind, roots: [URL]) async {
        let estimate = await Task.detached(priority: .utility) { AuxiliaryModelEstimate.bytes(at: roots) }.value
        AuxiliaryModelResidency.shared.track(owner, kind: kind, estimatedBytes: estimate)
    }

    @MainActor
    static func talkComponents() async -> [TalkMemoryBudget.Component] {
        let modelID = SpeechModelManager.shared.selectedModel?.id
        let roots = modelID.map(sttRoots)
        let vad = vadRoots
        let estimates = await Task.detached(priority: .utility) {
            (roots.flatMap { AuxiliaryModelEstimate.bytes(at: $0) }, AuxiliaryModelEstimate.bytes(at: vad))
        }.value
        let residents = AuxiliaryModelResidency.shared.snapshot()
        var components = residents.map {
            TalkMemoryBudget.Component(role: $0.kind.rawValue, estimatedBytes: $0.estimatedBytes, resident: true)
        }
        // STT owns VAD; every input mode reuses that pair, including Talk.
        // A draining worker may still retain the previous pair even after
        // unloadModel. It cannot satisfy a new capture's load requirement.
        if !SpeechService.shared.isModelLoaded {
            components.append(.init(role: "stt", estimatedBytes: estimates.0, resident: false))
            components.append(.init(role: "vad", estimatedBytes: estimates.1, resident: false))
        }
        // Talk already requires TTS ready. Remote TTS has no local resident;
        // a cached local manager is still charged even after switching remote.
        return components
    }
}
