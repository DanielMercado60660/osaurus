#!/usr/bin/env bash
# Deterministic fallback when the full MLX/app dependency graph cannot build.
# Copies production sources unchanged; shims only unrelated app integration types.
set -euo pipefail
export GIT_TERMINAL_PROMPT=0 GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0=
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROOF="$ROOT/build/t04/isolated"
mkdir -p "$PROOF/Sources/OsaurusCore/Resources" "$PROOF/Tests/OsaurusCoreTests" "$ROOT/build/t04/module-cache"
cat > "$PROOF/Package.swift" <<'SWIFT'
// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "PhoneAccessProof", platforms: [.macOS(.v15)], targets: [
    .target(name: "OsaurusCore", resources: [.process("Resources")]),
    .testTarget(name: "OsaurusCoreTests", dependencies: ["OsaurusCore"]),
])
SWIFT
CORE="$ROOT/Packages/OsaurusCore"
# Remove a stale copy from pre-T10 isolated runs.
rm -f "$PROOF/Sources/OsaurusCore/PhoneAccessBuildPin.swift"
cp "$CORE/Services/LoginItemService.swift" "$PROOF/Sources/OsaurusCore/"
cp "$CORE/Tests/PhoneAccess/PhoneReachabilityTests.swift" "$PROOF/Tests/OsaurusCoreTests/"
cp "$CORE/Services/ScreenshotCaptureService.swift" "$PROOF/Sources/OsaurusCore/"
cp "$CORE"/Services/PhoneAccess/*.swift "$PROOF/Sources/OsaurusCore/"
cp "$CORE/Networking/PhoneWebAssets.swift" "$CORE/Models/Configuration/SettingsSearchIndex.swift" "$CORE/Models/Configuration/ManagementTab.swift" "$CORE/Services/SearchService.swift" "$CORE/Views/Settings/PhoneAccessSettingsCard.swift" "$PROOF/Sources/OsaurusCore/"
cp "$CORE/AppleApps/AppleApp.swift" "$PROOF/Sources/OsaurusCore/"
cp "$CORE"/Resources/Phone/* "$PROOF/Sources/OsaurusCore/Resources/"
cp "$CORE/Tests/PhoneAccess/PhoneScreenTests.swift" "$PROOF/Tests/OsaurusCoreTests/"
cp "$CORE/Tests/PhoneAccess/PhoneAccessTests.swift" "$CORE/Tests/Configuration/SettingsSearchSelfFindProbe.swift" "$PROOF/Tests/OsaurusCoreTests/"
cat > "$PROOF/Sources/OsaurusCore/IntegrationShims.swift" <<'SWIFT'
import Foundation
import SwiftUI
// These shims do not implement phone state, trust, status parsing or search.
enum OsaurusPaths {
    static func root() -> URL { URL(fileURLWithPath: ProcessInfo.processInfo.environment["OSAURUS_TEST_ROOT"]!) }
    static func contextArtifactsDir(contextId: String) -> URL { root().appendingPathComponent(contextId) }
}
// The real screen service, capture/encoding, settings and policy are compiled.
// No real permission query, capture, store singleton or status item is used by tests.
enum SystemPermissionProbe { static func screenRecordingGranted() -> Bool { false } }
struct SharedArtifact: Sendable, Equatable {
    enum ContextType: Sendable { case chat }
    let contextId: String; let contextType: ContextType; let filename: String
    let mimeType: String; let fileSize: Int; let hostPath: String; let isDirectory: Bool
    let content: String?; let description: String?; let isFinalResult: Bool; let createdAt: Date
}
struct EgressInfo {
    let destinationLabel: String?; let bytesSent: Int?; let dataClasses: [String]; let details: [String: String]
}
struct RequestLog {
    enum Source { case httpAPI }
    init(source: Source, method: String, path: String, statusCode: Int, durationMs: Double, egress: EgressInfo) {}
}
@MainActor final class InsightsService {
    static let shared = InsightsService()
    var durableStoreAvailable: Bool { false }
    func logDurably(_ request: RequestLog) async throws { throw CocoaError(.fileWriteUnknown) }
}
func L(_ text: String) -> String { text }
enum SystemPermission { case calendar, reminders, contacts, notes, automationMail, disk, automationMessages, location, automationMusic }
struct MLXModel { let name: String; let id: String; let description: String; let downloadURL: String }
struct SidebarItemData { let id: String; let icon: String; let label: String; let badge: Int?; let badgeHighlight: Bool }
@MainActor final class ServerController: ObservableObject { var isRunning = false; func startServer() async {} }
extension View { func settingsLandingAnchor(_ id: String?) -> some View { self } }
SWIFT
CLANG_MODULE_CACHE_PATH="$ROOT/build/t04/module-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$ROOT/build/t04/module-cache" \
OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1 \
OSU_MODELS_DIR="$ROOT/build/t04/empty-models" \
OSAURUS_TEST_ROOT="$ROOT/build/t04/test-root" \
swift test --disable-keychain --disable-sandbox --package-path "$PROOF"
