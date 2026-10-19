import AVFoundation
import Combine
import Foundation
import Testing
@testable import OsaurusCore

@Suite("TalkMode reducer and latency")
struct TalkModeTests {
    private let config = TalkModeConfiguration.default
    private func step(_ s: inout TalkModeSnapshot, _ event: TalkModeEvent) -> [TalkModeEffect] {
        let result = TalkModeReducer.reduce(s, event, config: config)
        s = result.0
        return result.1
    }
    private func thinking() -> TalkModeSnapshot {
        var s = TalkModeSnapshot()
        _ = step(&s, .start(aec: false))
        _ = step(&s, .speechStarted(segment: 1, at: 1))
        _ = step(&s, .speechEnded(segment: 1, at: 1.5))
        _ = step(&s, .final(segment: 1, text: "Hello"))
        _ = step(&s, .tick(2.21))
        return s
    }

    @Test func happyPathWaitsForSilenceAndFinal() {
        var s = TalkModeSnapshot()
        _ = step(&s, .start(aec: true))
        #expect(s.state == .listening)
        _ = step(&s, .speechStarted(segment: 1, at: 1))
        _ = step(&s, .partial(segment: 1, text: "Hello"))
        #expect(s.caption == "Hello")
        _ = step(&s, .speechEnded(segment: 1, at: 1.5))
        #expect(step(&s, .tick(3)).isEmpty) // ASR has not finalized.
        _ = step(&s, .final(segment: 1, text: " Hello! "))
        #expect(step(&s, .tick(3)) == [.send(text: "Hello!", epoch: s.epoch, speechEnd: 1.5)])
        #expect(s.state == .thinking)
        _ = step(&s, .firstAudio(epoch: s.epoch))
        #expect(s.state == .speaking)
        _ = step(&s, .replyFinished(epoch: s.epoch, at: 4))
        #expect(s.state == .listening)
        #expect(s.ignoreUntil == 0)
    }

    @Test(arguments: ["", "   \n", "uh", "Um, uh!", "."])
    func emptyOrFillerNeverSends(text: String) {
        var s = TalkModeSnapshot()
        _ = step(&s, .start(aec: false))
        _ = step(&s, .speechStarted(segment: 1, at: 1))
        _ = step(&s, .speechEnded(segment: 1, at: 2))
        _ = step(&s, .final(segment: 1, text: text))
        #expect(step(&s, .tick(3)).isEmpty)
        #expect(s.state == .listening)
    }

    @Test func shortSpeechAndEarlySilenceDoNotSend() {
        var s = TalkModeSnapshot()
        _ = step(&s, .start(aec: false))
        _ = step(&s, .speechStarted(segment: 1, at: 1))
        _ = step(&s, .speechEnded(segment: 1, at: 1.1))
        _ = step(&s, .final(segment: 1, text: "noise"))
        #expect(step(&s, .tick(1.7)).isEmpty)
        #expect(s.state == .endOfTurn)
        #expect(step(&s, .tick(1.9)).isEmpty)
        #expect(s.state == .listening)
    }

    @Test(arguments: [false, true])
    func bargeInAndStaleEpoch(speaking: Bool) {
        var s = thinking()
        let old = s.epoch
        if speaking { _ = step(&s, .firstAudio(epoch: old)) }
        _ = step(&s, .speechStarted(segment: 2, at: 3))
        #expect(step(&s, .tick(3.15)).isEmpty)
        #expect(step(&s, .tick(3.17)) == [.cancelReply])
        #expect(s.state == .userSpeaking)
        #expect(s.speechStart == 3) // onset is retained
        #expect(s.epoch > old)
        let accepted = s
        _ = step(&s, .firstAudio(epoch: old))
        _ = step(&s, .replyFinished(epoch: old, at: 3.2))
        _ = step(&s, .final(segment: 1, text: "late previous ASR"))
        #expect(s == accepted)
        _ = step(&s, .speechEnded(segment: 2, at: 3.6))
        _ = step(&s, .final(segment: 2, text: "Actually, stop."))
        #expect(step(&s, .tick(4.31)) == [.send(text: "Actually, stop.", epoch: s.epoch, speechEnd: 3.6)])
    }

    @Test func briefNoiseDoesNotInterrupt() {
        var s = thinking()
        _ = step(&s, .speechStarted(segment: 2, at: 3))
        _ = step(&s, .speechEnded(segment: 2, at: 3.1))
        #expect(step(&s, .tick(4)).isEmpty)
        #expect(s.state == .thinking)
    }

    @Test func bargeInDisabled() {
        var config = config
        config.bargeInEnabled = false
        let s = thinking()
        let result = TalkModeReducer.reduce(s, .speechStarted(segment: 2, at: 3), config: config)
        #expect(result.0 == s)
        #expect(result.1.isEmpty)
    }

    @Test func fallbackThresholdAndCooldown() {
        #expect(TalkModeReducer.vadThreshold(aecActive: false, playback: true) == 0.75)
        #expect(TalkModeReducer.vadThreshold(aecActive: true, playback: true) == 0.5)
        #expect(TalkModeReducer.vadThreshold(aecActive: false, playback: false) == 0.5)
        var s = thinking()
        _ = step(&s, .firstAudio(epoch: s.epoch))
        _ = step(&s, .replyFinished(epoch: s.epoch, at: 3))
        _ = step(&s, .speechStarted(segment: 2, at: 3.2))
        #expect(s.state == .listening)
        _ = step(&s, .speechStarted(segment: 3, at: 3.31))
        #expect(s.state == .userSpeaking)
        let gate = TalkSpeechGate(silenceMs: 700)
        gate.update(aec: false, playback: true, ignoreUntil: 2)
        #expect(!gate.detects(0.8, at: 1))
        #expect(!gate.detects(0.7, at: 3))
        #expect(gate.detects(0.8, at: 3))
    }

    @Test func togglingOffInvalidatesEverything() {
        var s = thinking()
        let epoch = s.epoch
        #expect(step(&s, .stop) == [.cancelReply])
        #expect(s.state == .off)
        #expect(s.epoch > epoch)
        let stopped = s
        _ = step(&s, .firstAudio(epoch: epoch))
        _ = step(&s, .speechStarted(segment: 2, at: 3))
        _ = step(&s, .final(segment: 1, text: "late"))
        #expect(s == stopped)
    }

    @Test func pausesWithinUtteranceAccumulateActualSpeech() {
        var s = TalkModeSnapshot()
        _ = step(&s, .start(aec: true))
        _ = step(&s, .speechStarted(segment: 1, at: 1))
        _ = step(&s, .speechEnded(segment: 1, at: 1.2))
        _ = step(&s, .speechStarted(segment: 1, at: 1.4))
        _ = step(&s, .speechEnded(segment: 1, at: 1.6))
        _ = step(&s, .final(segment: 1, text: "hello"))
        #expect(step(&s, .tick(2.31)).count == 1)
    }

    @Test func configurationRoundTripAndDefaults() throws {
        var config = TalkModeConfiguration()
        config.enabledAgentIds = [UUID()]
        config.showCaptions = false
        #expect(try JSONDecoder().decode(TalkModeConfiguration.self, from: JSONEncoder().encode(config)) == config)
        #expect(try JSONDecoder().decode(TalkModeConfiguration.self, from: Data("{}".utf8)) == .default)
    }

    @Test func latencyRetains50AndDoesNotInventMissingMeasurements() throws {
        var history = TalkLatencyHistory()
        for epoch in 1...60 {
            history.begin(epoch: UInt64(epoch), speechEnd: 0)
            history.update(epoch: UInt64(epoch)) { $0.firstTokenMs = Double(epoch) }
        }
        #expect(history.turns.count == 50)
        #expect(history.turns.first?.epoch == 11)
        let percentiles = try #require(history.percentiles(\.firstTokenMs))
        #expect(percentiles.p50 == 35)
        #expect(percentiles.p90 == 55)
        #expect(history.percentiles(\.firstAudioMs) == nil)
        #expect(try JSONDecoder().decode([TalkTurnLatency].self, from: JSONEncoder().encode(history.turns)) == history.turns)
    }
}

@Suite("TalkMode TTS release")
struct TalkModeTTSReleaseTests {
    @Test func firstSentenceReleasedWithoutFinish() {
        var talk = TTSIncrementalChunker(policy: .conversational)
        var legacy = TTSIncrementalChunker()
        #expect(talk.append("Hello").isEmpty)
        #expect(talk.append(" there!") == ["Hello there!"])
        #expect(legacy.append("Hello there!").isEmpty)
        #expect(talk.append(" Second sentence.").isEmpty)
        #expect(talk.finish() == ["Second sentence."])
    }

    @Test(arguments: [1, 2, 9, 300])
    func arbitraryBoundariesDoNotRepeatOrLoseText(width: Int) {
        let text = "Hello there! " + String(repeating: "Another sentence with a little more information. ", count: 20)
        let chars = Array(text)
        var chunker = TTSIncrementalChunker(policy: .conversational)
        var chunks: [String] = []
        for i in stride(from: 0, to: chars.count, by: width) {
            chunks += chunker.append(String(chars[i..<min(chars.count, i + width)]))
        }
        chunks += chunker.finish()
        #expect(chunks.joined(separator: " ") == text.trimmingCharacters(in: .whitespaces))
    }

    @Test func clauseDeadlineAndMarkdown() {
        var chunker = TTSIncrementalChunker(policy: .conversational)
        let clause = "This clause has at least forty characters in it,"
        #expect(chunker.append(clause + " and more").isEmpty)
        #expect(chunker.releaseFirst(allowClause: true) == [clause])
        #expect(chunker.finish() == ["and more"])
        var markdown = TTSIncrementalChunker(policy: .conversational)
        #expect(markdown.append("**Hello!").isEmpty)
        #expect(markdown.releaseFirst(allowClause: true).isEmpty)
        #expect(markdown.append("**") == ["Hello!"])
        #expect(markdown.finish().isEmpty)
    }
}

@Suite("TalkMode completion races")
struct TalkModeCompletionRaceTests {
    @Test func completionDuringSpeechCandidateKeepsOnset() {
        var s = TalkModeSnapshot(state: .speaking, epoch: 3)
        let config = TalkModeConfiguration.default
        s = TalkModeReducer.reduce(s, .speechStarted(segment: 7, at: 1), config: config).0
        s = TalkModeReducer.reduce(s, .replyFinished(epoch: 3, at: 1.1), config: config).0
        #expect(s.state == .userSpeaking)
        #expect(s.segment == 7)
        #expect(s.speechStart == 1)
        #expect(s.epoch == 4)
    }
    @Test func speechEndConfirmsBargeEvenIfTimerWasDelayed() {
        var s = TalkModeSnapshot(state: .thinking, epoch: 3)
        let config = TalkModeConfiguration.default
        s = TalkModeReducer.reduce(s, .speechStarted(segment: 7, at: 1), config: config).0
        let result = TalkModeReducer.reduce(s, .speechEnded(segment: 7, at: 1.4), config: config)
        #expect(result.1 == [.cancelReply])
        #expect(result.0.state == .endOfTurn)
        #expect(result.0.speechDuration > 0.39)
    }
}

@Suite("TalkMode live policy changes")
struct TalkModePolicyChangeTests {
    @Test func disablingBargeInWithdrawsPendingCandidate() {
        var s = TalkModeSnapshot(state: .speaking, epoch: 3)
        var config = TalkModeConfiguration.default
        s = TalkModeReducer.reduce(s, .speechStarted(segment: 8, at: 1), config: config).0
        config.bargeInEnabled = false
        let result = TalkModeReducer.reduce(s, .tick(2), config: config)
        #expect(result.0.state == .speaking)
        #expect(result.0.candidateStart == nil)
        #expect(result.1.isEmpty)
    }
}

@Suite("Talk mode live-run recovery")
struct TalkModeRecoveryTests {
    private func step(_ s: inout TalkModeSnapshot, _ event: TalkModeEvent) -> [TalkModeEffect] {
        let result = TalkModeReducer.reduce(s, event, config: .default)
        s = result.0
        return result.1
    }

    @Test(arguments: [false, true])
    func renewedSpeechKeepsEarlierText(earlierFinalReady: Bool) {
        var s = TalkModeSnapshot()
        _ = step(&s, .start(aec: true))
        _ = step(&s, .speechStarted(segment: 1, at: 1))
        _ = step(&s, .speechEnded(segment: 1, at: 1.5))
        if earlierFinalReady { _ = step(&s, .final(segment: 1, text: "First part.")) }
        _ = step(&s, .speechStarted(segment: 2, at: 2.3))
        _ = step(&s, .speechEnded(segment: 2, at: 2.8))
        _ = step(&s, .final(segment: 2, text: "Second part."))
        if !earlierFinalReady {
            #expect(step(&s, .tick(4)).isEmpty)
            _ = step(&s, .final(segment: 1, text: "First part."))
        }
        #expect(step(&s, .tick(4)) == [.send(text: "First part. Second part.", epoch: s.epoch, speechEnd: 2.8)])
        #expect(abs(s.speechDuration - 1) < 0.0001)
    }

    @Test(arguments: [TalkModeState.thinking, .speaking])
    func turnErrorRecoversAndRejectsOldCallbacks(state: TalkModeState) {
        var s = TalkModeSnapshot(state: state, epoch: 7, aecActive: true)
        #expect(step(&s, .turnFailed(epoch: 7)) == [.cancelReply])
        #expect(s.state == .listening && s.epoch == 8 && s.aecActive)
        let recovered = s
        _ = step(&s, .firstAudio(epoch: 7))
        _ = step(&s, .replyFinished(epoch: 7, at: 3))
        _ = step(&s, .turnFailed(epoch: 7))
        #expect(s == recovered)
        _ = step(&s, .speechStarted(segment: 9, at: 4))
        _ = step(&s, .speechEnded(segment: 9, at: 4.5))
        _ = step(&s, .final(segment: 9, text: "Try again."))
        #expect(step(&s, .tick(6)).count == 1)
    }

    @Test func replyFailureKeepsConcurrentBargeOnset() {
        var s = TalkModeSnapshot(state: .speaking, epoch: 1)
        _ = step(&s, .speechStarted(segment: 2, at: 3))
        #expect(step(&s, .turnFailed(epoch: 1)) == [.cancelReply])
        #expect(s.state == .userSpeaking && s.segment == 2 && s.speechStart == 3)
    }

    @Test(arguments: [false, true])
    func asrFailureDoesNotStopCaptureOrDiscardNewerText(preview: Bool) {
        var s = TalkModeSnapshot()
        _ = step(&s, .start(aec: true))
        _ = step(&s, .speechStarted(segment: 1, at: 1))
        if !preview { _ = step(&s, .speechEnded(segment: 1, at: 1.5)) }
        _ = step(&s, .recognitionFailed(segment: 1))
        #expect(s.state == .listening)
        _ = step(&s, .speechStarted(segment: 2, at: 2))
        _ = step(&s, .speechEnded(segment: 2, at: 2.5))
        _ = step(&s, .speechStarted(segment: 3, at: 3))
        _ = step(&s, .speechEnded(segment: 3, at: 3.5))
        _ = step(&s, .final(segment: 3, text: "Keep this."))
        _ = step(&s, .recognitionFailed(segment: 2))
        #expect(step(&s, .tick(5)) == [.send(text: "Keep this.", epoch: s.epoch, speechEnd: 3.5)])
    }

    @Test func failureOfCurrentAccumulatedSegmentReturnsToListening() {
        var s = TalkModeSnapshot()
        _ = step(&s, .start(aec: true))
        _ = step(&s, .speechStarted(segment: 1, at: 1))
        _ = step(&s, .speechEnded(segment: 1, at: 1.5))
        _ = step(&s, .final(segment: 1, text: "Previous words"))
        _ = step(&s, .speechStarted(segment: 2, at: 2))
        _ = step(&s, .recognitionFailed(segment: 2))
        #expect(s.state == .listening)
        #expect(s.transcript == nil)
        _ = step(&s, .final(segment: 2, text: "Stale final"))
        #expect(step(&s, .tick(5)).isEmpty)
    }

    @Test func routesAndAECPolicy() {
        #expect(!TalkAudioPolicy.needsRebuild(running: true, inputUnchanged: true))
        #expect(TalkAudioPolicy.needsRebuild(running: false, inputUnchanged: true))
        #expect(TalkAudioPolicy.needsRebuild(running: true, inputUnchanged: false))
        #expect(TalkAudioPolicy.canUseAEC(requested: true, selectedInput: nil, defaultInput: 1))
        #expect(TalkAudioPolicy.canUseAEC(requested: true, selectedInput: 1, defaultInput: 1))
        #expect(!TalkAudioPolicy.canUseAEC(requested: true, selectedInput: 2, defaultInput: 1))
        #expect(!TalkAudioPolicy.canUseAEC(requested: true, selectedInput: 2, defaultInput: nil))
        #expect(!TalkAudioPolicy.canUseAEC(requested: false, selectedInput: nil, defaultInput: 1))
        var s = TalkModeSnapshot(state: .speaking, epoch: 1, aecActive: true)
        _ = step(&s, .aecChanged(false))
        #expect(!s.aecActive && s.state == .speaking && s.epoch == 1)
    }

    @Test func toggleDuringStopRemembersTargetAndConsumesOnce() {
        var restart = TalkRestartRequest()
        #expect(restart.take() == nil)
        let agent = UUID(), window = UUID()
        restart.queue(agentID: agent, windowID: window)
        let request = restart.take()
        #expect(request?.agentID == agent && request?.windowID == window)
        #expect(restart.take() == nil)
        restart.queue(agentID: nil, windowID: nil)
        #expect(restart.take() != nil)
    }

    @Test func speakingIsScopedToOwner() {
        let owner = UUID(), other = UUID()
        #expect(TalkAudioPolicy.speakingBelongsToSurface(talkActive: true, owner: owner, surface: owner))
        #expect(!TalkAudioPolicy.speakingBelongsToSurface(talkActive: true, owner: owner, surface: other))
        #expect(TalkAudioPolicy.speakingBelongsToSurface(talkActive: false, owner: nil, surface: other))
    }

    @Test func speculativeFinalReusesOnlyUninterruptedSilence() {
        var endpoint = TalkFinalizationPolicy()
        #expect(endpoint.update(active: false, silence: 0.25, endSilence: 0.7, sampleCount: 20_000) == .none)
        #expect(endpoint.update(active: false, silence: 0.28, endSilence: 0.7, sampleCount: 20_000) == .speculate)
        #expect(endpoint.update(active: false, silence: 0.5, endSilence: 0.7, sampleCount: 20_000) == .none)
        #expect(endpoint.update(active: false, silence: 0.71, endSilence: 0.7, sampleCount: 20_000) == .finalize(reuse: true))
        #expect(endpoint.update(active: false, silence: 0.28, endSilence: 0.7, sampleCount: 20_000) == .speculate)
        #expect(endpoint.update(active: true, silence: 0, endSilence: 0.7, sampleCount: 20_000) == .cancelSpeculation)
        #expect(endpoint.update(active: false, silence: 0.71, endSilence: 0.7, sampleCount: 20_000) == .finalize(reuse: false))
    }

    @Test func longUtteranceClosesInsteadOfFailing() {
        var endpoint = TalkFinalizationPolicy()
        #expect(endpoint.update(active: true, silence: 0, endSilence: 0.7, sampleCount: 16_000 * 120) == .finalize(reuse: false))
        #expect(endpoint.update(active: true, silence: 0, endSilence: 0.7, sampleCount: 4096) == .none)
    }

    @Test(arguments: [false, true])
    func speculativeDeliveryBeforeOrAfterCommit(completedFirst: Bool) {
        var ledger = TalkRecognitionLedger()
        let id = ledger.begin(segment: 1, kind: .speculative)
        if completedFirst {
            #expect(ledger.complete(id, result: .text("hello")) == nil)
            #expect(ledger.commitSpeculation() == .init(segment: 1, final: true, result: .text("hello")))
        } else {
            #expect(ledger.commitSpeculation() == nil)
            #expect(ledger.complete(id, result: .text("hello")) == .init(segment: 1, final: true, result: .text("hello")))
        }
        #expect(ledger.complete(id, result: .text("duplicate")) == nil)
    }

    @Test func staleRecognitionCannotPublishAndFailuresStayTurnScoped() {
        var ledger = TalkRecognitionLedger()
        let preview = ledger.begin(segment: 1, kind: .preview)
        #expect(ledger.cancelPreviews() == [preview])
        #expect(ledger.complete(preview, result: .text("stale")) == nil)
        let speculative = ledger.begin(segment: 1, kind: .speculative)
        #expect(ledger.complete(speculative, result: .text("incomplete")) == nil)
        #expect(ledger.cancelSpeculation() == speculative)
        #expect(ledger.commitSpeculation() == nil)
        #expect(ledger.complete(speculative, result: .failure("late")) == nil)
        let final = ledger.begin(segment: 1, kind: .final)
        #expect(ledger.complete(final, result: .failure("ASR error")) == .init(segment: 1, final: true, result: .failure("ASR error")))
        let next = ledger.begin(segment: 2, kind: .final)
        #expect(ledger.complete(next, result: .text("next"))?.segment == 2)
    }
}

@Suite("Conversational sentence boundaries")
struct TalkSentenceBoundaryTests {
    @Test(arguments: ["Dr.", "Mr.", "vs.", "e.g.", "i.e.", "The value is 3.", "List 1."])
    func periodIsNotAlwaysSentenceEnd(prefix: String) {
        var chunker = TTSIncrementalChunker(policy: .conversational)
        #expect(chunker.append(prefix).isEmpty)
        let tail = prefix == "The value is 3." ? "5 units. " : " Smith continues. "
        #expect(chunker.append(tail) == [(prefix + tail).trimmingCharacters(in: .whitespaces)])
    }

    @Test(arguments: ["Hello!world", "example.com", "Really?yes"])
    func punctuationNeedsFollowingSpace(text: String) {
        var chunker = TTSIncrementalChunker(policy: .conversational)
        #expect(chunker.append(text).isEmpty)
        #expect(chunker.finish() == TTSTextChunker.split(text))
    }

    @Test(arguments: ["Okay :) let's go.", "Use x < 5 here.", "A stray ) is fine!", "A < symbol is fine.", "Multiply x * 5 now."])
    func prosePunctuationDoesNotHoldSpeech(text: String) {
        var chunker = TTSIncrementalChunker(policy: .conversational)
        #expect(chunker.append(text) == [text])
        #expect(chunker.finish().isEmpty)
    }

    @Test func laterOpenMarkdownDoesNotHoldFirstSentence() {
        var chunker = TTSIncrementalChunker(policy: .conversational)
        #expect(chunker.append("First sentence. `unfinished code") == ["First sentence."])
        #expect(chunker.append("` ends here.").isEmpty)
        #expect(chunker.finish() == ["unfinished code ends here."])
    }

    @Test func codeStillWaitsForClosure() {
        var chunker = TTSIncrementalChunker(policy: .conversational)
        #expect(chunker.append("```swift\nprint(1). ").isEmpty)
        #expect(chunker.append("```\nNow speak.") == ["Now speak."])
    }
}

@Suite("Talk capture format renegotiation")
struct TalkCaptureFormatTests {
    @Test func usesEachBuffersSampleRate() throws {
        let resampler = TalkCaptureResampler()
        for rate in [48_000.0, 44_100, 16_000, 24_000] {
            let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false))
            let input = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate / 10)))
            input.frameLength = input.frameCapacity
            for index in 0..<Int(input.frameLength) { input.floatChannelData![0][index] = 0.25 }
            let samples = resampler.convert(input)
            // AVAudioConverter primes its filter once per format change.
            #expect(abs(samples.count - 1600) <= 256)
            #expect(abs(resampler.convert(input).count - 1600) <= 32)
            #expect(samples.allSatisfy { $0.isFinite })
            #expect(samples.contains { abs($0 - 0.25) < 0.01 })
        }
    }
}

@Suite("Talk route notification coalescing")
struct TalkRouteRecoveryTests {
    @Test func notificationsCoalesceAndShutdownInvalidatesPendingWork() async throws {
        let queue = DispatchQueue(label: "talk-route-test")
        let recovery = TalkRouteRecovery(queue: queue)
        let record = TalkRouteTestRecord()
        let start = ProcessInfo.processInfo.systemUptime
        queue.async {
            recovery.request { record.record() }
            recovery.request { record.record() }
        }
        try await Task.sleep(for: .milliseconds(100))
        queue.async { recovery.request { record.record() } }
        try await Task.sleep(for: .milliseconds(450))
        #expect(record.times.count == 1)
        #expect((record.times.first ?? start) - start >= 0.39)
        await withCheckedContinuation { continuation in
            queue.async {
                recovery.request { record.record() }
                recovery.cancel()
                continuation.resume()
            }
        }
        try await Task.sleep(for: .milliseconds(350))
        #expect(record.times.count == 1)
    }
}

private final class TalkRouteTestRecord: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [TimeInterval] = []
    var times: [TimeInterval] { lock.withLock { values } }
    func record() { lock.withLock { values.append(ProcessInfo.processInfo.systemUptime) } }
}
