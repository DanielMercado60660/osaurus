import Foundation

@MainActor
public enum TalkModeConfigurationStore {
    private static var cached: TalkModeConfiguration?
    private static var url: URL { OsaurusPaths.voiceConfig().appendingPathComponent("talk.json") }

    public static func load() -> TalkModeConfiguration {
        if let cached { return cached }
        let config = (try? JSONDecoder().decode(TalkModeConfiguration.self, from: Data(contentsOf: url))) ?? .default
        cached = config
        return config
    }

    public static func save(_ configuration: TalkModeConfiguration) {
        do {
            OsaurusPaths.ensureExistsSilent(url.deletingLastPathComponent())
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(configuration).write(to: url, options: .atomic)
            cached = configuration
            NotificationCenter.default.post(name: .voiceConfigurationChanged, object: nil)
        } catch {
            ToastManager.shared.error("Cannot save talk settings", message: error.localizedDescription)
        }
    }
}
