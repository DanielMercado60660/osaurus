#!/usr/bin/env bash
# Deterministic fallback when the full MLX/app dependency graph cannot build.
# Copies production sources unchanged; shims only unrelated app integration types.
set -euo pipefail
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
cp "$CORE"/Services/PhoneAccess/*.swift "$PROOF/Sources/OsaurusCore/"
cp "$CORE/Networking/PhoneWebAssets.swift" "$CORE/Models/Configuration/SettingsSearchIndex.swift" "$CORE/Models/Configuration/ManagementTab.swift" "$CORE/Services/SearchService.swift" "$CORE/Views/Settings/PhoneAccessSettingsCard.swift" "$PROOF/Sources/OsaurusCore/"
cp "$CORE/AppleApps/AppleApp.swift" "$PROOF/Sources/OsaurusCore/"
cp "$CORE"/Resources/Phone/* "$PROOF/Sources/OsaurusCore/Resources/"
cp "$CORE/Tests/PhoneAccess/PhoneAccessTests.swift" "$CORE/Tests/Configuration/SettingsSearchSelfFindProbe.swift" "$PROOF/Tests/OsaurusCoreTests/"
cat > "$PROOF/Sources/OsaurusCore/IntegrationShims.swift" <<'SWIFT'
import Foundation
import SwiftUI
// These shims do not implement phone state, trust, status parsing or search.
enum OsaurusPaths { static func root() -> URL { URL(fileURLWithPath: ProcessInfo.processInfo.environment["OSAURUS_TEST_ROOT"]!) } }
func L(_ text: String) -> String { text }
enum SystemPermission { case calendar, reminders, contacts, notes, automationMail, disk, automationMessages, location, automationMusic }
struct MLXModel { let name: String; let id: String; let description: String; let downloadURL: String }
struct SidebarItemData { let id: String; let icon: String; let label: String; let badge: Int?; let badgeHighlight: Bool }
@MainActor final class ServerController: ObservableObject { var isRunning = false; func startServer() async {} }
extension View { func settingsLandingAnchor(_ id: String?) -> some View { self } }
SWIFT
CLANG_MODULE_CACHE_PATH="$ROOT/build/t04/module-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$ROOT/build/t04/module-cache" \
OSAURUS_TEST_ROOT="$ROOT/build/t04/test-root" \
swift test --disable-sandbox --package-path "$PROOF"
