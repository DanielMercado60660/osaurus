import Foundation
import Testing
@testable import OsaurusCore

@Suite("Make it yours state")
struct MakeItYoursStateTests {
    private var pending: MakeItYoursState {
        MakeItYoursState(onboardingComplete: true, dismissed: false, speech: .pending, voice: .pending,
                        microphoneGranted: false, agentEnabled: false, companionEnabled: false, phone: .pending)
    }

    @Test func pendingRows() {
        let state = pending
        #expect(state.isVisible)
        #expect(state.talk == .pending)
        #expect(state.companion == .pending)
        #expect(state.phone == .pending)
    }

    @Test func onboardingAndDismissalGateVisibility() {
        var state = pending
        state.onboardingComplete = false
        #expect(!state.isVisible)
        state.onboardingComplete = true
        state.dismissed = true
        #expect(!state.isVisible)
    }

    @Test func allPrerequisitesRequiredForTalk() {
        var state = pending
        state.speech = .done; state.voice = .done
        #expect(state.talk == .pending)
        state.microphoneGranted = true
        #expect(state.talk == .pending)
        state.agentEnabled = true
        #expect(state.talk == .done)
        state.microphoneGranted = false
        #expect(state.talk == .pending)
    }

    @Test func completionAndExternalChanges() {
        var state = pending
        state.speech = .done; state.voice = .done
        state.microphoneGranted = true; state.agentEnabled = true
        state.companionEnabled = true
        #expect(state.isVisible) // Phone setup is not satisfied just by opening Settings.
        state.phone = .done
        #expect(!state.isVisible)
        state.companionEnabled = false
        #expect(state.isVisible)
        state.dismissed = true
        #expect(!state.isVisible)
    }

    @Test func combinedProgressAndIndeterminatePreparation() {
        var state = pending
        state.speech = .done; state.voice = .inProgress(0.4)
        #expect(state.combinedDownloadProgress == 0.7)
        #expect(state.talk == .inProgress(0.7))
        state.speech = .inProgress(nil)
        #expect(state.combinedDownloadProgress == nil)
        #expect(state.talk == .inProgress(nil))
        state.speech = .done; state.voice = .inProgress(nil)
        #expect(state.talk == .inProgress(nil)) // CoreML compilation, not a fake 100%.
    }

    @Test func progressIsBounded() {
        var state = pending
        state.speech = .inProgress(-1); state.voice = .inProgress(2)
        #expect(state.combinedDownloadProgress == 0.5)
        state.voice = .inProgress(.nan)
        #expect(state.combinedDownloadProgress == nil)
    }

    @Test func failuresWinOverOtherDownloadAndRetryCanRecover() {
        var state = pending
        state.speech = .failed("HTTP 503"); state.voice = .inProgress(0.5)
        #expect(state.talk == .failed("HTTP 503"))
        state.speech = .done; state.voice = .failed("disk full")
        #expect(state.talk == .failed("disk full"))
        state.voice = .inProgress(0.2)
        #expect(state.talk == .inProgress(0.6))
    }

    @Test func permissionRequestAndSaveFailure() {
        var state = pending
        state.requestingMicrophone = true
        #expect(state.talk == .inProgress(nil))
        state.requestingMicrophone = false
        state.setupError = "Permission denied"
        #expect(state.talk == .failed("Permission denied"))
        state.setupError = "Read-only filesystem"
        #expect(state.talk == .failed("Read-only filesystem"))
        state.setupError = nil
        #expect(state.talk == .pending)
    }

    @Test func agentSwitchDoesNotBorrowCompletion() {
        var state = pending
        state.speech = .done; state.voice = .done; state.microphoneGranted = true
        state.agentEnabled = true
        #expect(state.talk == .done)
        state.agentEnabled = false
        #expect(state.talk == .pending)
    }

    @Test func dismissalPersistsAcrossStoreInstancesAndCanBeRestored() throws {
        let suite = "MakeItYoursTests.\(UUID().uuidString)"
        let first = try #require(UserDefaults(suiteName: suite))
        defer { first.removePersistentDomain(forName: suite) }
        #expect(!MakeItYoursPreference.isDismissed(in: first))
        MakeItYoursPreference.setDismissed(true, in: first)
        let reopened = try #require(UserDefaults(suiteName: suite))
        #expect(MakeItYoursPreference.isDismissed(in: reopened))
        MakeItYoursPreference.setDismissed(false, in: reopened)
        #expect(!MakeItYoursPreference.isDismissed(in: first))
    }
}

@Suite("Notification authorization deferral")
struct NotificationAuthorizationPolicyTests {
    @Test(arguments: [false, true])
    func onboardingAlwaysDefers(alreadyRequested: Bool) {
        #expect(!NotificationAuthorizationPolicy.shouldRequest(
            onboardingRequired: true, alreadyRequested: alreadyRequested))
    }

    @Test func completionAndExistingUsersRequestOnce() {
        #expect(NotificationAuthorizationPolicy.shouldRequest(onboardingRequired: false, alreadyRequested: false))
        #expect(!NotificationAuthorizationPolicy.shouldRequest(onboardingRequired: false, alreadyRequested: true))
    }
}
