// Appended to the T09 serialized suite by the T11 isolated verifier only.
// Uses the actual controller, with inert VAD/window/capture spies.
extension CompanionBindingTests {
    @Test func wakeHandoffResumesAlreadyPausedVADWithoutShowingChat() async throws {
        let (talk, manager, id) = try await reset()
        let vad = VADService.shared
        vad.state = .idle
        let resumes = vad.resumeCount
        talk.startFromWakeWord(agentID: id)
        await settle { talk.state == .listening }
        #expect(talk.usesCompanion)
        #expect(manager.createdShowFlags == [false])
        #expect(manager.shownIDs.isEmpty)
        talk.startFromWakeWord(agentID: id) // Late/duplicate detection is not a toggle.
        #expect(talk.state == .listening)
        talk.stop()
        await settle { vad.resumeCount == resumes + 1 }
        #expect(!talk.isActive)
        #expect(vad.state == .listening)
    }

    @Test func refusedWakeHandoffReturnsListeningOwnership() async throws {
        let (talk, manager, id) = try await reset()
        let window = manager.createWindow(agentId: id, showImmediately: false)
        manager.windowState(id: window)?.session.isAvailableForDispatchReattachment = false
        let vad = VADService.shared
        vad.state = .idle
        let resumes = vad.resumeCount
        talk.startFromWakeWord(agentID: id)
        await settle { vad.resumeCount == resumes + 1 }
        #expect(talk.lastError != nil)
        #expect(!talk.isActive)
        #expect(manager.shownIDs.isEmpty)
    }

    @Test func wakeStartupFailureAndImmediateStopResumeListening() async throws {
        for fail in [true, false] {
            let (talk, _, id) = try await reset()
            let vad = VADService.shared
            vad.state = .idle
            let resumes = vad.resumeCount
            SpeechService.shared.failStartup = fail
            talk.startFromWakeWord(agentID: id)
            if !fail { talk.stop() }
            await settle { vad.resumeCount == resumes + 1 }
            #expect(!talk.isActive)
            SpeechService.shared.failStartup = false
        }
    }

    @Test func queuedRestartInheritsWakeOwnershipUntilFinalStop() async throws {
        let (talk, manager, id) = try await reset()
        let vad = VADService.shared
        vad.state = .idle
        let attempts = vad.resumeAttempts
        let resumes = vad.resumeCount
        talk.startFromWakeWord(agentID: id)
        await settle { talk.state == .listening }
        talk.stop()
        talk.toggle(agentID: id, withoutWindow: true)
        await settle { talk.state == .listening && !talk.isStopping }
        #expect(vad.resumeAttempts == attempts)
        #expect(manager.shownIDs.isEmpty)
        talk.stop()
        await settle { vad.resumeCount == resumes + 1 }
    }

    @Test func ordinaryTalkResumesOnlyPreviouslyListeningVAD() async throws {
        for listening in [false, true] {
            let (talk, _, id) = try await reset()
            let vad = VADService.shared
            vad.state = listening ? .listening : .idle
            let resumes = vad.resumeCount
            talk.toggle(agentID: id)
            await settle { talk.state == .listening }
            talk.stop()
            await settle { !talk.isActive }
            #expect(vad.resumeCount == resumes + (listening ? 1 : 0))
        }
    }
    @Test func newTalkDuringWakeResumeDelayKeepsListeningOwnership() async throws {
        let (talk, _, id) = try await reset()
        let vad = VADService.shared
        vad.state = .idle
        let resumes = vad.resumeCount
        vad.delayResume = true
        talk.startFromWakeWord(agentID: id)
        await settle { talk.state == .listening }
        talk.stop()
        await settle { vad.resumeGate != nil }
        talk.toggle(agentID: id, withoutWindow: true)
        vad.delayResume = false
        vad.resumeGate?.resume()
        vad.resumeGate = nil
        await settle { talk.state == .listening }
        #expect(vad.resumeCount == resumes)
        talk.stop()
        await settle { vad.resumeCount == resumes + 1 }
    }

}
