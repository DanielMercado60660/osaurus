import Foundation
import FluidAudio

/// One model contract for loading, readiness and residency accounting.
/// `directory` in FluidAudio is the cache base, not the language-pack root.
enum PocketTTSResources {
    static let language: PocketTtsLanguage = .english
    static let precision: PocketTtsPrecision = .fp16
    static let placement: PocketTtsModelPlacement = .gpu

    static func sharedCache(home: URL) -> URL {
        home.appendingPathComponent(".cache/fluidaudio", isDirectory: true)
    }

    static func ownedCache(home: URL) -> URL {
        home.appendingPathComponent(".cache/osaurus/fluidaudio", isDirectory: true)
    }

    static func languageRoot(in cache: URL) -> URL {
        cache.appendingPathComponent(PocketTtsConstants.defaultModelsSubdirectory, isDirectory: true)
            .appendingPathComponent(Repo.pocketTts.folderName, isDirectory: true)
            .appendingPathComponent(language.repoSubdirectory, isDirectory: true)
    }

    static func requiredArtifacts(in languageRoot: URL) -> [URL] {
        ModelNames.PocketTTS.requiredModels(precision: precision, placement: placement)
            .sorted().map { languageRoot.appendingPathComponent($0, isDirectory: true) }
    }

    /// Presence probe only; CoreML and the constants loader still validate contents.
    static func modelsExist(in cache: URL) -> Bool {
        requiredArtifacts(in: languageRoot(in: cache)).allSatisfy {
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: $0.path, isDirectory: &isDirectory)
                && isDirectory.boolValue
        }
    }

    static func cachedBase(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        [sharedCache(home: home), ownedCache(home: home)].first { modelsExist(in: $0) }
    }

    /// Reuse a complete shared pack. Never run FluidAudio's repair/download
    /// cleanup on a partial shared pack: it removes unused precision variants.
    /// Old flat/v2 packs stay untouched; migration downloads v2.1 once here.
    static func loadingBase(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        cachedBase(home: home) ?? ownedCache(home: home)
    }
}
