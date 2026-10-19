#!/usr/bin/env python3
"""Compile the real pinned FluidAudio with Osaurus resource/load adapters.

No inference/download/microphone/Keychain calls are executed. Resource and
sentinel tests use temporary fixtures. App singletons in the compilation seam
are inert. Full app/UI/audio proof is a separate host lane.
"""
import os
from pathlib import Path
import shutil
import subprocess

root = Path(__file__).resolve().parents[2]
core = root / "Packages/OsaurusCore"
dest = root / "build/T15/isolated"
src = dest / "Sources/OsaurusCore"
tests = dest / "Tests/OsaurusCoreTests"
for path in (src, tests):
    path.mkdir(parents=True, exist_ok=True)
(dest / "Package.swift").write_text('''// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "T15Proof", platforms: [.macOS(.v15)],
    dependencies: [.package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.4")],
    targets: [.target(name: "OsaurusCore", dependencies: [.product(name: "FluidAudio", package: "FluidAudio")]),
              .testTarget(name: "OsaurusCoreTests", dependencies: ["OsaurusCore"])])
''')
for file in ("Services/Voice/PocketTTSResources.swift", "Services/Voice/SpeechModelMemory.swift",
             "Managers/CoreMLLoadSentinel.swift"):
    shutil.copy(core / file, src)
for file in ("Tests/Voice/PocketTTSResourcesTests.swift", "Tests/Service/CoreMLLoadSentinelTests.swift"):
    shutil.copy(core / file, tests)

# Extract actual production model loading methods, preserving FluidAudio calls.
s = (core / "Managers/TTSService.swift").read_text()
methods = s[s.index("    public func ensureModelLoaded()"):s.index("    // MARK: - Playback", s.index("    public func ensureModelLoaded()"))]
state = s[s.index("public enum TTSModelState"):s.index("/// Owns the AVAudioEngine")]
seam = '''import Foundation
import Combine
@preconcurrency import FluidAudio
func L(_ text: String) -> String { text }
enum TTSConfigurationStore {
    struct Configuration { let voice = "alba" }
    static func load() -> Configuration { Configuration() }
}
@MainActor final class TTSService {
    static let shared = TTSService()
    var modelState: TTSModelState = .notReady
    var initTask: Task<Void, Never>?
    var manager: PocketTtsManager?
'''
(src / "TTSLoadSeam.swift").write_text(seam + methods + "\n}\n" + state)
(src / "AppStubs.swift").write_text('''import Foundation
// Only app dependencies are stubbed. FluidAudio APIs and model names are real.
enum AuxiliaryModelEstimate { static func bytes(at roots: [URL]) -> UInt64? { nil } }
final class AuxiliaryModelResidency: Sendable {
    static let shared = AuxiliaryModelResidency()
    enum Kind: String { case stt, tts, vad }
    struct Entry { let kind: Kind; let estimatedBytes: UInt64? }
    func track(_ owner: AnyObject, kind: Kind, estimatedBytes: UInt64?) {}
    func snapshot() -> [Entry] { [] }
}
enum TalkMemoryBudget {
    struct Component { let role: String; let estimatedBytes: UInt64?; let resident: Bool }
}
@MainActor final class SpeechModelManager {
    static let shared = SpeechModelManager()
    struct Model { let id: String }
    var selectedModel: Model? = nil
}
@MainActor final class SpeechService {
    static let shared = SpeechService()
    var isModelLoaded = false
    var isLoadingModel = false
    var lastError: String?
    // Unexpected admission must fail the test, never download/load a model.
    func loadModel(_ id: String) async throws { throw CocoaError(.featureUnsupported) }
}
''')
s = (core / "Managers/SpeechService.swift").read_text()
automatic = s[s.index("    @discardableResult\n    public func loadModelAutomatically"):s.index("    /// Ensure a model is loaded, using the default if needed")]
(src / "SpeechAutomaticLoadSeam.swift").write_text("import Foundation\nextension SpeechService {\n" + automatic + "\n}\n")
# These compile-only probes validate the remaining unchanged public signatures.
# They are never called: no model loading or synthesis is part of this lane.
(src / "FluidAudioAPIProbe.swift").write_text('''import Foundation
@preconcurrency import FluidAudio
func speechAPIProbe(audio: [Float], url: URL) async throws {
    let version: AsrModelVersion = .v3
    _ = AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: version), version: version)
    let models = try await AsrModels.downloadAndLoad(version: version)
    let manager = AsrManager(config: .default)
    try await manager.loadModels(models)
    var decoder = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
    _ = try await manager.transcribe(audio, decoderState: &decoder)
    _ = try await manager.transcribe(url, decoderState: &decoder)
    let vad = try await VadManager(config: VadConfig(defaultThreshold: 0.5))
    _ = try await vad.process(audio)
}
func ttsAPIProbe(manager: PocketTtsManager, text: String, voice: String, temperature: Float) async throws {
    // Same manager overload used by API speech, incremental Talk and ordinary playback.
    let frames = try await manager.synthesizeStreaming(text: text, voice: voice, temperature: temperature)
    for try await frame in frames { let _: [Float] = frame.samples }
}
''')
env = os.environ.copy()
env.update(GIT_TERMINAL_PROMPT="0", GIT_CONFIG_COUNT="1", GIT_CONFIG_KEY_0="credential.helper", GIT_CONFIG_VALUE_0="",
           CLANG_MODULE_CACHE_PATH=str(root / "build/ModuleCache"), SWIFTPM_MODULECACHE_OVERRIDE=str(root / "build/ModuleCache"),
           OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS="1", OSAURUS_TEST_ROOT=str(root / "build/T15/test-root"),
           OSU_MODELS_DIR=str(root / "build/T15/test-models"))
command = ["swift", "test", "--disable-keychain", "--disable-sandbox", "--package-path", str(dest),
           "--cache-path", str(root / "build/swiftpm-cache"), "--config-path", str(root / "build/swiftpm-config"),
           "--security-path", str(root / "build/swiftpm-security"), "--jobs", "4"]
log = root / "build/T15/isolated.log"
print("Running:", " ".join(command), flush=True)
with log.open("w") as output:
    result = subprocess.run(command, cwd=root, env=env, stdout=output, stderr=subprocess.STDOUT)
print("Exit:", result.returncode, "Log:", log)
raise SystemExit(result.returncode)
