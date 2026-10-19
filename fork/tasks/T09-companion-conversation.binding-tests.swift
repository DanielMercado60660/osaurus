// Harness-only controller integration checks. The T09 verify script supplies
// inert ChatWindowManager/SpeechService/TTSService spies; never compile these
// tests against live singletons. No NSWindow, microphone or model is opened.
import Foundation
import Testing
@testable import OsaurusCore

@Suite("Companion headless binding (inert services)", .serialized)
@MainActor
struct CompanionBindingTests {
    private func settle(_ condition: () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(condition())
    }

    private func reset() async throws -> (TalkModeController, ChatWindowManager, UUID) {
        let talk = TalkModeController.shared
        talk.dismissCompanion()
        talk.stop()
        await settle { !talk.isActive }
        let manager = ChatWindowManager.shared
        manager.reset()
        let id = AgentManager.shared.activeAgent.id
        var configuration = TalkModeConfiguration()
        configuration.enabledAgentIds = [id]
        try TalkModeConfigurationStore.saveThrowing(configuration)
        return (talk, manager, id)
    }

    @Test func createsHeadlessThenReusesSessionAndCanRevealExplicitly() async throws {
        let (talk, manager, id) = try await reset()
        talk.toggle(agentID: id, withoutWindow: true)
        await settle { talk.state == .listening }
        #expect(manager.createdShowFlags == [false])
        #expect(manager.shownIDs.isEmpty)
        #expect(talk.usesCompanion)
        let ownedWindow = try #require(talk.windowID)
        #expect(talk.owns(try #require(manager.windowState(id: ownedWindow)?.session)))
        talk.stop()
        await settle { !talk.isActive }
        talk.toggle(agentID: id, withoutWindow: true)
        await settle { talk.state == .listening }
        #expect(talk.windowID == ownedWindow)
        #expect(manager.createdShowFlags == [false])
        #expect(manager.shownIDs.isEmpty)
        talk.stop()
        await settle { !talk.isActive }
        talk.toggle(agentID: id)
        await settle { talk.state == .listening }
        #expect(manager.shownIDs == [ownedWindow])
        #expect(!talk.usesCompanion)
        talk.stop()
        await settle { !talk.isActive }
    }

    @Test func focusedSessionIsBoundWithoutRaisingWindow() async throws {
        let (talk, manager, id) = try await reset()
        let window = manager.createWindow(agentId: id, showImmediately: false)
        manager.lastFocusedWindowId = window
        talk.toggle(agentID: id, withoutWindow: true)
        await settle { talk.state == .listening }
        #expect(talk.windowID == window)
        #expect(manager.shownIDs.isEmpty)
        #expect(manager.createdShowFlags == [false])
        talk.stop()
        await settle { !talk.isActive }
    }

    @Test func rapidRestartStaysHeadlessAndDismissalCancelsQueuedRestart() async throws {
        let (talk, manager, id) = try await reset()
        talk.toggle(agentID: id, withoutWindow: true)
        await settle { talk.state == .listening }
        talk.stop()
        talk.toggle(agentID: id, withoutWindow: true)
        await settle { talk.state == .listening && !talk.isStopping }
        #expect(talk.usesCompanion)
        #expect(manager.shownIDs.isEmpty)
        talk.stop()
        talk.toggle(agentID: id, withoutWindow: true)
        talk.dismissCompanion()
        await settle { !talk.isActive }
        try? await Task.sleep(for: .milliseconds(30))
        #expect(!talk.isActive)
        #expect(manager.shownIDs.isEmpty)
    }

    @Test func busySessionIsRejectedWithoutFocusOrCapture() async throws {
        let (talk, manager, id) = try await reset()
        let window = manager.createWindow(agentId: id, showImmediately: false)
        manager.windowState(id: window)?.session.isAvailableForDispatchReattachment = false
        talk.toggle(agentID: id, withoutWindow: true)
        #expect(!talk.isActive)
        #expect(talk.lastError != nil)
        #expect(manager.shownIDs.isEmpty)
    }
}
