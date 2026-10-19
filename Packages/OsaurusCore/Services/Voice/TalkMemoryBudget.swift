import Foundation

/// Advisory for the documented <=16 GiB Talk preset. Uses the existing
/// comfortable model budget and host reserve; never changes runtime limits,
/// sampling, privacy settings, or admission on larger machines.
public enum TalkMemoryBudget {
    public struct Component: Codable, Sendable {
        public let role: String
        public let estimatedBytes: UInt64?
        public let resident: Bool
        public init(role: String, estimatedBytes: UInt64?, resident: Bool) {
            self.role = role; self.estimatedBytes = estimatedBytes; self.resident = resident
        }
    }
    public struct Facts: Codable, Sendable {
        public let physicalBytes: UInt64
        public let comfortableBytes: UInt64
        public let availableBytes: UInt64?
        public let reserveBytes: UInt64
        public let components: [Component]
        public init(physicalBytes: UInt64, comfortableBytes: UInt64, availableBytes: UInt64?,
                    reserveBytes: UInt64, components: [Component]) {
            self.physicalBytes = physicalBytes; self.comfortableBytes = comfortableBytes
            self.availableBytes = availableBytes; self.reserveBytes = reserveBytes; self.components = components
        }
    }
    public struct Decision: Codable, Sendable, Equatable {
        public let outcome: String
        public let message: String?
        public let projectedBytes: UInt64?
    }
    static func sum(_ bytes: [UInt64]) -> UInt64 {
        bytes.reduce(0) { a, b in
            let result = a.addingReportingOverflow(b)
            return result.overflow ? .max : result.partialValue
        }
    }
    public static func assess(_ facts: Facts) -> Decision {
        guard facts.physicalBytes > 0, facts.physicalBytes <= 16 << 30 else {
            return Decision(outcome: "unaffected", message: nil, projectedBytes: nil)
        }
        guard facts.components.allSatisfy({ $0.estimatedBytes != nil }), let available = facts.availableBytes else {
            return Decision(outcome: "unknown", message:
                "Talk mode's memory estimate is unavailable. Load the selected models in Voice and Models, then retry. You can continue without an estimate.", projectedBytes: nil)
        }
        let projected = sum(facts.components.compactMap(\.estimatedBytes))
        // Residents are already reflected in availableBytes. Only cold engines
        // cost additional headroom. Never credit estimated unload bytes.
        let incremental = sum(facts.components.filter { !$0.resident }.compactMap(\.estimatedBytes))
        guard projected > facts.comfortableBytes || sum([incremental, facts.reserveBytes]) > available else {
            return Decision(outcome: "comfortable", message: nil, projectedBytes: projected)
        }
        let privacy = facts.components.contains { $0.role == "privacy" }
        return Decision(outcome: privacy ? "smaller_model_with_privacy" : "smaller_model", message: privacy
            ? "Use a smaller chat model while talking to leave room for the privacy filter and speech models. Privacy protection is not changed automatically."
            : "Use a smaller chat model while talking, or stop other local workloads to free memory for speech models.",
            projectedBytes: projected)
    }
}
