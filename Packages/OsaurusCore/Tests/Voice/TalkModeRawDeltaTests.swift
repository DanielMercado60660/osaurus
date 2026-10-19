import Foundation
import Testing
@testable import OsaurusCore

@Suite("TalkMode raw content observation", .serialized)
@MainActor
struct TalkModeRawDeltaTests {
    @Test func rawContentPrecedesDisplayPacerAndExcludesReasoning() async {
        let key = "chatSmoothStreamingEnabled"
        let old = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(true, forKey: key)
        defer {
            if let old { UserDefaults.standard.set(old, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        let turn = ChatTurn(role: .assistant, content: "")
        let processor = StreamingDeltaProcessor(turn: turn)
        var raw = ""
        var visible = ""
        let start = ProcessInfo.processInfo.systemUptime
        var rawAt: Double?
        var visibleAt: Double?
        processor.onRawVisibleDelta = { raw += $0; if rawAt == nil { rawAt = ProcessInfo.processInfo.systemUptime } }
        processor.onVisibleDelta = { visible += $0; if visibleAt == nil { visibleAt = ProcessInfo.processInfo.systemUptime } }
        processor.receiveReasoning("private reasoning")
        processor.receiveDelta("First sentence. A second sentence.")
        #expect(raw == "First sentence. A second sentence.")
        #expect(visible.isEmpty)
        try? await Task.sleep(for: .milliseconds(60))
        await processor.finalize()
        #expect(raw == visible)
        if let rawAt, let visibleAt {
            print("TalkMode pacer measurement raw_ms=\((rawAt - start) * 1000) visible_ms=\((visibleAt - start) * 1000)")
            #expect(visibleAt > rawAt)
        } else { Issue.record("Both content hooks must fire") }
    }
}
