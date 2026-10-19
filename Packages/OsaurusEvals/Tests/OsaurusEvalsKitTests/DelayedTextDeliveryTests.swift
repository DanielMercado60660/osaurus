import Foundation
import XCTest
@testable import OsaurusCore
@testable import OsaurusEvalsKit

final class DelayedTextDeliveryTests: XCTestCase {
    private func driver() -> ScriptedCUDriver {
        ScriptedCUDriver(app: "TextEdit", elements: [
            .init(id: "body", role: "textarea", label: "Body", value: "Old draft", editable: true,
                  editCaptureValues: ["Hello agai", "Hello agai"])
        ])
    }

    func testImmediateObservationStillContainsPartialInput() async {
        let driver = driver()
        _ = await driver.perform(.typeText(id: "body", pid: 7777, text: "Hello again", replace: true))
        let first = await driver.capture(pid: 7777, tier: .ax)
        let second = await driver.capture(pid: 7777, tier: .ax)
        let third = await driver.capture(pid: 7777, tier: .ax)
        XCTAssertEqual(first.elements.first?.value, "Hello agai")
        XCTAssertEqual(second.elements.first?.value, "Hello agai")
        XCTAssertEqual(third.elements.first?.value, "Hello again")
    }

    func testVerificationWaitsForExactTextWithoutRepeatingMutation() async {
        for verb in [AgentVerb.type, .setValue, .clear] {
            let driver = driver()
            let initial = await driver.capture(pid: 7777, tier: .ax)
            var view: AgentView? = AgentView.build(from: initial, previous: nil)
            var snapshot: CUSnapshot? = initial
            var tier = CaptureTier.ax
            var image: CUImage?
            var metrics = ComputerUseRunMetrics()
            let expected = verb == .clear ? "" : "Hello again"
            let result = await ComputerUseLoop.act(
                action: AgentAction(verb: verb, target: AgentTarget(mark: 1), text: expected, replace: true),
                element: initial.elements.first, pid: 7777, driver: driver,
                availability: MacDriverAvailability(accessibility: true, screenRecording: true, skyLight: true),
                currentTier: &tier, pendingFrameImage: &image, lastView: &view, lastSnapshot: &snapshot,
                metrics: &metrics, feed: SubagentFeed(toolCallId: "settle", kindId: "computer_use", title: "settle"),
                step: 1
            )
            XCTAssertEqual(snapshot?.elements.first?.value, expected, verb.rawValue)
            XCTAssertFalse(result.contains("Hello agai\""), result)
            let trace = await driver.verbTrace()
            XCTAssertEqual(trace, [verb.rawValue])
            XCTAssertEqual(metrics.verifyChanged, 1)
        }
    }
}
