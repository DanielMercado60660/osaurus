import Foundation
import Testing
@testable import OsaurusCore

@Suite("Talk layered echo defense")
struct TalkEchoTests {
    let policy = TalkEchoPolicy()
    func step(_ s: inout TalkModeSnapshot, _ event: TalkModeEvent,
              config: TalkModeConfiguration = .default) -> [TalkModeEffect] {
        let result = TalkModeReducer.reduce(s, event, config: config)
        s = result.0
        return result.1
    }

    @Test(arguments: [false, true])
    func thresholdsAndCooldown(aec: Bool) {
        let gate = TalkSpeechGate(silenceMs: 700)
        let threshold: Float = aec ? 0.65 : 0.75
        gate.update(aec: aec, playback: true, ignoreUntil: 0, at: 1)
        #expect(!gate.detects(threshold - 0.01, micRMS: 0, at: 1))
        #expect(gate.detects(threshold, micRMS: 0.1, at: 1.1))
        gate.update(aec: aec, playback: false, ignoreUntil: 0, at: 2)
        #expect(!gate.detects(0.6, micRMS: 0.1, at: 2.249))
        #expect(gate.detects(threshold, micRMS: 0.1, at: 2.249))
        #expect(gate.detects(0.5, micRMS: 0.1, at: 2.250))
    }

    @Test func floorLearnsOnlyLowVADAndUsesBothConditions() {
        var floor = TalkEchoFloor()
        func detect(_ p: Float, _ rms: Float, _ time: Double) -> Bool {
            floor.detects(probability: p, micRMS: rms, outputRMS: 0, playback: true,
                          threshold: 0.65, at: time, policy: policy)
        }
        #expect(!detect(0.4, 0.02, 1))
        #expect(abs(floor.echoFloor - 0.02) < 0.00001)
        #expect(!detect(0.4, 0.04, 1.1))
        #expect(abs(floor.echoFloor - 0.024) < 0.00001)
        #expect(!detect(0.9, 0.05, 1.2))
        #expect(abs(floor.echoFloor - 0.024) < 0.00001)
        #expect(detect(0.65, 0.061, 1.3))
        #expect(!detect(0.1, 0.2, 1.4))
    }

    @Test func floorDecaysResetsAndTracksConcurrentOutput() {
        var floor = TalkEchoFloor()
        _ = floor.detects(probability: 0.1, micRMS: 0.02, outputRMS: 0.1, playback: true,
                          threshold: 0.65, at: 1, policy: policy)
        // Speaker amplitude doubles: learned coupling predicts the larger echo.
        let residual = floor.detects(probability: 0.9, micRMS: 0.07, outputRMS: 0.2, playback: true,
                                     threshold: 0.65, at: 1.1, policy: policy)
        let user = floor.detects(probability: 0.9, micRMS: 0.11, outputRMS: 0.2, playback: true,
                                 threshold: 0.65, at: 1.2, policy: policy)
        #expect(!residual && user)
        _ = floor.detects(probability: 0.1, micRMS: 0, outputRMS: 0, playback: false,
                          threshold: 0.5, at: 1.5, policy: policy)
        #expect(floor.echoFloor < 0.01)
        floor.reset()
        #expect(floor.echoFloor == 0)
        let gate = TalkSpeechGate(silenceMs: 700)
        gate.update(aec: true, playback: true, ignoreUntil: 0, at: 1)
        #expect(!gate.detects(0.1, micRMS: 0.1, at: 1))
        #expect(!gate.detects(0.9, micRMS: 0.1, at: 1.1))
        gate.beginReply()
        #expect(gate.detects(0.9, micRMS: 0.1, at: 1.2))
    }

    @Test func invalidMicCannotTrigger() {
        var floor = TalkEchoFloor()
        for rms: Float in [.nan, .infinity, -1] {
            let detected = floor.detects(probability: 1, micRMS: rms, outputRMS: 0,
                                         playback: true, threshold: 0.65, at: 1, policy: policy)
            #expect(!detected)
        }
    }

    @Test func exactPartialOverlapUnrelatedAndExpiredTranscripts() {
        var history = TalkEchoTranscripts()
        history.record("The sky is blue today! Oceans contain salt water.", at: 1, policy: policy)
        for text in ["THE SKY IS BLUE TODAY.", "sky is blue", "sky blue today actually stop"] {
            #expect(history.isEcho(text, at: 11, policy: policy))
        }
        #expect(!history.isEcho("please stop and tell a joke", at: 2, policy: policy))
        #expect(!history.isEcho("he", at: 2, policy: policy))
        #expect(!history.isEcho("!!!", at: 2, policy: policy))
        #expect(!history.isEcho("sky is blue", at: 11.001, policy: policy))
        #expect(!history.isEcho("sky is blue", at: 0, policy: policy))
        history.record("New reply.", at: 12, policy: policy)
        #expect(history.sentences.count == 1)
    }

    @Test(arguments: [false, true])
    func sustainedQualificationAndEchoRevert(aec: Bool) {
        var s = TalkModeSnapshot(state: .speaking, epoch: 10, aecActive: aec)
        _ = step(&s, .agentSpoke(text: "The sky is blue today.", at: 1))
        _ = step(&s, .speechStarted(segment: 2, at: 2))
        let duration = aec ? 0.25 : 0.30
        #expect(step(&s, .tick(2 + duration - 0.001)).isEmpty)
        #expect(step(&s, .tick(2 + duration + 0.001)) == [.pauseReply])
        #expect(s.epoch == 10 && s.state == .userSpeaking)
        _ = step(&s, .speechEnded(segment: 2, at: 2.5))
        #expect(step(&s, .final(segment: 2, text: "sky is blue")) == [.resumeReply])
        #expect(s.state == .speaking && s.epoch == 10 && s.echoRejectedSegments == 1)
        #expect(step(&s, .tick(4)).isEmpty)
        // Duplicate final cannot increment counters or send.
        #expect(step(&s, .final(segment: 2, text: "sky is blue")).isEmpty)
        #expect(s.echoRejectedSegments == 1)
    }

    @Test func realBargeInConfirmsOnlyOnFinalThenSends() {
        var s = TalkModeSnapshot(state: .speaking, epoch: 10, aecActive: true)
        _ = step(&s, .agentSpoke(text: "The sky is blue today.", at: 1))
        _ = step(&s, .speechStarted(segment: 2, at: 2))
        #expect(step(&s, .tick(2.25)) == [.pauseReply])
        _ = step(&s, .speechEnded(segment: 2, at: 2.6))
        #expect(step(&s, .final(segment: 2, text: "Tell me a joke instead")) == [.cancelReply])
        #expect(s.epoch == 11 && s.tentativeReplyState == nil)
        _ = step(&s, .firstAudio(epoch: 10))
        #expect(s.state == .endOfTurn)
        #expect(step(&s, .tick(3.4)) == [.send(text: "Tell me a joke instead", epoch: 11, speechEnd: 2.6)])
    }

    @Test func longerConfiguredDurationWinsAndNoiseDoesNotPause() {
        var s = TalkModeSnapshot(state: .speaking, aecActive: true)
        var config = TalkModeConfiguration()
        config.bargeInMinSpeechMs = 500
        _ = step(&s, .speechStarted(segment: 1, at: 1), config: config)
        #expect(step(&s, .tick(1.3), config: config).isEmpty)
        #expect(step(&s, .speechEnded(segment: 1, at: 1.4), config: config).isEmpty)
        #expect(s.state == .speaking && s.candidateSegment == nil)
    }

    @Test func recognitionFailureAndEmptyFinalResumeReply() {
        for failure in [true, false] {
            var s = TalkModeSnapshot(state: .speaking, epoch: 2, aecActive: true)
            _ = step(&s, .speechStarted(segment: 1, at: 1))
            _ = step(&s, .tick(1.25))
            _ = step(&s, .speechEnded(segment: 1, at: 1.5))
            if failure {
                #expect(step(&s, .recognitionFailed(segment: 1)) == [.resumeReply])
            } else {
                _ = step(&s, .final(segment: 1, text: "um"))
                #expect(step(&s, .tick(2.3)) == [.resumeReply])
            }
            #expect(s.state == .speaking && s.epoch == 2)
        }
    }

    @Test func completedReplyDoesNotResumeAndLateEchoDoesNotSend() {
        var s = TalkModeSnapshot(state: .speaking, epoch: 2, aecActive: true)
        _ = step(&s, .agentSpoke(text: "The sky is blue.", at: 1))
        _ = step(&s, .speechStarted(segment: 1, at: 1))
        _ = step(&s, .tick(1.25))
        _ = step(&s, .replyFinished(epoch: 2, at: 1.3))
        _ = step(&s, .speechEnded(segment: 1, at: 1.5))
        #expect(step(&s, .final(segment: 1, text: "sky is blue")).isEmpty)
        #expect(s.state == .listening)
        _ = step(&s, .speechStarted(segment: 2, at: 2))
        _ = step(&s, .speechEnded(segment: 2, at: 2.6))
        _ = step(&s, .final(segment: 2, text: "sky is blue"))
        #expect(step(&s, .tick(3.5)).isEmpty)
        #expect(s.echoRejectedSegments == 2 && s.state == .listening)
    }

    @Test func sentenceMatchingPreservesDecimalsAndAbbreviations() {
        var history = TalkEchoTranscripts()
        history.record("Dr. Smith calculated 3.5. Next sentence!", at: 1, policy: policy)
        #expect(history.isEcho("Dr Smith calculated 3.5", at: 2, policy: policy))
        #expect(history.isEcho("3.5", at: 2, policy: policy))
        #expect(history.isEcho("Next sentence", at: 2, policy: policy))
    }

    @Test func exactFinalArrivalTimeExpiresEchoWindow() {
        var s = TalkModeSnapshot(state: .listening, epoch: 2, aecActive: true)
        _ = step(&s, .agentSpoke(text: "The sky is blue.", at: 1))
        _ = step(&s, .speechStarted(segment: 1, at: 10))
        _ = step(&s, .speechEnded(segment: 1, at: 10.6))
        _ = step(&s, .final(segment: 1, text: "sky is blue", at: 11.001))
        #expect(s.echoRejectedSegments == 0)
        #expect(step(&s, .tick(12)) == [.send(text: "sky is blue", epoch: s.epoch, speechEnd: 10.6)])
    }

    @Test(arguments: [0.1, 0.4])
    func lateEchoFinalPreservesNewerUserTextButNotEchoDuration(userDuration: Double) {
        var s = TalkModeSnapshot(state: .listening, epoch: 2, aecActive: true)
        _ = step(&s, .agentSpoke(text: "The sky is blue.", at: 1))
        _ = step(&s, .speechStarted(segment: 1, at: 2))
        _ = step(&s, .speechEnded(segment: 1, at: 2.5))
        _ = step(&s, .speechStarted(segment: 2, at: 3))
        _ = step(&s, .speechEnded(segment: 2, at: 3 + userDuration))
        _ = step(&s, .final(segment: 2, text: "Tell a joke"))
        _ = step(&s, .final(segment: 1, text: "sky is blue"))
        #expect(s.echoRejectedSegments == 1 && s.transcript == "Tell a joke")
        #expect(abs(s.speechDuration - userDuration) < 0.00001)
        let effects = step(&s, .tick(5))
        #expect(effects.count == (userDuration >= 0.3 ? 1 : 0))
    }

    @Test func recoveryRetainsEchoHistoryAndCounters() {
        var s = TalkModeSnapshot(state: .speaking, epoch: 2, aecActive: true)
        _ = step(&s, .agentSpoke(text: "The sky is blue.", at: 1))
        _ = step(&s, .turnFailed(epoch: 2))
        for segment in [1, 2] {
            _ = step(&s, .speechStarted(segment: segment, at: 2))
            _ = step(&s, .speechEnded(segment: segment, at: 2.6))
            _ = step(&s, .final(segment: segment, text: "sky is blue"))
        }
        #expect(s.echoRejectedSegments == 2 && s.state == .listening)
        _ = step(&s, .speechStarted(segment: 3, at: 3))
        _ = step(&s, .recognitionFailed(segment: 3))
        #expect(s.echoRejectedSegments == 2)
        #expect(s.spoken.isEcho("sky is blue", at: 4, policy: policy))
    }

    @Test func disablingBargeDuringTentativePauseRestoresAndStopInvalidates() {
        var s = TalkModeSnapshot(state: .speaking, epoch: 2, aecActive: true)
        _ = step(&s, .speechStarted(segment: 1, at: 1))
        _ = step(&s, .tick(1.25))
        var config = TalkModeConfiguration()
        config.bargeInEnabled = false
        #expect(step(&s, .tick(1.3), config: config) == [.resumeReply])
        #expect(s.state == .speaking && s.segment == nil)
        _ = step(&s, .speechStarted(segment: 2, at: 2))
        _ = step(&s, .tick(2.25))
        #expect(step(&s, .stop) == [.cancelReply])
        let stopped = s
        _ = step(&s, .final(segment: 2, text: "stale"))
        _ = step(&s, .firstAudio(epoch: 2))
        _ = step(&s, .speechEnded(segment: 2, at: 2.5))
        #expect(s == stopped)
    }

    @Test func firstAudioDuringTentativeThinkingPausesAndEchoResumesIt() {
        var s = TalkModeSnapshot(state: .thinking, epoch: 2, aecActive: true)
        _ = step(&s, .agentSpoke(text: "The sky is blue.", at: 1))
        _ = step(&s, .speechStarted(segment: 1, at: 1))
        #expect(step(&s, .tick(1.25)).isEmpty)
        #expect(step(&s, .firstAudio(epoch: 2)) == [.pauseReply])
        _ = step(&s, .speechEnded(segment: 1, at: 1.6))
        #expect(step(&s, .final(segment: 1, text: "sky is blue")) == [.resumeReply])
        #expect(s.state == .speaking)
    }

    @Test func aecFallbackReasonsKeepFailureText() {
        #expect(TalkAudioPolicy.aecOffReason(requested: false) == "Disabled in Talk Mode settings")
        #expect(TalkAudioPolicy.aecOffReason(requested: true).contains("Selected input"))
        #expect(TalkAudioPolicy.aecOffReason(requested: true, failure: "VPIO OSStatus -10851")
                == "Apple voice processing failed: VPIO OSStatus -10851")
    }

    @Test func echoOptionParsing() throws {
        let base = ["OSAURUS_TALK_INPUT_WAV": "/tmp/test.wav"]
        #expect(try TalkBenchmarkConfiguration.parse(base)?.echo == nil)
        let config = try #require(try TalkBenchmarkConfiguration.parse(base.merging(["OSAURUS_TALK_ECHO_DB": "-20"]) { _, b in b }))
        #expect(config.echo?.delayMs == 30)
        #expect(abs((config.echo?.gain ?? 0) - 0.1) < 0.00001)
        for value in ["nan", "inf", "1", "-61", "bad"] {
            #expect(throws: TalkBenchmarkError.self) {
                try TalkBenchmarkConfiguration.parse(base.merging(["OSAURUS_TALK_ECHO_DB": value]) { _, b in b })
            }
        }
        for value in ["-1", "1001", "1.5"] {
            #expect(throws: TalkBenchmarkError.self) {
                try TalkBenchmarkConfiguration.parse(base.merging(["OSAURUS_TALK_ECHO_DB": "-20", "OSAURUS_TALK_ECHO_DELAY_MS": value]) { _, b in b })
            }
        }
        #expect(throws: TalkBenchmarkError.self) {
            try TalkBenchmarkConfiguration.parse(base.merging(["OSAURUS_TALK_ECHO_DELAY_MS": "30"]) { _, b in b })
        }
    }

    @Test func mixerDelayGainTailAndResampling() {
        var mixer = TalkBenchmarkEchoMixer(config: .init(decibels: -20, delayMs: 30))
        let silent = [Float](repeating: 0, count: 320)
        let first = mixer.mix(input: silent, output24k: Array(repeating: 1, count: 480))
        #expect(first.allSatisfy { $0 == 0 })
        let second = mixer.mix(input: silent, output24k: Array(repeating: 0, count: 480))
        #expect(second.prefix(160).allSatisfy { $0 == 0 })
        #expect(second.suffix(160).allSatisfy { abs($0 - 0.1) < 0.00001 })
        let third = mixer.mix(input: silent, output24k: [])
        #expect(third.prefix(160).allSatisfy { abs($0 - 0.1) < 0.00001 })
        #expect(third.suffix(160).allSatisfy { $0 == 0 })
        #expect(mixer.mixedSamples == 320)
        var immediate = TalkBenchmarkEchoMixer(config: .init(decibels: 0, delayMs: 0))
        let resampled = immediate.mix(input: [0, 0, 0], output24k: [0, 0.2, 0.4, 0.6, 0.8])
        #expect(resampled == [0, 0.3, 0.6])
    }
}
