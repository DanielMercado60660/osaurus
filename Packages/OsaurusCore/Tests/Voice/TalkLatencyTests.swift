import Combine
import Foundation
import Testing
@testable import OsaurusCore

@Suite("Talk latency stages and thinking preference")
struct TalkLatencyTests {
    @Test func thinkingMatrixAndCaptions() {
        for on in [false, true] {
            for supports in [false, true] {
                for toggle in [false, true] {
                    let result = TalkThinkingPolicy.enableThinking(thinkBeforeSpeaking: on, toggleable: supports && toggle)
                    #expect(result == (!on && supports && toggle ? false : nil))
                }
            }
        }
        #expect(TalkThinkingPolicy.caption(supportsThinking: true, toggleable: false) == "This model always reasons")
        #expect(TalkThinkingPolicy.caption(supportsThinking: false, toggleable: false) == "This model doesn't reason")
        #expect(TalkThinkingPolicy.enableThinking(thinkBeforeSpeaking: false, toggleable: false) == nil)
    }

    @Test func preferenceMigrationAndRoundTrip() throws {
        let old = try JSONDecoder().decode(TalkModeConfiguration.self, from: Data("{}".utf8))
        #expect(!old.thinkBeforeSpeaking)
        var changed = old
        changed.thinkBeforeSpeaking = true
        #expect(try JSONDecoder().decode(TalkModeConfiguration.self, from: JSONEncoder().encode(changed)) == changed)
    }

    @Test func talkControlsDoNotMutateComposerOrCarryItsReasoningChoice() throws {
        let composer: [String: ModelOptionValue] = ["disableThinking": .bool(false), "reasoningEffort": .string("high")]
        for on in [false, true] {
            for toggle in [false, true] {
                let controls = ChatTurnGenerationControls.captureForTalk(
                    activeModelOptions: composer, thinkBeforeSpeaking: on, toggleable: toggle)
                #expect(controls.enableThinking == (!on && toggle ? false : nil))
                #expect(controls.modelOptions?["disableThinking"]?.boolValue == (!on && toggle ? true : nil))
                #expect(controls.reasoningEffort == nil)
                #expect(controls.modelOptions != nil) // prevent persisted UI-agent fallback
                for _ in 0..<3 {
                    var request = try JSONDecoder().decode(ChatCompletionRequest.self,
                        from: Data(#"{"model":"test-model","messages":[]}"#.utf8))
                    controls.apply(to: &request)
                    #expect(request.enable_thinking == controls.enableThinking)
                    #expect(request.modelOptions == controls.modelOptions)
                    #expect(request.reasoning_effort == nil)
                }
            }
        }
        #expect(ChatTurnGenerationControls.capture(activeModelOptions: composer).enableThinking == true)
        #expect(composer["reasoningEffort"]?.stringValue == "high")
    }

    @Test func earlySpeculationRetainsCompletionTimeAtEndpoint() throws {
        var endpoint = TalkFinalizationPolicy()
        var ledger = TalkRecognitionLedger()
        #expect(endpoint.update(active: false, silence: 0.25, endSilence: 0.7, sampleCount: 16000) == .none)
        #expect(endpoint.update(active: false, silence: 0.3, endSilence: 0.7, sampleCount: 16000) == .speculate)
        let id = ledger.begin(segment: 1, kind: .speculative)
        #expect(ledger.complete(id, result: .text("Hello"), at: 10.4) == nil)
        #expect(endpoint.update(active: false, silence: 0.7, endSilence: 0.7, sampleCount: 16000) == .finalize(reuse: true))
        let committed = ledger.commitSpeculation()
        let delivery = try #require(committed)
        #expect(delivery.completedAt == 10.4)
        var timing = TalkCaptureTiming()
        timing.endpoints[1] = 10.7
        timing.finals[1] = delivery.completedAt
        var turn = TalkTurnLatency(epoch: 1, speechEnd: 10)
        timing.apply(segments: [1], to: &turn)
        #expect(try #require(turn.asrFinalMs) < #require(turn.endOfTurnDecidedMs))
    }

    @Test func lateAndCancelledSpeculationNeverFabricateEarlyASR() throws {
        var ledger = TalkRecognitionLedger()
        let late = ledger.begin(segment: 1, kind: .speculative)
        #expect(ledger.commitSpeculation() == nil)
        #expect(ledger.complete(late, result: .text("Late"), at: 12)?.completedAt == 12)
        let resumed = ledger.begin(segment: 2, kind: .speculative)
        #expect(ledger.cancelSpeculation() == resumed)
        #expect(ledger.complete(resumed, result: .text("Stale"), at: 13) == nil)
        #expect(ledger.commitSpeculation() == nil)
        var timing = TalkCaptureTiming()
        timing.endpoints = [1: 11, 2: 14]
        timing.finals = [1: 12, 2: 15]
        var turn = TalkTurnLatency(epoch: 3, speechEnd: 13)
        timing.apply(segments: [1, 2], to: &turn)
        #expect(turn.asrFinalMs == 2000)
        #expect(turn.endOfTurnDecidedMs == 1000)
        timing.retain([3])
        #expect(timing.finals.isEmpty && timing.endpoints.isEmpty)
    }

    @Test func streamingStagesReasoningPhasesAndJSON() throws {
        var turn = TalkTurnLatency(epoch: 1, speechEnd: 10)
        turn.observe(.delta(at: 11))
        turn.observe(.reasoning(at: 11.25))
        turn.observe(.reasoning(at: 11.5))
        turn.visible(at: 12)
        turn.visible(at: 12.25)
        turn.observe(.reasoning(at: 13)) // tool continuation
        turn.finishReasoning(at: 13.5)
        #expect(turn.firstStreamDeltaMs == 1000)
        #expect(turn.firstReasoningMs == 1250)
        #expect(turn.firstVisibleTokenMs == 2000 && turn.firstTokenMs == 2000)
        #expect(turn.reasoningDeltaCount == 3)
        #expect(turn.reasoningDurationMs == 1250)
        let encoded = try JSONEncoder().encode(turn)
        #expect(try JSONDecoder().decode(TalkTurnLatency.self, from: encoded) == turn)
        let legacy = try JSONDecoder().decode(TalkTurnLatency.self, from: Data(#"{"epoch":1,"speechEnd":10,"firstTokenMs":20}"#.utf8))
        #expect(legacy.firstVisibleTokenMs == nil && legacy.reasoningDeltaCount == nil)
        var direct = TalkTurnLatency(epoch: 2, speechEnd: 10)
        direct.visible(at: 11)
        #expect(direct.reasoningDurationMs == 0 && direct.firstReasoningMs == nil)
    }

    @Test func percentilesExcludeInvalidMeasurements() throws {
        var history = TalkLatencyHistory()
        for i in 1...60 {
            history.begin(epoch: UInt64(i), speechEnd: 0)
            history.update(epoch: UInt64(i)) { $0.sendIssuedMs = Double(i) }
        }
        #expect(history.turns.count == 50)
        #expect(try #require(history.percentiles(\.sendIssuedMs)).p50 == 35)
        #expect(try #require(history.percentiles(\.sendIssuedMs)).p90 == 55)
        history.update(epoch: 60) { $0.firstReasoningMs = .nan }
        history.update(epoch: 59) { $0.firstReasoningMs = -1 }
        history.update(epoch: 58) { $0.firstReasoningMs = .infinity }
        #expect(history.percentiles(\.firstReasoningMs) == nil)
    }

    @Test @MainActor func releaseObservationPrecedesSynthesisAndIncludesFinalFlush() {
        let handle = TTSStreamHandle(id: "stages", player: LatencyPlayer(), synthesize: { _, _ in }, releasePolicy: .conversational)
        var released: [String] = []
        let subscription = handle.releasedChunks.sink { released.append($0) }
        handle.enqueue(text: "Hello there.")
        #expect(released == ["Hello there."])
        handle.enqueue(text: "A final fragment")
        handle.finish()
        #expect(released.count == 2)
        handle.cancel()
        withExtendedLifetime(subscription) {}
    }
}

private struct LatencyPlayer: TTSStreamPlayer {
    func prepareAndPlay() async throws {}
    func schedulePlayed(samples: [Float], completion: @escaping @Sendable (Bool) -> Void) { completion(true) }
    func cancelPlayback() {}
}
