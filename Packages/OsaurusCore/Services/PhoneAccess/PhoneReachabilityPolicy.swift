import Foundation

/// Pure policies shared by the runtime and deterministic tests.
enum PhoneReachabilityPolicy {
    enum Power: Equatable { case ac, battery, unknown }

    static func preventsIdleSleep(phoneEnabled: Bool, power: Power) -> Bool {
        phoneEnabled && power == .ac
    }

    static func requiresLogin(generalPreference: Bool, phoneEnabled: Bool) -> Bool {
        generalPreference || phoneEnabled
    }

    static func status(enabled: Bool, power: Power, assertionActive: Bool, state: PhoneAccessState) -> String {
        guard enabled else { return "Phone access is off" }
        if power == .battery { return "Not always reachable: Mac will sleep on battery" }
        if power == .unknown { return "Not always reachable: power source is unknown" }
        guard assertionActive else { return "Not always reachable: could not prevent idle sleep" }
        guard state.phase == .running, let url = state.phoneURL else {
            switch state.phase {
            case .needsLogin: return "Not reachable: sign in to Tailscale"
            case .failed: return "Not reachable: \(state.error ?? "Phone helper failed")"
            default: return "Not reachable: connecting to Tailscale…"
            }
        }
        return "Reachable at \(url.absoluteString) · Mac stays awake on power"
    }
}

/// A fresh running event is required after each check; a cached running state
/// never answers a wake/network probe. Repeated network events cannot defer it.
struct PhoneHelperHealth: Equatable {
    private(set) var deadline: TimeInterval?
    mutating func begin(now: TimeInterval) -> Bool {
        guard deadline == nil else { return false }
        deadline = now + 10
        return true
    }
    mutating func running() { deadline = nil }
    mutating func cancel() { deadline = nil }
    mutating func shouldRestart(now: TimeInterval) -> Bool {
        guard let deadline, now >= deadline else { return false }
        self.deadline = nil
        return true
    }
}
