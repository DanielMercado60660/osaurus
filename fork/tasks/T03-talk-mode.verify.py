#!/usr/bin/env python3
"""Build a dependency-free T03 proof package. Run with --run to execute tests.

Production files are copied, not rewritten; the existing chunker and speech
worker are extracted at their declaration boundaries. ProofStubs contains inert
app/provider dependencies solely for typechecking. No model, microphone, keychain,
network, or real app is exercised. This is deliberately not full-app proof.
"""
from pathlib import Path
import shutil
root=Path(__file__).resolve().parents[2]; core=root/'Packages/OsaurusCore'; dest=root/'build/t03-harness'; src=dest/'Sources/OsaurusCore'; tests=dest/'Tests/OsaurusCoreTests'
src.mkdir(parents=True,exist_ok=True); tests.mkdir(parents=True,exist_ok=True)
(dest/'Package.swift').write_text('''// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "TalkModeProof", platforms: [.macOS(.v15)], targets: [
.target(name: "OsaurusCore"), .testTarget(name: "OsaurusCoreTests", dependencies: ["OsaurusCore"])])
''')
for f in ['Services/Voice/SmartTurn/SmartTurnFeatures.swift','Services/Voice/SmartTurn/TalkSmartTurnPolicy.swift','Services/Voice/SmartTurn/SmartTurnResources.swift','Services/Chat/ChatTurnGenerationControls.swift','Services/Avatar/AvatarMood.swift','Services/Avatar/AvatarPresentation.swift','Services/Voice/TalkModeReducer.swift','Models/Voice/TalkModeConfiguration.swift','Services/Voice/TTSStream.swift','Services/Voice/TalkAudioEngine.swift','Services/Voice/TalkBenchmarkConfiguration.swift','Services/Voice/TalkBenchmarkAudio.swift','Services/Voice/MarkdownStripper.swift','Utils/StreamingDeltaProcessor.swift','Models/Configuration/SettingsSearchIndex.swift','Models/Configuration/ManagementTab.swift','AppleApps/AppleApp.swift','Services/SearchService.swift']:
    shutil.copy(core/f,src/Path(f).name)
s=(core/'Managers/TTSService.swift').read_text(); chunk=s[s.index('enum TTSTextChunker {'):s.index('\nextension Notification.Name',s.index('enum TTSTextChunker {'))]; (src/'TTSTextChunker.swift').write_text('import Foundation\n'+chunk)
for f in ['Voice/SmartTurnTests.swift','Voice/TalkLatencyTests.swift','Voice/TalkModeTests.swift','Voice/TalkModeRawDeltaTests.swift','Voice/TTSStreamTests.swift','Voice/TTSTextChunkerTests.swift','Configuration/SettingsSearchSelfFindProbe.swift']:
    shutil.copy(core/'Tests'/f,tests/Path(f).name)
(src/'ProofStubs.swift').write_text('''import Foundation
// Smart Turn MLX/provider boundary is inert in this isolated regression lane.
struct SmartTurnPrediction: Sendable { let probability: Float; let threshold: Float }
actor SmartTurnService {
    static let shared = SmartTurnService()
    func predict(samples: [Float], directory: URL) async throws -> SmartTurnPrediction { throw CancellationError() }
}
final class DirectDownloader: @unchecked Sendable {
    func invalidate() {}
    func download(from: URL, to: URL, expectedSize: Int64, onProgress: @escaping @Sendable (Int64, Int64) -> Void) async throws { throw CancellationError() }
}
func L(_ text: String) -> String { text }
enum ModelOptionValue: Codable, Sendable, Equatable {
    case bool(Bool), string(String)
    var boolValue: Bool? { if case .bool(let v) = self { v } else { nil } }
    var stringValue: String? { if case .string(let v) = self { v } else { nil } }
}
struct ChatCompletionRequest: Codable {
    var modelOptions: [String: ModelOptionValue]?
    var enable_thinking: Bool?
    var reasoning_effort: String?
}
enum ModelProfileRegistry {
    static func normalizedOptions(for id: String, persisted: [String: ModelOptionValue]) -> [String: ModelOptionValue] { persisted }
}
enum LocalReasoningCapability {
    struct Capability: Sendable { var supportsThinking = false; var isToggleableThinking = false }
    static func resolveForDispatch(modelId: String) async -> Capability { Capability() }
}
enum SystemPermission { case calendar, reminders, contacts, notes, automationMail, disk, automationMessages, location, automationMusic }
struct SidebarItemData { let id: String; let icon: String; let label: String; let badge: Int?; let badgeHighlight: Bool }
struct MLXModel { let id: String; let name: String; let description: String; let downloadURL: String }
@MainActor final class ChatTurn {
    enum Role { case assistant }
    var content: String
    init(role: Role, content: String) { self.content = content }
    func appendContent(_ text: String) { content += text }
    func appendThinking(_ text: String) {}
    func notifyContentChanged() {}
}
@MainActor final class ChatPerfTrace {
    static let shared = ChatPerfTrace()
    func count(_ name: String, _ n: Int = 1) {}
}
''')
# Additional production files are typechecked against explicitly inert app seams.
# This is NOT a full-app build or provider/hardware proof.
for f in ['Services/Voice/TalkMemoryBudget.swift','Services/Voice/TalkModeController.swift','Services/Voice/TalkModeHotKey.swift','Models/Voice/TalkModeConfigurationStore.swift','Views/Voice/TalkModeSettingsTab.swift']:
    shutil.copy(core/f,src/Path(f).name)
s=(core/'Managers/SpeechService.swift').read_text()
(src/'SpeechWorker.swift').write_text('import Foundation\nimport AVFoundation\nimport os\n'+s[s.index('private enum TranscriptionUpdate: Sendable'):])
with (src/'ProofStubs.swift').open('a') as f:
    f.write('''
import Combine
import SwiftUI
import AVFoundation
// T09 presentation boundary; full avatar source is compiled in the T09 lane.
@MainActor final class AvatarOverlayWindowService {
    static let shared = AvatarOverlayWindowService()
    var isVisible: Bool { false }
    func toggleTalk() {}
}
@MainActor final class ToastManager { static let shared = ToastManager(); func error(_ title: String, message: String) {}; func info(_ title: String, message: String) {} }
struct Agent: Identifiable { static let defaultId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!; let id: UUID; let name: String; var ttsVoice: String? = nil }
@MainActor final class AgentManager: ObservableObject {
    static let shared = AgentManager()
    let activeAgent = Agent(id: UUID(), name: "Proof")
    var agents: [Agent] { [activeAgent] }
    func agent(for id: UUID) -> Agent? { activeAgent }
}
enum AssistantDeltaEvent { case delta(turnId: UUID, text: String), finished, cancelled }
@MainActor final class ChatSession: ObservableObject {
    var selectedModel: String? = nil
    var selectedModelIsLocal = false
    var isAvailableForDispatchReattachment = true
    var lastStreamError: String?
    let streamTimingEvents = PassthroughSubject<TalkStreamTimingEvent, Never>()
    let subject = PassthroughSubject<AssistantDeltaEvent, Never>()
    var rawAssistantDeltas: AnyPublisher<AssistantDeltaEvent, Never> { subject.eraseToAnyPublisher() }
    func send(_ text: String, directUserSend: Bool = false, talkThinkBeforeSpeaking: Bool? = nil) {}
    func stop() {}
}
@MainActor final class ChatWindowState {
    let windowId = UUID()
    let session = ChatSession()
    var activeAgent: Agent { AgentManager.shared.activeAgent }
}
@MainActor final class ChatWindowManager: ObservableObject {
    static let shared = ChatWindowManager()
    var lastFocusedWindowId: UUID?
    func windowState(id: UUID) -> ChatWindowState? { nil }
    struct WindowInfo { let id: UUID }
    func findWindows(byAgentId id: UUID) -> [WindowInfo] { [] }
    func createWindow(agentId: UUID, showImmediately: Bool = true) -> UUID { UUID() }
    func showWindow(id: UUID) {}
}
@MainActor final class TranscriptionModeService {
    static let shared = TranscriptionModeService()
    enum State { case idle, starting }
    var state = State.idle
}
@MainActor final class VADService {
    static let shared = VADService()
    enum State { case idle, starting, listening }
    var state = State.idle
    func pause() async {}
    func resumeAfterChat() async {}
}
enum SpeechModelMemory {
    @MainActor static func talkComponents() async -> [TalkMemoryBudget.Component] { [] }
}
actor ModelRuntime {
    static let shared = ModelRuntime()
    func talkMemoryDecision(modelName: String?, local: Bool, auxiliary: [TalkMemoryBudget.Component]) -> TalkMemoryBudget.Decision {
        TalkMemoryBudget.assess(.init(physicalBytes: 32 << 30, comfortableBytes: 0,
            availableBytes: nil, reserveBytes: 0, components: auxiliary))
    }
}
@MainActor final class SpeechService {
    static let shared = SpeechService()
    let subject = PassthroughSubject<TalkCaptureEvent, Never>()
    var talkEvents: AnyPublisher<TalkCaptureEvent, Never> { subject.eraseToAnyPublisher() }
    func startTalkTranscription(duplex: TalkAudioEngine, gate: TalkSpeechGate, echoCancellation: Bool) async throws -> Bool { false }
    func stopTalkTranscription() async {}
    func stopStreamingTranscription(force: Bool = false) async -> String { "" }
}
@MainActor final class TTSService {
    static let shared = TTSService()
    let isModelReady = true
    func stop() {}
    func beginTalkStream(id: String, duplex: TalkAudioEngine, voiceOverride: String? = nil) -> TTSStreamHandle {
        TTSStreamHandle(id: id, player: duplex, synthesize: { _, _ in })
    }
}
enum OsaurusPaths {
    static func root() -> URL { URL(fileURLWithPath: "/tmp/osaurus-t03-proof-only") }
    static func voiceConfig() -> URL { URL(fileURLWithPath: "/tmp/osaurus-t03-proof-only") }
    static func ensureExistsSilent(_ url: URL) { try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
}
extension Notification.Name { static let voiceConfigurationChanged = Notification.Name("ProofVoiceConfigurationChanged") }
struct ProofTheme: Sendable { var secondaryText: Color { .secondary } }
private struct ProofThemeKey: EnvironmentKey { static let defaultValue = ProofTheme() }
private struct ProofLandingKey: EnvironmentKey { static let defaultValue: String? = nil }
extension EnvironmentValues { var settingsLandingPending: String? { self[ProofLandingKey.self] } }
extension EnvironmentValues { var theme: ProofTheme { get { self[ProofThemeKey.self] } set { self[ProofThemeKey.self] = newValue } } }
extension View { func settingsLandingAnchor(_ id: String) -> some View { self } }
struct TdtDecoderState: Sendable {}
struct ASRResult: Sendable { let text: String }
actor ProofASRManager {
    func transcribe(_ samples: [Float], decoderState: inout TdtDecoderState) async throws -> ASRResult { ASRResult(text: "") }
}
struct SendableAsrManager: Sendable { let manager: ProofASRManager }
enum SpeechDecoderStateFactory { static func make(for manager: ProofASRManager) async -> TdtDecoderState { TdtDecoderState() } }
struct VoiceSensitivity { static let medium = Self(); let vadThreshold: Float = 0.5; let silenceThresholdSeconds: Double = 0.7 }
actor VadManager {
    static let chunkSize = 4096
    struct State: Sendable {}
    struct Config: Sendable { static let `default` = Self() }
    struct Result: Sendable { let state: State; let probability: Float }
    func makeStreamState() -> State { State() }
    func processStreamingChunk(_ samples: [Float], state: State, config: Config) async throws -> Result { Result(state: state, probability: 0) }
}
''')

if __name__ == "__main__":
    import os
    import subprocess
    import sys
    if "--run" in sys.argv:
        env = os.environ.copy()
        env.update(GIT_TERMINAL_PROMPT="0", GIT_CONFIG_COUNT="1",
                   GIT_CONFIG_KEY_0="credential.helper", GIT_CONFIG_VALUE_0="",
                   CLANG_MODULE_CACHE_PATH=str(root/"build/ModuleCache"),
                   SWIFTPM_MODULECACHE_OVERRIDE=str(root/"build/ModuleCache"),
                   OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS="1",
                   OSAURUS_TEST_ROOT=str(root/"build/t03-test"),
                   OSU_MODELS_DIR=str(root/"build/t03-test-models"))
        command = ["swift", "test", "--disable-keychain", "--disable-sandbox",
                   "--build-system", "native", "--package-path", str(dest),
                   "--cache-path", str(root/"build/swiftpm-cache"),
                   "--config-path", str(root/"build/swiftpm-config"),
                   "--security-path", str(root/"build/swiftpm-security"), "--jobs", "4"]
        log = root/"build/t03-proof/isolated.log"
        log.parent.mkdir(parents=True, exist_ok=True)
        print("Running:", " ".join(command), flush=True)
        with log.open("w") as output:
            result = subprocess.run(command, cwd=root, env=env, stdout=output, stderr=subprocess.STDOUT)
        print("Exit:", result.returncode, "Log:", log)
        sys.exit(result.returncode)
    print("Prepared", dest)
