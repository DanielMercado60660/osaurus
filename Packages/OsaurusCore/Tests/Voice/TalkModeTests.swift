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
