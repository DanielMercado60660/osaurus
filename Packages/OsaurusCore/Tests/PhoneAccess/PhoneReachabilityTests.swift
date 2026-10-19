import Foundation
import Testing
@testable import OsaurusCore

@Suite("Phone reachability")
struct PhoneReachabilityTests {
    @Test func assertionPolicy() {
        for enabled in [false, true] {
            for power in [PhoneReachabilityPolicy.Power.ac, .battery, .unknown] {
                #expect(PhoneReachabilityPolicy.preventsIdleSleep(phoneEnabled: enabled, power: power) == (enabled && power == .ac))
            }
        }
    }
    @Test func loginPreferenceComposition() {
        for general in [false, true] {
            for phone in [false, true] {
                #expect(PhoneReachabilityPolicy.requiresLogin(generalPreference: general, phoneEnabled: phone) == (general || phone))
            }
        }
    }
    @Test func freshHealthAndTimeout() {
        var health = PhoneHelperHealth()
        let noPendingProbe = !health.shouldRestart(now: 0)
        #expect(noPendingProbe)
        let firstCheck = health.begin(now: 20)
        #expect(firstCheck)
        let coalescedCheck = !health.begin(now: 25)
        #expect(coalescedCheck)
        #expect(health.deadline == 30)
        let beforeDeadline = !health.shouldRestart(now: 29.99)
        #expect(beforeDeadline)
        let restartAtDeadline = health.shouldRestart(now: 30)
        #expect(restartAtDeadline)
        let restartOnlyOnce = !health.shouldRestart(now: 31)
        #expect(restartOnlyOnce)
        let nextCheck = health.begin(now: 40)
        #expect(nextCheck)
        health.running()
        let freshRunningCancelsRestart = !health.shouldRestart(now: 50)
        #expect(freshRunningCancelsRestart)
        let cancelledCheck = health.begin(now: 60)
        #expect(cancelledCheck)
        health.cancel()
        let stopCancelsRestart = !health.shouldRestart(now: 70)
        #expect(stopCancelsRestart)
    }
    @Test func oldRunningCannotSatisfyWake() {
        var health = PhoneHelperHealth()
        health.running()
        let wakeCheck = health.begin(now: 100)
        #expect(wakeCheck)
        let staleRunningDoesNotSatisfyCheck = health.shouldRestart(now: 110)
        #expect(staleRunningDoesNotSatisfyCheck)
    }
    @Test func statusLines() {
        var state = PhoneAccessState()
        func text(_ enabled: Bool = true, _ power: PhoneReachabilityPolicy.Power = .ac, _ assertion: Bool = true) -> String {
            PhoneReachabilityPolicy.status(enabled: enabled, power: power, assertionActive: assertion, state: state)
        }
        #expect(text(false) == "Phone access is off")
        #expect(text(true, .battery).contains("Mac will sleep on battery"))
        #expect(text(true, .unknown).contains("power source is unknown"))
        #expect(text(true, .ac, false).contains("could not prevent idle sleep"))
        #expect(text().contains("connecting"))
        state.start()
        state.receive(.init(type: "login_url", value: "https://login.tailscale.com/abc"))
        #expect(text() == "Not reachable: sign in to Tailscale")
        state.receive(.init(type: "running", value: "https://mac.tail.ts.net/phone"))
        #expect(text() == "Reachable at https://mac.tail.ts.net/phone · Mac stays awake on power")
        state.fail("No helper")
        #expect(text() == "Not reachable: No helper")
    }
}
