import Foundation
import FluidAudio
import Testing
@testable import OsaurusCore

struct PocketTTSResourcesTests {
    private func withHome(_ body: (URL) throws -> Void) throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try body(home)
    }

    private func populate(_ base: URL) throws {
        for artifact in PocketTTSResources.requiredArtifacts(in: PocketTTSResources.languageRoot(in: base)) {
            try FileManager.default.createDirectory(at: artifact, withIntermediateDirectories: true)
        }
    }

    @Test func matchesPinnedLoaderAndEnglishManager() {
        let base = URL(fileURLWithPath: "/cache")
        let root = PocketTTSResources.languageRoot(in: base)
        #expect(root.path == "/cache/Models/pocket-tts/v2.1/english")
        #expect(Set(PocketTTSResources.requiredArtifacts(in: root).map(\.lastPathComponent)) == [
            "cond_prefill.mlmodelc", "flowlm_step.mlmodelc", "flow_decoder_fused.mlmodelc",
            "mimi_decoder.mlmodelc", "constants_bin",
        ])
        let manager = PocketTtsManager(language: PocketTTSResources.language,
            directory: base, precision: PocketTTSResources.precision, placement: PocketTTSResources.placement)
        #expect(manager.language == .english)
    }

    @Test func sharedCacheIsReusedAndPreferred() throws {
        try withHome { home in
            let shared = PocketTTSResources.sharedCache(home: home)
            try populate(shared)
            try populate(PocketTTSResources.ownedCache(home: home))
            #expect(PocketTTSResources.cachedBase(home: home) == shared)
            #expect(PocketTTSResources.loadingBase(home: home) == shared)
        }
    }

    @Test func incompleteSharedPackUsesOwnedCacheWithoutDeletingVariants() throws {
        try withHome { home in
            let shared = PocketTTSResources.sharedCache(home: home)
            let owned = PocketTTSResources.ownedCache(home: home)
            try populate(shared)
            let root = PocketTTSResources.languageRoot(in: shared)
            try FileManager.default.removeItem(at: root.appendingPathComponent("cond_prefill.mlmodelc"))
            let otherProjectVariant = root.appendingPathComponent("flowlm_stepv2.mlmodelc")
            try FileManager.default.createDirectory(at: otherProjectVariant, withIntermediateDirectories: true)
            #expect(PocketTTSResources.cachedBase(home: home) == nil)
            #expect(PocketTTSResources.loadingBase(home: home) == owned)
            try populate(owned)
            #expect(PocketTTSResources.cachedBase(home: home) == owned)
            #expect(FileManager.default.fileExists(atPath: otherProjectVariant.path))
        }
    }

    @Test func legacyFlatAndV2PacksNeedMigrationAndRemainUntouched() throws {
        try withHome { home in
            let repo = PocketTTSResources.sharedCache(home: home).appendingPathComponent("Models/pocket-tts")
            for suffix in ["", "v2/english"] {
                for name in ["cond_step.mlmodelc", "flowlm_step.mlmodelc", "flow_decoder.mlmodelc",
                             "mimi_decoder_v2.mlmodelc", "constants_bin"] {
                    try FileManager.default.createDirectory(at: repo.appendingPathComponent(suffix)
                        .appendingPathComponent(name), withIntermediateDirectories: true)
                }
            }
            #expect(PocketTTSResources.cachedBase(home: home) == nil)
            #expect(PocketTTSResources.loadingBase(home: home) == PocketTTSResources.ownedCache(home: home))
            #expect(FileManager.default.fileExists(atPath: repo.appendingPathComponent("cond_step.mlmodelc").path))
            #expect(FileManager.default.fileExists(atPath: repo.appendingPathComponent("v2/english/cond_step.mlmodelc").path))
        }
    }

    @Test func wrongLanguageAndPlainFilesCannotSatisfyReadiness() throws {
        try withHome { home in
            let base = PocketTTSResources.sharedCache(home: home)
            try populate(base)
            let root = PocketTTSResources.languageRoot(in: base)
            try FileManager.default.moveItem(at: root, to: root.deletingLastPathComponent().appendingPathComponent("french_24l"))
            #expect(!PocketTTSResources.modelsExist(in: base))
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            for artifact in PocketTTSResources.requiredArtifacts(in: root) {
                try Data([1]).write(to: artifact)
            }
            #expect(!PocketTTSResources.modelsExist(in: base))
        }
    }

    @Test func residencyUsesOnlyTheLoadedV21Artifacts() {
        let root = URL(fileURLWithPath: "/cache/Models/pocket-tts/v2.1/english")
        #expect(SpeechModelMemory.ttsRoots(directory: root) == PocketTTSResources.requiredArtifacts(in: root))
        #expect(!SpeechModelMemory.ttsRoots(directory: root).contains { $0.lastPathComponent == "pocket_state.mlmodelc" })
    }

    @Test func parakeetAndSileroPathsRetainExistingDefaults() {
        #expect(Set(SpeechModelMemory.sttRoots(modelID: "v3").map(\.lastPathComponent)) == [
            "Preprocessor.mlmodelc", "Encoder.mlmodelc", "Decoder.mlmodelc", "JointDecisionv3.mlmodelc",
        ])
        #expect(Set(SpeechModelMemory.sttRoots(modelID: "v2").map(\.lastPathComponent)) == [
            "Preprocessor.mlmodelc", "Encoder.mlmodelc", "Decoder.mlmodelc", "JointDecision.mlmodelc",
        ])
        #expect(SpeechModelMemory.vadRoots.map(\.lastPathComponent) == ["silero-vad-unified-256ms-v6.0.0.mlmodelc"])
        #expect(SpeechModelMemory.sttRoots(modelID: "v3").allSatisfy {
            $0.deletingLastPathComponent() == AsrModels.defaultCacheDirectory(for: .v3)
        })
    }
}
