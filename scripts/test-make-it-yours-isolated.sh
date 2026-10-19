#!/usr/bin/env bash
# Copies production setup/card/catalog sources unchanged; app services are inert
# interface shims. This is deterministic unit/type-check proof, not a live app.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROOF="$ROOT/build/T05/isolated"
CORE="$ROOT/Packages/OsaurusCore"
mkdir -p "$PROOF/Sources/OsaurusCore" "$PROOF/Tests/OsaurusCoreTests" "$ROOT/build/T05/module-cache"
cat > "$PROOF/Package.swift" <<'SWIFT'
// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "MakeItYoursProof", platforms: [.macOS(.v15)], targets: [
    .target(name: "OsaurusCore"),
    .testTarget(name: "OsaurusCoreTests", dependencies: ["OsaurusCore"]),
])
SWIFT
for source in Services/Setup/MakeItYoursState.swift Services/Setup/MakeItYoursSetup.swift \
    Services/Setup/NotificationAuthorizationPolicy.swift Views/Chat/MakeItYoursCard.swift \
    Models/Voice/TalkModeConfiguration.swift Models/Voice/TalkModeConfigurationStore.swift \
    Models/Configuration/SettingsSearchIndex.swift Models/Configuration/ManagementTab.swift \
    Services/SearchService.swift AppleApps/AppleApp.swift; do
    cp "$CORE/$source" "$PROOF/Sources/OsaurusCore/"
done
cp "$CORE/Tests/Setup/MakeItYoursStateTests.swift" "$CORE/Tests/Configuration/SettingsSearchSelfFindProbe.swift" "$PROOF/Tests/OsaurusCoreTests/"
cat > "$PROOF/Sources/OsaurusCore/IntegrationShims.swift" <<'SWIFT'
import AppKit
import Combine
import SwiftUI
func L(_ text: String) -> String { text }
enum SystemPermission { case calendar, reminders, contacts, notes, automationMail, disk, automationMessages, location, automationMusic }
struct MLXModel { let name: String; let id: String; let description: String; let downloadURL: String }
struct SidebarItemData { let id: String; let icon: String; let label: String; let badge: Int?; let badgeHighlight: Bool }
enum OsaurusPaths {
    static func voiceConfig() -> URL { URL(fileURLWithPath: ProcessInfo.processInfo.environment["OSAURUS_TEST_ROOT"]!).appendingPathComponent("voice") }
    static func ensureExistsSilent(_ url: URL) { try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
}
@MainActor final class ToastManager { static let shared = ToastManager(); func error(_ title: String, message: String) {} }
extension Notification.Name { static let voiceConfigurationChanged = Self("voiceConfigurationChanged") }
@MainActor final class OnboardingService { static let shared = OnboardingService(); var shouldShowOnboarding = false }
struct SpeechModel { let id: String }
enum SpeechDownloadState: Equatable { case notStarted, downloading(progress: Double), completed, failed(error: String) }
@MainActor final class SpeechModelManager: ObservableObject {
    static let shared = SpeechModelManager()
    @Published var selectedModel: SpeechModel? = SpeechModel(id: "parakeet-tdt-0.6b-v3")
    func effectiveDownloadState(for model: SpeechModel) -> SpeechDownloadState { .notStarted }
    func downloadModel(_ model: SpeechModel) {}
}
@MainActor final class SpeechService: ObservableObject {
    static let shared = SpeechService()
    @Published var microphonePermissionGranted = false
    func checkMicrophonePermission() {}
    func requestMicrophonePermission() async -> Bool { false }
}
enum TTSModelState { case notReady, downloading(fraction: Double?), ready, failed(String) }
@MainActor final class TTSService: ObservableObject {
    static let shared = TTSService()
    @Published var modelState: TTSModelState = .notReady
    func ensureModelLoaded() {}
}
struct PhoneAccessState {
    enum Phase { case stopped, starting, needsLogin, running, failed }
    var phase: Phase = .stopped
    var error: String?
}
@MainActor final class TailscalePhoneAccessService: ObservableObject {
    static let shared = TailscalePhoneAccessService()
    @Published var state = PhoneAccessState()
}
enum AnimatedAvatarSetting { static let defaultsKey = "showAnimatedAgentAvatar" }
@MainActor final class AvatarOverlayWindowService { static let shared = AvatarOverlayWindowService(); func applyPreference() {} }
@MainActor final class ManagementStateManager { static let shared = ManagementStateManager(); var serverSectionRequest: String? }
@MainActor final class SettingsHighlightCoordinator { static let shared = SettingsHighlightCoordinator(); func request(_ id: String) {} }
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate { func showManagementWindow(initialTab: ManagementTab?) {} }
struct ProofTheme: Sendable { var secondaryText: Color { .secondary }; var secondaryBackground: Color { .gray.opacity(0.1) } }
private struct ThemeKey: EnvironmentKey { static let defaultValue = ProofTheme() }
extension EnvironmentValues { var theme: ProofTheme { get { self[ThemeKey.self] } set { self[ThemeKey.self] = newValue } } }
extension View { func settingsLandingAnchor(_ id: String?) -> some View { self } }
SWIFT
export GIT_TERMINAL_PROMPT=0 GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0=
export OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1
export OSAURUS_TEST_ROOT="$ROOT/build/T05/test-root"
export OSU_MODELS_DIR="$ROOT/build/T05/test-models"
export CLANG_MODULE_CACHE_PATH="$ROOT/build/T05/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$ROOT/build/T05/module-cache"
swift test --disable-keychain --disable-sandbox --package-path "$PROOF" \
    --cache-path "$ROOT/build/T05/swiftpm-cache" \
    --config-path "$ROOT/build/T05/swiftpm-config" \
    --security-path "$ROOT/build/T05/swiftpm-security" --jobs 4
