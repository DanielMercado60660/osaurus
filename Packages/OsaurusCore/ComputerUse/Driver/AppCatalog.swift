import Foundation

/// Metadata-only lookup, independent of AppKit and the running app state.
/// Identity wins over display names; equal matches are ordered by bundle id,
/// then canonical path, so filesystem/LaunchServices enumeration order cannot
/// decide which app a localized name opens.
struct CUAppCatalogEntry: Sendable, Equatable {
    let url: URL
    let bundleIdentifier: String?
    let executableName: String?
    let displayNames: [String]

    static func read(at url: URL, preferredLanguages: [String] = Locale.preferredLanguages) -> Self? {
        guard url.pathExtension.lowercased() == "app", let bundle = Bundle(url: url) else { return nil }
        let keys = ["CFBundleDisplayName", "CFBundleName"]
        var names = [
            FileManager.default.displayName(atPath: url.path),
            url.deletingPathExtension().lastPathComponent,
        ]
        for key in keys {
            if let name = bundle.infoDictionary?[key] as? String { names.append(name) }
            if let name = bundle.localizedInfoDictionary?[key] as? String { names.append(name) }
        }
        // Resolve each preference separately: preferredLocalizations with the
        // entire list returns only the best match, losing secondary languages.
        // Recent system apps package InfoPlist translations in a single
        // .loctable instead of per-language .strings files.
        let table = bundle.url(forResource: "InfoPlist", withExtension: "loctable")
            .flatMap(readPlist) ?? [:]
        let available = Set(bundle.localizations + table.keys).sorted()
        let localizations = Set(preferredLanguages.flatMap {
            Bundle.preferredLocalizations(from: available, forPreferences: [$0])
        })
        for localization in localizations {
            let strings = bundle.url(
                forResource: "InfoPlist", withExtension: "strings", subdirectory: nil, localization: localization
            ).flatMap(readPlist) ?? [:]
            for key in keys {
                if let name = strings[key] as? String { names.append(name) }
                if let name = (table[localization] as? [String: Any])?[key] as? String { names.append(name) }
            }
        }
        return Self(
            url: url.standardizedFileURL,
            bundleIdentifier: bundle.bundleIdentifier,
            executableName: bundle.infoDictionary?["CFBundleExecutable"] as? String,
            displayNames: Array(Set(names)).sorted()
        )
    }

    private static func readPlist(_ url: URL) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: url.path) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }
}

enum CUAppResolver {
    static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .precomposedStringWithCanonicalMapping
    }

    static func resolve(_ identifier: String, in catalog: [CUAppCatalogEntry]) -> CUAppCatalogEntry? {
        let needle = normalized(identifier)
        guard !needle.isEmpty else { return nil }
        let path = (identifier as NSString).expandingTildeInPath
        func rank(_ entry: CUAppCatalogEntry) -> Int? {
            if path.hasPrefix("/"), URL(fileURLWithPath: path).standardizedFileURL == entry.url { return 0 }
            if entry.bundleIdentifier.map(normalized) == needle { return 1 }
            if entry.displayNames.contains(where: { normalized($0) == needle }) { return 2 }
            if entry.executableName.map(normalized) == needle { return 3 }
            return nil
        }
        return catalog.compactMap { entry -> (CUAppCatalogEntry, Int)? in
            rank(entry).map { (entry, $0) }
        }.sorted {
            if $0.1 != $1.1 { return $0.1 < $1.1 }
            let lhs = normalized($0.0.bundleIdentifier ?? "")
            let rhs = normalized($1.0.bundleIdentifier ?? "")
            if lhs != rhs { return lhs < rhs }
            return $0.0.url.path < $1.0.url.path
        }.first?.0
    }
}
