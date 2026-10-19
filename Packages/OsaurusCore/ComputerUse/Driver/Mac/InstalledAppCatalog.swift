import AppKit
import Foundation

/// LaunchServices candidates plus installed bundles. No app-name aliases:
/// localized names come from Finder and each bundle's InfoPlist.strings.
/// Called on the AX background queue, never while blocking the main actor.
func resolveInstalledApplication(_ identifier: String) -> URL? {
    let workspace = NSWorkspace.shared
    let fm = FileManager.default
    var urls = Set(workspace.runningApplications.compactMap(\.bundleURL))
    if let url = workspace.urlForApplication(withBundleIdentifier: identifier) { urls.insert(url) }
    // LaunchServices also knows apps outside the standard installation roots.
    if let path = workspace.fullPath(forApplication: identifier) { urls.insert(URL(fileURLWithPath: path)) }
    let expanded = (identifier as NSString).expandingTildeInPath
    if expanded.hasPrefix("/"), fm.fileExists(atPath: expanded) {
        urls.insert(URL(fileURLWithPath: expanded))
    }
    let roots = ["/Applications", "/System/Applications", "/System/Library/CoreServices", NSHomeDirectory() + "/Applications"]
    for root in roots {
        guard let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: root), includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { continue }
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "app" {
            urls.insert(url)
        }
    }
    let catalog = urls.compactMap { CUAppCatalogEntry.read(at: $0) }
    return CUAppResolver.resolve(identifier, in: catalog)?.url
}
