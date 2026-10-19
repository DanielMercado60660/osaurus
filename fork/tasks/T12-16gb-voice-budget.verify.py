"""Add a type-check/lifecycle seam to the dependency-free T12 package.

Copies SpeechModelMemory unchanged except its FluidAudio import; extracts the
actual SpeechService load/unload methods at stable declaration boundaries.
FluidAudio/audio/app seams are inert. No download, model allocation, microphone,
Keychain, or physical RAM proof. Invoked by test-talk-memory-isolated.sh.
"""
from pathlib import Path
root = Path(__file__).resolve().parents[2]
core = root / 'Packages/OsaurusCore'
src = root / 'build/T12/isolated/Sources/OsaurusCore'
tests = root / 'build/T12/isolated/Tests/Tests'
s = (core / 'Services/Voice/SpeechModelMemory.swift').read_text()
(src / 'SpeechModelMemory.swift').write_text(s.replace('import FluidAudio\n', ''))
s = (core / 'Managers/SpeechService.swift').read_text()
methods = s[s.index('    /// Load the ASR model for a given version'):s.index('    /// Auto-load the model if a default model is selected')]
stubs = '''import Foundation

// Isolated app/FluidAudio seams, not alternate production memory policy.
enum AsrModelVersion: Sendable { case v2, v3 }
struct AsrModels: Sendable {
    static func defaultCacheDirectory(for version: AsrModelVersion) -> URL {
        URL(fileURLWithPath: "/tmp/osaurus-t12-unused-models/\\(version)")
    }
    static func downloadAndLoad(version: AsrModelVersion) async throws -> AsrModels {
        await SpeechLoadProbe.shared.loading()
        return AsrModels()
    }
}
enum ModelNames {
    enum ASR { static let requiredModels = ["v2.mlmodelc"]; static let requiredModelsV3 = ["v3.mlmodelc"] }
    enum VAD { static let requiredModels = ["vad.mlmodelc"] }
    enum PocketTTS { static let requiredModels = ["tts.mlmodelc", "constants_bin"] }
}
enum MLModelConfigurationUtils {
    enum Repo { case vad }
    static func defaultModelsDirectory(for repo: Repo) -> URL { URL(fileURLWithPath: "/tmp/osaurus-t12-unused-models/vad") }
}
actor SpeechLoadProbe {
    static let shared = SpeechLoadProbe()
    private var suspend = false
    var rejectVad = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    func configure(suspend: Bool = false, rejectVad: Bool = false) { self.suspend = suspend; self.rejectVad = rejectVad }
    func loading() async {
        guard suspend else { return }
        await withCheckedContinuation { waiter = $0; startWaiters.forEach { $0.resume() }; startWaiters = [] }
    }
    func waitForStart() async {
        if waiter != nil { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }
    func resume() { waiter?.resume(); waiter = nil }
}
actor AsrManager {
    struct Config { static let `default` = Config() }
    init(config: Config) {}
    func loadModels(_ models: AsrModels) async throws {}
}
final class SendableAsrManager: @unchecked Sendable {
    let manager: AsrManager
    init(_ manager: AsrManager) { self.manager = manager }
}
struct VadConfig { let defaultThreshold: Double }
actor VadManager {
    init(config: VadConfig) async throws {
        if await SpeechLoadProbe.shared.rejectVad { throw SpeechError.transcriptionFailed("scripted VAD failure") }
    }
}
enum SpeechError: Error { case transcriptionFailed(String) }
enum SpeechConfigurationStore {
    struct Sensitivity { let vadThreshold = 0.5 }
    struct Config { let sensitivity = Sensitivity() }
    static func load() -> Config { Config() }
}
enum CoreMLLoadSentinel {
    enum Kind { case speech }
    static func begin(_ kind: Kind, modelId: String) {}
    static func end(_ kind: Kind) {}
}
@MainActor final class SpeechModelManager {
    struct Model { let id: String }
    static let shared = SpeechModelManager()
    let selectedModel: Model? = Model(id: "v3")
}
@MainActor public final class SpeechService {
    static let shared = SpeechService()
    var isLoadingModel = false
    var isModelLoaded = false
    var loadedModelId: String?
    var lastError: String?
    private var modelLoadGeneration = UUID()
    var sendableAsrManager: SendableAsrManager?
    private var vadManager: VadManager?
'''
(src / 'SpeechLoadSeam.swift').write_text(stubs + methods + '\n}\n')
(tests / 'SpeechResidencyLifecycleTests.swift').write_text('''import Foundation
import Testing
@testable import OsaurusCore

@Suite(.serialized) @MainActor
struct SpeechResidencyLifecycleTests {
    @Test func loadReuseUnloadAndDrainingWorker() async throws {
        let service = SpeechService.shared
        await SpeechLoadProbe.shared.configure()
        try await service.loadModel("v3")
        #expect(service.isModelLoaded)
        #expect(AuxiliaryModelResidency.shared.snapshot().count == 2)
        #expect((await SpeechModelMemory.talkComponents()).allSatisfy(\\.resident))
        var worker = service.sendableAsrManager
        service.unloadModel()
        #expect(!service.isModelLoaded)
        #expect(AuxiliaryModelResidency.shared.snapshot().count == 1)
        // Old worker remains counted; next capture still needs a new pair.
        let components = await SpeechModelMemory.talkComponents()
        #expect(components.filter { !$0.resident }.count == 2)
        withExtendedLifetime(worker) {}
        worker = nil
        #expect(AuxiliaryModelResidency.shared.snapshot().isEmpty)
    }
    @Test func vadFailureDoesNotLeavePartialASRResident() async {
        let service = SpeechService.shared
        await SpeechLoadProbe.shared.configure(rejectVad: true)
        do { try await service.loadModel("v3"); Issue.record("expected VAD failure") } catch {}
        #expect(!service.isModelLoaded)
        #expect(!service.isLoadingModel)
        #expect(AuxiliaryModelResidency.shared.snapshot().isEmpty)
    }
    @Test(arguments: [false, true]) func unloadOrCancelWhileLoadingCannotPublish(cancel: Bool) async {
        let service = SpeechService.shared
        await SpeechLoadProbe.shared.configure(suspend: true)
        let task = Task { try await service.loadModel("v3") }
        await SpeechLoadProbe.shared.waitForStart()
        if cancel { task.cancel() } else { service.unloadModel() }
        await SpeechLoadProbe.shared.resume()
        switch await task.result {
        case .success: Issue.record("cancelled/unloaded load published successfully")
        case .failure: break
        }
        #expect(!service.isModelLoaded)
        #expect(!service.isLoadingModel)
        #expect(AuxiliaryModelResidency.shared.snapshot().isEmpty)
    }
}
''')

# Actual shared projection and its regression, with only settings storage stubbed.
runtime = (core / 'Services/ModelRuntime.swift').read_text()
def declaration(text, marker):
    start = text.index(marker)
    opening = text.index('{', start)
    depth = 1
    end = opening + 1
    while depth:
        if text[end] == '{': depth += 1
        elif text[end] == '}': depth -= 1
        end += 1
    return text[start:end]
parts = [declaration(runtime, marker) for marker in (
    '    public struct RAMFeasibility:', '    static func buildRAMFeasibility(', '    static func gpuBudgetBytes(')]
(src / 'RAMProjection.swift').write_text('''import Foundation
enum ServerRuntimeSettingsStore {
    static func automaticMemoryLimitsDisabled() -> Bool { false }
    static func modelLoadRAMThresholds() -> (soft: Double, hard: Double) { (0.7, 0.9) }
}
actor ModelRuntime {
''' + '\n'.join(parts) + '\n}\n')
regression = (core / 'Tests/Service/ModelRuntimeRAMFeasibilityTests.swift').read_text()
body = declaration(regression, '    func speechResidentsSupplementProjection()')
(tests / 'RAMProjectionTests.swift').write_text('''import Foundation
import Testing
@testable import OsaurusCore
struct RAMProjectionTests {
    private let gb: Int64 = 1 << 30
    @Test
''' + body + '\n}\n')
