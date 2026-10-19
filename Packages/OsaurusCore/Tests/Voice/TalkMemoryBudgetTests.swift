import Foundation
import Testing
@testable import OsaurusCore

struct TalkMemoryBudgetTests {
    private let gib: UInt64 = 1 << 30
    private func facts(_ components: [TalkMemoryBudget.Component], available: UInt64? = 12 << 30,
                       physical: UInt64 = 16 << 30, comfortable: UInt64 = 9 << 30) -> TalkMemoryBudget.Facts {
        .init(physicalBytes: physical, comfortableBytes: comfortable, availableBytes: available,
              reserveBytes: 3 << 30, components: components)
    }

    @Test func comfortableBoundaryAndOneByteOver() {
        let c = TalkMemoryBudget.Component(role: "chat", estimatedBytes: 9 * gib, resident: false)
        #expect(TalkMemoryBudget.assess(facts([c])).outcome == "comfortable")
        #expect(TalkMemoryBudget.assess(facts([c], comfortable: 9 * gib - 1)).outcome == "smaller_model")
    }
    @Test func residentBytesAreNotChargedAgainAgainstHostHeadroom() {
        let resident = TalkMemoryBudget.Component(role: "stt", estimatedBytes: 2 * gib, resident: true)
        #expect(TalkMemoryBudget.assess(facts([resident], available: 3 * gib)).outcome == "comfortable")
        let cold = TalkMemoryBudget.Component(role: "stt", estimatedBytes: 2 * gib, resident: false)
        #expect(TalkMemoryBudget.assess(facts([cold], available: 3 * gib)).outcome == "smaller_model")
    }
    @Test func unknownIsNotZeroAndLargeMachinesAreUnaffected() {
        let unknown = TalkMemoryBudget.Component(role: "stt", estimatedBytes: nil, resident: false)
        #expect(TalkMemoryBudget.assess(facts([unknown])).outcome == "unknown")
        #expect(TalkMemoryBudget.assess(facts([], available: nil)).outcome == "unknown")
        #expect(TalkMemoryBudget.assess(facts([unknown], available: nil, physical: 32 * gib)).outcome == "unaffected")
        #expect(TalkMemoryBudget.assess(facts([unknown], physical: 16 * gib + 1)).message == nil)
    }
    @Test func privacySpecificRemedyOnlyWhenItIsActuallyPresent() {
        let chat = TalkMemoryBudget.Component(role: "chat", estimatedBytes: 8 * gib, resident: true)
        let privacy = TalkMemoryBudget.Component(role: "privacy", estimatedBytes: 3 * gib, resident: true)
        let decision = TalkMemoryBudget.assess(facts([chat, privacy]))
        #expect(decision.outcome == "smaller_model_with_privacy")
        #expect(decision.message?.contains("Privacy protection is not changed automatically.") == true)
        #expect(TalkMemoryBudget.assess(facts([chat])).message == nil)
    }
    @Test func overflowNeverWrapsIntoComfortable() {
        #expect(TalkMemoryBudget.sum([.max, 1]) == .max)
        let c = TalkMemoryBudget.Component(role: "chat", estimatedBytes: .max, resident: false)
        #expect(TalkMemoryBudget.assess(facts([c, c])).outcome == "smaller_model")
    }
    @Test func registryDeduplicatesOwnerAndTracksRealLifetime() {
        let registry = AuxiliaryModelResidency()
        var owner: NSObject? = NSObject()
        registry.track(owner!, kind: .stt, estimatedBytes: 100)
        registry.track(owner!, kind: .stt, estimatedBytes: 200)
        #expect(registry.snapshot().count == 1)
        #expect(registry.knownEstimatedBytes == 200)
        var worker = owner
        owner = nil // stopping the service must not erase a retained worker
        #expect(registry.knownEstimatedBytes == 200)
        withExtendedLifetime(worker) {}
        worker = nil
        #expect(registry.snapshot().isEmpty)
    }
    @Test func replacementAndFailureReleaseOnlyTheirOwnOwners() {
        let registry = AuxiliaryModelResidency()
        let old = NSObject()
        var candidate: NSObject? = NSObject()
        registry.track(old, kind: .tts, estimatedBytes: 200)
        registry.track(candidate!, kind: .tts, estimatedBytes: nil)
        #expect(registry.snapshot().count == 2)
        candidate = nil // failed replacement, old model still retained
        #expect(registry.snapshot().count == 1)
        #expect(registry.knownEstimatedBytes == 200)
        withExtendedLifetime(old) {}
    }
    @Test func artifactMeasurementIncludesNestedWeightsAndDeduplicatesRoots() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let weights = root.appendingPathComponent("Model.mlmodelc/weights")
        try FileManager.default.createDirectory(at: weights, withIntermediateDirectories: true)
        let file = weights.appendingPathComponent("data.bin")
        try Data(repeating: 0, count: 100).write(to: file)
        #expect(AuxiliaryModelEstimate.bytes(at: [root]) == 125)
        #expect(AuxiliaryModelEstimate.bytes(at: [root, file]) == 125)
        #expect(AuxiliaryModelEstimate.bytes(at: [root.appendingPathComponent("missing")]) == nil)
        #expect(AuxiliaryModelEstimate.bytes(at: []) == nil)
    }
}
