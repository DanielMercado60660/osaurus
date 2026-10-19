// Copyright © 2026 osaurus.

import Combine
import Foundation
import Testing
@testable import OsaurusCore

/// Hardware-free player: scheduling does not play anything until the test
/// releases a completion, including callbacks arriving after cancellation.
private final class ManualTTSPlayer: TTSStreamPlayer, @unchecked Sendable {
    private let lock = NSLock()
    private var callbacks: [@Sendable (Bool) -> Void] = []
    private var stops = 0
    var pending: Int { lock.withLock { callbacks.count } }
    var stopCount: Int { lock.withLock { stops } }
    func prepareAndPlay() async throws {}
    func schedulePlayed(samples: [Float], completion: @escaping @Sendable (Bool) -> Void) {
        lock.withLock { callbacks.append(completion) }
    }
    func cancelPlayback() { lock.withLock { stops += 1 } }
    func playNext(played: Bool = true) {
        let callback = lock.withLock { callbacks.isEmpty ? nil : callbacks.removeFirst() }
        callback?(played)
    }
}

@Suite("Incremental TTS streams")
@MainActor
struct TTSStreamTests {
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(condition(), "Timed out waiting for stream state")
    }

    @Test("Arbitrary deltas preserve whole-text chunking", arguments: [1, 2, 7, 43, 241])
    func incrementalChunks(width: Int) {
        let text = "First sentence! " + String(repeating: "Another ordinary sentence with several words. ", count: 13)
            + "\n\nA new paragraph\nwith a soft wrap. " + String(repeating: "longword ", count: 70) + "tail"
        let chars = Array(text)
        var chunker = TTSIncrementalChunker()
        var chunks: [String] = []
        for offset in stride(from: 0, to: chars.count, by: width) {
            chunks += chunker.append(String(chars[offset..<min(offset + width, chars.count)]))
        }
        #expect(!chunks.isEmpty, "Long text must begin synthesis before finish")
        chunks += chunker.finish()
        #expect(chunks == TTSTextChunker.split(text))
    }

    @Test("Markdown split inside fences and links is stripped before speech")
    func markdownChunks() {
        let text = "**Hello!**\n\n```swift\n" + String(repeating: "do.not.read.this. ", count: 30)
            + "\n```\n\nRead [the documentation](https://example.com/long.path) now."
        var chunker = TTSIncrementalChunker()
        var chunks: [String] = []
        for character in text { chunks += chunker.append(String(character)) }
        chunks += chunker.finish()
        #expect(chunks == TTSTextChunker.split(MarkdownStripper.plainText(from: text)))
        #expect(!chunks.joined().contains("do.not.read"))
        #expect(!chunks.joined().contains("https"))
    }

    @Test("Lifecycle follows real playback, and synthesis can run ahead")
    func playedLifecycle() async {
        let player = ManualTTSPlayer()
        var synthesized: [String] = []
        let handle = TTSStreamHandle(id: "a", player: player) { text, emit in
            synthesized.append(text)
            try await emit([0.5, 0.5])
        }
        var events: [TTSStreamEvent] = []
        let subscription = handle.events.sink { events.append($0) }
        handle.enqueue(text: "First.\n\nSecond.")
        handle.finish()
        await waitUntil { player.pending == 2 }
        #expect(synthesized == ["First.", "Second."])
        #expect(events.isEmpty, "Synthesis/scheduling is not audible playback")
        player.playNext()
        await waitUntil { events.count == 1 }
        #expect(events == [.firstAudio(id: "a")])
        player.playNext()
        await waitUntil { events.count == 2 }
        #expect(events == [.firstAudio(id: "a"), .finished(id: "a")])
        handle.cancel()
        handle.enqueue(text: "Ignored.")
        handle.finish()
        #expect(events.count == 2)
        withExtendedLifetime(subscription) {}
    }

    @Test("Cancel before or after first audio suppresses late finished", arguments: [false, true])
    func cancelDraining(afterAudio: Bool) async {
        let player = ManualTTSPlayer()
        let handle = TTSStreamHandle(id: "cancel", player: player) { _, emit in
            try await emit(Array(repeating: 0.5, count: 1600))
        }
        var events: [TTSStreamEvent] = []
        let subscription = handle.events.sink { events.append($0) }
        handle.enqueue(text: "Hello.")
        handle.finish()
        await waitUntil { player.pending == 2 }
        if afterAudio {
            player.playNext()
            await waitUntil { events.count == 1 }
        }
        handle.cancel()
        #expect(player.stopCount == 1, "Player stopped before cancel returns")
        while player.pending > 0 { player.playNext() }
        for _ in 0..<10 { await Task.yield() }
        let expected: [TTSStreamEvent] = afterAudio
            ? [.firstAudio(id: "cancel"), .cancelled(id: "cancel")]
            : [.cancelled(id: "cancel")]
        #expect(events == expected)
        handle.cancel()
        handle.finish()
        #expect(events == expected)
        withExtendedLifetime(subscription) {}
    }

    @Test("Cancel before any input never starts synthesis")
    func cancelBeforeInput() {
        let player = ManualTTSPlayer()
        let handle = TTSStreamHandle(id: "early", player: player) { _, _ in
            Issue.record("Cancelled stream synthesized input")
        }
        var events: [TTSStreamEvent] = []
        let subscription = handle.events.sink { events.append($0) }
        handle.cancel()
        handle.enqueue(text: "Hello.")
        handle.finish()
        #expect(events == [.cancelled(id: "early")])
        #expect(player.pending == 0)
        withExtendedLifetime(subscription) {}
    }

    @Test("Cancellation during a suspended synthesizer rejects late audio")
    func cancelDuringSynthesis() async {
        let player = ManualTTSPlayer()
        var resume: CheckedContinuation<Void, Never>?
        var returned = false
        let handle = TTSStreamHandle(id: "suspended", player: player) { _, emit in
            defer { returned = true }
            await withCheckedContinuation { resume = $0 }
            try await emit([0.5])
        }
        var events: [TTSStreamEvent] = []
        let subscription = handle.events.sink { events.append($0) }
        handle.enqueue(text: "Hello.")
        handle.finish()
        await waitUntil { resume != nil }
        handle.cancel()
        resume?.resume()
        await waitUntil { returned }
        #expect(player.pending == 0)
        #expect(events == [.cancelled(id: "suspended")])
        withExtendedLifetime(subscription) {}
    }

    @Test("Cancellation releases synthesis waiting on a full playback queue")
    func cancelBackpressure() async {
        let player = ManualTTSPlayer()
        var returned = false
        let handle = TTSStreamHandle(id: "bounded", player: player) { _, emit in
            defer { returned = true }
            try await emit(Array(repeating: 0.5, count: 800 * 20))
        }
        var events: [TTSStreamEvent] = []
        let subscription = handle.events.sink { events.append($0) }
        handle.enqueue(text: "Hello.")
        handle.finish()
        await waitUntil { player.pending == 8 }
        handle.cancel()
        await waitUntil { returned }
        #expect(player.pending == 8)
        #expect(events == [.cancelled(id: "bounded")])
        withExtendedLifetime(subscription) {}
    }

    @Test("Synthesis failure is terminal and never claims playback finished")
    func synthesisFailure() async {
        struct Failure: Error {}
        let handle = TTSStreamHandle(id: "failure", player: ManualTTSPlayer()) { _, _ in throw Failure() }
        var events: [TTSStreamEvent] = []
        let subscription = handle.events.sink { events.append($0) }
        handle.enqueue(text: "Hello.")
        handle.finish()
        await waitUntil { !events.isEmpty }
        #expect(events.count == 1)
        if case .failed(id: "failure", message: _) = events[0] {} else {
            Issue.record("Expected failure, got \(events)")
        }
        withExtendedLifetime(subscription) {}
    }

    @Test("Scheduling failure is not reported as played audio")
    func schedulingFailure() async {
        let player = ManualTTSPlayer()
        let handle = TTSStreamHandle(id: "schedule", player: player) { _, emit in
            try await emit([0.5])
        }
        var events: [TTSStreamEvent] = []
        let subscription = handle.events.sink { events.append($0) }
        handle.enqueue(text: "Hello.")
        handle.finish()
        await waitUntil { player.pending == 1 }
        player.playNext(played: false)
        await waitUntil { !events.isEmpty }
        #expect(events == [.failed(id: "schedule", message: "Unable to schedule an audio buffer.")])
        withExtendedLifetime(subscription) {}
    }

    @Test("Empty stream completes without claiming first audio")
    func emptyStream() async {
        let handle = TTSStreamHandle(id: "empty", player: ManualTTSPlayer()) { _, _ in
            Issue.record("Empty stream synthesized")
        }
        var events: [TTSStreamEvent] = []
        let subscription = handle.events.sink { events.append($0) }
        handle.finish()
        await waitUntil { !events.isEmpty }
        #expect(events == [.finished(id: "empty")])
        withExtendedLifetime(subscription) {}
    }

    @Test("RMS is zero idle, positive for audio, bounded, and zero on silence")
    func outputLevel() {
        var meter = TTSOutputMeter()
        #expect(meter.level == 0)
        let rms = [Float](repeating: 0.5, count: 800).withUnsafeBufferPointer { TTSOutputMeter.rms($0) }
        #expect(abs(rms - 0.5) < 0.0001)
        #expect(meter.update(rms: rms) > 0)
        #expect(meter.update(rms: 100) == 1)
        #expect(meter.update(rms: 0) == 0)
        #expect(meter.update(rms: .nan) == 0)
    }
}

@Suite("TalkMode stream deadlines and shared player ownership")
@MainActor
struct TalkModeStreamLifecycleTests {
    @Test func clauseReleasesAfterDeadlineWithoutAnotherDelta() async {
        let player = ManualTTSPlayer()
        var chunks: [String] = []
        let handle = TTSStreamHandle(id: "clause", player: player, synthesize: { text, _ in
            chunks.append(text)
        }, releasePolicy: .conversational)
        let clause = "This is a long enough clause to start talking now,"
        handle.enqueue(text: clause + " followed by a tail")
        #expect(chunks.isEmpty)
        for _ in 0..<150 {
            if !chunks.isEmpty { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(chunks == [clause])
        handle.finish()
        for _ in 0..<50 {
            if chunks.count == 2 { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(chunks == [clause, "followed by a tail"])
    }

    @Test func releasingTerminalHandleDoesNotStopReusedDuplexPlayer() async {
        let player = ManualTTSPlayer()
        var handle: TTSStreamHandle? = TTSStreamHandle(id: "done", player: player, synthesize: { _, _ in })
        var finished = false
        let subscription = handle!.events.sink { if case .finished = $0 { finished = true } }
        handle?.finish()
        for _ in 0..<50 {
            if finished { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(finished)
        let stops = player.stopCount
        handle = nil
        #expect(player.stopCount == stops)
        withExtendedLifetime(subscription) {}
    }
}
