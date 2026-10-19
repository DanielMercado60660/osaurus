import Foundation
import Testing
@testable import OsaurusCore

@Suite("Avatar reducer")
struct AvatarMoodReducerTests {
    @Test func activityPrecedence() {
        var input = AvatarInputs(
            isSpeaking: true,
            speakingLevel: 1,
            isListening: true,
            listeningLevel: 1,
            isStreaming: true,
            hasError: true
        )
        #expect(reduce(input).isSpeaking)
        input.isSpeaking = false
        guard case .listening = reduce(input) else { Issue.record("Listening must beat thinking/error"); return }
        input.isListening = false
        #expect(reduce(input) == .thinking)
        input.isStreaming = false
        #expect(reduce(input) == .error)
        input.hasError = false
        #expect(reduce(input) == .idle)
    }

    @Test func thinkingEndsWithVisibleTextOrCancellation() {
        #expect(reduce(AvatarInputs(isStreaming: true)) == .thinking)
        #expect(reduce(AvatarInputs(isStreaming: true, hasVisibleText: true)) == .idle)
        #expect(AvatarMoodReducer.reduce(previous: .thinking, inputs: AvatarInputs(), elapsed: 0.1) == .idle)
    }

    @Test func attackAndReleaseAreSmoothed() throws {
        let input = AvatarInputs(isSpeaking: true, speakingLevel: 1)
        let rising = AvatarMoodReducer.reduce(previous: .speaking(0), inputs: input, elapsed: 0.03)
        guard case .speaking(let attack) = rising else { Issue.record("Expected speaking"); return }
        #expect(attack > 0 && attack < 1)
        let falling = AvatarMoodReducer.reduce(
            previous: .speaking(1),
            inputs: AvatarInputs(isSpeaking: true),
            elapsed: 0.03
        )
        guard case .speaking(let release) = falling else { Issue.record("Expected speaking"); return }
        #expect(release > 0 && release < 1)
        #expect(attack > 1 - release)
    }

    @Test func smoothingIsFrameRateIndependent() {
        let input = AvatarInputs(isListening: true, listeningLevel: 0.8)
        let single = AvatarMoodReducer.reduce(previous: .listening(0), inputs: input, elapsed: 0.1)
        var stepped: AvatarMood = .listening(0)
        for _ in 0 ..< 10 { stepped = AvatarMoodReducer.reduce(previous: stepped, inputs: input, elapsed: 0.01) }
        guard case .listening(let a) = single, case .listening(let b) = stepped else {
            Issue.record("Expected listening"); return
        }
        #expect(abs(a - b) < 0.0001)
    }

    @Test func transitionsDoNotCarryMicrophoneLevelIntoMouth() {
        #expect(
            AvatarMoodReducer.reduce(previous: .listening(1), inputs: AvatarInputs(isSpeaking: true), elapsed: 0.1)
                == .speaking(0)
        )
        #expect(
            AvatarMoodReducer.reduce(previous: .speaking(1), inputs: AvatarInputs(isListening: true), elapsed: 0.1)
                == .listening(0)
        )
        #expect(AvatarMoodReducer.reduce(previous: .speaking(1), inputs: AvatarInputs(), elapsed: 0.1) == .idle)
    }

    @Test func invalidLevelsAndElapsedTimeStayFinite() {
        for level in [Float(-1), .nan, .infinity] {
            #expect(reduce(AvatarInputs(isSpeaking: true, speakingLevel: level)) == .speaking(0))
        }
        #expect(
            AvatarMoodReducer.reduce(
                previous: .speaking(0),
                inputs: AvatarInputs(isSpeaking: true, speakingLevel: 4),
                elapsed: 10
            ) == .speaking(1)
        )
        #expect(
            AvatarMoodReducer.reduce(
                previous: .listening(0),
                inputs: AvatarInputs(isListening: true, listeningLevel: 1),
                elapsed: -1
            ) == .listening(0)
        )
    }

    @MainActor @Test func modelAcceptsInjectedAudioWithoutStartingServices() {
        struct SilentAudio: AvatarAudioLevelSource {
            var isSpeaking: Bool { false }
            var outputLevel: Float { 0 }
        }
        let model = AvatarStateModel(audio: SilentAudio())
        #expect(model.mood == .idle)
        model.update(AvatarInputs(isStreaming: true), elapsed: 0.1)
        #expect(model.mood == .thinking)
        model.update(AvatarInputs(), elapsed: 0.1)
        #expect(model.mood == .idle)
    }

    private func reduce(_ inputs: AvatarInputs) -> AvatarMood {
        AvatarMoodReducer.reduce(previous: .idle, inputs: inputs, elapsed: 0.1)
    }
}
