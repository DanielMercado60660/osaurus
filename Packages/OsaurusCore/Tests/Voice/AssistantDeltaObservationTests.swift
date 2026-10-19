// Copyright © 2026 osaurus.

import Foundation
import Testing
@testable import OsaurusCore

@Suite("Voice assistant delta observation")
@MainActor
struct AssistantDeltaObservationTests {
    @Test("Visible observer excludes reasoning and drains before finalization returns")
    func visibleOnly() async {
        let turn = ChatTurn(role: .assistant, content: "")
        let processor = StreamingDeltaProcessor(turn: turn)
        var observed = ""
        processor.onVisibleDelta = { observed += $0 }
        processor.receiveReasoning("Private reasoning.")
        processor.receiveDelta("Hello")
        processor.receiveDelta(" there.")
        // Explicit flush also works when the test runner does not pump timers.
        processor.flush()
        await processor.finalize()
        #expect(observed == "Hello there.")
        #expect(turn.content == observed)
        #expect(!observed.contains("Private"))
        await processor.finalize()
        #expect(observed == "Hello there.", "Repeated finalize cannot duplicate deltas")
    }
}
