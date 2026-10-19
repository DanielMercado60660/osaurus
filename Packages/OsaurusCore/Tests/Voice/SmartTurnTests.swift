import Foundation
import Testing
@testable import OsaurusCore

@Suite("Smart Turn preprocessing and endpoint policy")
struct SmartTurnTests {
    @Test func referenceConstantsPaddingAndNormalization() {
        #expect(SmartTurnFeatures.sampleRate == 16000)
        #expect(SmartTurnFeatures.fftSize == 400 && SmartTurnFeatures.hop == 160)
        #expect(SmartTurnFeatures.frames == 800 && SmartTurnFeatures.mels == 80)
        let short = SmartTurnFeatures.padded([1, -1])
        #expect(short.count == 128000 && short[127997] == 0 && short.suffix(2) == [1, -1])
        let long = [Float](repeating: 1, count: 128000) + [Float](repeating: -1, count: 16000)
        #expect(SmartTurnFeatures.padded(long) == Array(long.suffix(128000)))
        for hz in [0.0, 200, 999, 1000, 4000, 8000] {
            #expect(abs(SmartTurnFeatures.melToHz(SmartTurnFeatures.hzToMel(hz)) - hz) < 1e-6)
        }
        #expect(SmartTurnFeatures.hzToMel(600) == 9)
        let silence = SmartTurnFeatures.extract([])
        #expect(silence.count == 64000 && silence.allSatisfy { $0 == -1.5 })
    }
    @Test func toneAndLongTailHaveWhisperRange() {
        let tone = (0..<16000).map { Float(sin(Double($0) * 440 * 2 * .pi / 16000) * 0.25) }
        let features = SmartTurnFeatures.extract(tone)
        #expect(features.allSatisfy { $0.isFinite })
        #expect(features.max()! - features.min()! <= 2.00001)
        let long = [Float](repeating: 0.9, count: 128000) + tone
        #expect(SmartTurnFeatures.extract(long) == SmartTurnFeatures.extract(Array(long.suffix(128000))))
    }
    @Test func checksAreBoundedAndStaleResultsRejected() throws {
        var policy = TalkSmartTurnPolicy()
        #expect(policy.request(silence: 0.25, speechDuration: 0.299, checkSilence: 0.25) == nil)
        #expect(policy.request(silence: 0.249, speechDuration: 1, checkSilence: 0.25) == nil)
        let first = policy.request(silence: 0.25, speechDuration: 1, checkSilence: 0.25)
        let id = try #require(first)
        #expect(policy.request(silence: 0.5, speechDuration: 1, checkSilence: 0.25) == nil)
        #expect(policy.receive(id: id, probability: 0.4, threshold: 0.5) == true)
        #expect(!policy.complete)
        #expect(policy.request(silence: 0.449, speechDuration: 1, checkSilence: 0.25) == nil)
        let next = policy.request(silence: 0.45, speechDuration: 1, checkSilence: 0.25)
        let nextID = try #require(next)
        policy.resumeSpeech()
        #expect(policy.receive(id: nextID, probability: 1, threshold: 0.5) == false)
        let resumed = policy.request(silence: 0.25, speechDuration: 1.2, checkSilence: 0.25)
        let resumedID = try #require(resumed)
        #expect(policy.receive(id: resumedID, probability: 0.5, threshold: 0.5) == true)
        #expect(policy.complete && policy.checks == 3)
        #expect(policy.request(silence: 0.7, speechDuration: 1.2, checkSilence: 0.25) == nil)
    }
    @Test func earlyEndpointReusesASRAndDoesNotWaitForReducerSilence() {
        var endpoint = TalkFinalizationPolicy()
        #expect(endpoint.update(active: false, silence: 0.25, endSilence: 0.9, sampleCount: 16000,
                                speculationSilence: 0.25) == .speculate)
        #expect(endpoint.update(active: false, silence: 0.35, endSilence: 0.9, sampleCount: 16000,
                                semanticComplete: true) == .finalize(reuse: true))
        var snapshot = TalkModeSnapshot()
        let config = TalkModeConfiguration()
        for event in [TalkModeEvent.start(aec: true), .speechStarted(segment: 1, at: 1),
                      .speechEnded(segment: 1, at: 2), .endpoint(segment: 1), .final(segment: 1, text: "Hello") ] {
            snapshot = TalkModeReducer.reduce(snapshot, event, config: config).0
        }
        let result = TalkModeReducer.reduce(snapshot, .tick(2.35), config: config)
        #expect(result.0.state == .thinking && result.1.count == 1)
        snapshot = TalkModeReducer.reduce(snapshot, .speechStarted(segment: 1, at: 2.3), config: config).0
        #expect(!snapshot.endpointDecided)
    }
    @Test func silenceFallbackAndActiveSpeechWin() {
        var endpoint = TalkFinalizationPolicy()
        #expect(endpoint.update(active: false, silence: 0.25, endSilence: 0.9, sampleCount: 16000,
                                speculationSilence: 0.25) == .speculate)
        #expect(endpoint.update(active: true, silence: 0, endSilence: 0.9, sampleCount: 16000,
                                semanticComplete: true) == .cancelSpeculation)
        #expect(endpoint.update(active: false, silence: 0.899, endSilence: 0.9, sampleCount: 16000) == .speculate)
        #expect(endpoint.update(active: false, silence: 0.9, endSilence: 0.9, sampleCount: 16000) == .finalize(reuse: true))
        var legacy = TalkFinalizationPolicy()
        #expect(legacy.update(active: false, silence: 0.7, endSilence: 0.7, sampleCount: 16000) == .finalize(reuse: false))
    }
    @Test func settingsMigrationPreservesExplicitSilence() throws {
        let decoder = JSONDecoder()
        var automatic = try decoder.decode(TalkModeConfiguration.self, from: Data("{}".utf8))
        #expect(automatic.smartTurnEnabled && automatic.smartTurnCheckSilenceMs == 250)
        #expect(automatic.effectiveEndSilenceMs(smartTurnActive: true) == 900)
        #expect(automatic.effectiveEndSilenceMs(smartTurnActive: false) == 700)
        var explicit = automatic
        explicit.endOfTurnSilenceMs = 700
        #expect(explicit.requiresCaptureRestart(comparedTo: automatic))
        #expect(explicit.effectiveEndSilenceMs(smartTurnActive: true) == 700)
        automatic.smartTurnEnabled = false
        #expect(try decoder.decode(TalkModeConfiguration.self, from: JSONEncoder().encode(automatic)) == automatic)
        let saved = try decoder.decode(TalkModeConfiguration.self, from: Data(#"{"endOfTurnSilenceMs":700,"smartTurnEnabled":false}"#.utf8))
        #expect(saved.effectiveEndSilenceMs(smartTurnActive: true) == 700 && !saved.smartTurnEnabled)
    }
    @Test func telemetryAndLegacyDecoding() throws {
        var timing = TalkCaptureTiming()
        timing.observations = [1: .init(checks: 2, probability: 0.4), 2: .init(checks: 1, probability: 0.8, reason: .smartTurn)]
        var turn = TalkTurnLatency(epoch: 1, speechEnd: 10)
        timing.apply(segments: [1, 2], to: &turn)
        #expect(turn.smartTurnChecks == 3 && turn.smartTurnProbability == 0.8 && turn.endOfTurnReason == "smartTurn")
        #expect(try JSONDecoder().decode(TalkTurnLatency.self, from: JSONEncoder().encode(turn)) == turn)
        let legacy = try JSONDecoder().decode(TalkTurnLatency.self, from: Data(#"{"epoch":1,"speechEnd":10}"#.utf8))
        #expect(legacy.smartTurnChecks == nil && legacy.endOfTurnReason == nil)
        timing.retain([])
        #expect(timing.observations.isEmpty)
    }
    @Test func cacheDiscoveryDoesNotModifyExternalSnapshots() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let owned = root.appendingPathComponent("owned")
        let snapshot = home.appendingPathComponent(".cache/huggingface/hub/models--mlx-community--smart-turn-v3/snapshots/revision")
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        #expect(SmartTurnResources.locate(owned: owned, home: home, environment: [:]) == nil)
        try Data("{}".utf8).write(to: snapshot.appendingPathComponent("config.json"))
        #expect(SmartTurnResources.locate(owned: owned, home: home, environment: [:]) == nil)
        try Data([1]).write(to: snapshot.appendingPathComponent("model.safetensors"))
        #expect(SmartTurnResources.locate(owned: owned, home: home, environment: [:])?.resolvingSymlinksInPath().path == snapshot.resolvingSymlinksInPath().path)
        #expect(!FileManager.default.fileExists(atPath: owned.path))
    }
}
