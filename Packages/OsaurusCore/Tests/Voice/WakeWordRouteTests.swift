import Testing
@testable import OsaurusCore

struct WakeWordRouteTests {
    @Test func bothSettingsSelectCompanion() {
        #expect(WakeWordRoute.resolve(companionEnabled: true, talkEnabledForAgent: true) == .companion)
    }

    @Test func eitherDisabledPreservesChat() {
        for (companion, talk) in [(false, false), (false, true), (true, false)] {
            #expect(WakeWordRoute.resolve(companionEnabled: companion, talkEnabledForAgent: talk) == .chat)
        }
    }
}
