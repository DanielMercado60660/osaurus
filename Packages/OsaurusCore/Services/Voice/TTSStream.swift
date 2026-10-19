// Copyright © 2026 osaurus.

import Combine
import Foundation

public enum TTSStreamEvent: Equatable, Sendable {
    /// First player buffer has reached the output device (not merely synthesized).
    case firstAudio(id: String)
    case finished(id: String)
    case cancelled(id: String)
    case failed(id: String, message: String)
}

/// Small hardware seam: completions must mean *played back*, not consumed.
protocol TTSStreamPlayer: Sendable {
    func prepareAndPlay() async throws
    /// false means scheduling failed; it is never evidence of audible playback.
    func schedulePlayed(samples: [Float], completion: @escaping @Sendable (Bool) -> Void)
    func cancelPlayback()
}

/// Incremental counterpart of TTSTextChunker.split. Retains the last chunk:
/// later deltas can still extend that sentence or pack another sentence into it.
/// This intentionally preserves the existing 240-character grouping budget.
struct TTSIncrementalChunker {
    private var text = ""
    private var emitted = 0

    mutating func append(_ delta: String) -> [String] {
        text += delta
        // An unfinished Markdown construct can retroactively remove text (in
        // particular a fenced code block or link URL). Wait for its closure.
        guard Self.markdownIsClosed(text) else { return [] }
        let chunks = TTSTextChunker.split(MarkdownStripper.plainText(from: text))
        let stableCount = max(0, chunks.count - 1)
        guard stableCount > emitted else { return [] }
        let ready = Array(chunks[emitted..<stableCount])
        emitted = stableCount
        return ready
    }

    mutating func finish() -> [String] {
        let chunks = TTSTextChunker.split(MarkdownStripper.plainText(from: text))
        let ready = Array(chunks.dropFirst(emitted))
        text = ""
        emitted = 0
        return ready
    }

    private static func markdownIsClosed(_ text: String) -> Bool {
        // Conservative: unmatched markup delays speech until finish rather
        // than speaking a URL, code, or formatting delimiter prematurely.
        for marker in ["```", "~~~", "`", "*", "_", "~~"] {
            if (text.components(separatedBy: marker).count - 1) % 2 != 0 { return false }
        }
        for (open, close) in [("[", "]"), ("(", ")"), ("<", ">")] {
            if text.filter({ String($0) == open }).count != text.filter({ String($0) == close }).count {
                return false
            }
        }
        // A link destination may start in the very next delta.
        return !text.hasSuffix("]")
    }
}

/// Stateful RMS smoothing shared by mixer taps. Silence resets immediately so
/// idle output never leaves the avatar's mouth half open.
struct TTSOutputMeter {
    private(set) var level: Float = 0

    mutating func update(rms: Float) -> Float {
        guard rms.isFinite, rms > 0.00001 else {
            level = 0
            return level
        }
        level = min(1, max(0, level * 0.65 + rms * 0.35))
        return level
    }

    static func rms(_ samples: UnsafeBufferPointer<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        return sqrt(samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(samples.count))
    }
}

/// Main-actor, single-use stream. Subscribe to events before enqueueing text.
/// finish() closes input; playback drains asynchronously. cancel() is idempotent
/// and stops the player immediately, including after finish() while draining.
@MainActor
public final class TTSStreamHandle {
    public let id: String
    public var events: AnyPublisher<TTSStreamEvent, Never> { subject.eraseToAnyPublisher() }
    private let subject = PassthroughSubject<TTSStreamEvent, Never>()
    private let player: any TTSStreamPlayer
    private let synthesize: @MainActor (String, @escaping @MainActor ([Float]) async throws -> Void) async throws -> Void
    private let onTerminal: @MainActor () -> Void
    private var chunker = TTSIncrementalChunker()
    private let input: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation
    private var task: Task<Void, Never>?
    private var inputClosed = false
    private var synthesisDone = false
    private var terminal = false
    private var heardAudio = false
    private var pending = 0

    init(
        id: String,
        player: any TTSStreamPlayer,
        synthesize: @escaping @MainActor (String, @escaping @MainActor ([Float]) async throws -> Void) async throws -> Void,
        onTerminal: @escaping @MainActor () -> Void = {}
    ) {
        self.id = id
        self.player = player
        self.synthesize = synthesize
        self.onTerminal = onTerminal
        (input, continuation) = AsyncStream.makeStream(of: String.self)
    }

    isolated deinit {
        continuation.finish()
        task?.cancel()
        player.cancelPlayback()
    }

    public func enqueue(text: String) {
        guard !inputClosed, !terminal else { return }
        for chunk in chunker.append(text) { continuation.yield(chunk) }
        startIfNeeded()
    }

    public func finish() {
        guard !inputClosed, !terminal else { return }
        inputClosed = true
        for chunk in chunker.finish() { continuation.yield(chunk) }
        continuation.finish()
        startIfNeeded()
    }

    public func cancel() {
        guard !terminal else { return }
        // Invalidate callbacks before stop(), which can invoke completions for
        // buffers it discards. No discarded buffer may emit firstAudio/finished.
        terminal = true
        inputClosed = true
        continuation.finish()
        task?.cancel()
        task = nil
        player.cancelPlayback()
        onTerminal()
        subject.send(.cancelled(id: id))
        subject.send(completion: .finished)
    }

    private func startIfNeeded() {
        guard task == nil else { return }
        task = Task { [weak self, input, player, synthesize] in
            var prepared = false
            do {
                for await chunk in input {
                    try Task.checkCancellation()
                    if !prepared {
                        try await player.prepareAndPlay()
                        prepared = true
                    }
                    try Task.checkCancellation()
                    try await synthesize(chunk) { [weak self] samples in
                        // Small buffers bound firstAudio latency; the bounded
                        // queue keeps stop independent of synthesis run-ahead.
                        for start in stride(from: 0, to: samples.count, by: 800) {
                            while let self, self.pending >= 8, !self.terminal {
                                try await Task.sleep(for: .milliseconds(10))
                            }
                            try Task.checkCancellation()
                            guard let self, !self.terminal else { throw CancellationError() }
                            let frame = Array(samples[start..<min(start + 800, samples.count)])
                            self.pending += 1
                            player.schedulePlayed(samples: frame) { [weak self] played in
                                Task { @MainActor in self?.bufferCompleted(played: played) }
                            }
                        }
                    }
                }
                guard let self, !self.terminal else { return }
                self.synthesisDone = true
                self.completeIfDrained()
            } catch {
                guard let self, !self.terminal else { return }
                self.terminal = true
                self.inputClosed = true
                self.continuation.finish()
                player.cancelPlayback()
                self.onTerminal()
                self.subject.send(.failed(id: self.id, message: error.localizedDescription))
                self.subject.send(completion: .finished)
            }
        }
    }

    private func bufferCompleted(played: Bool) {
        guard !terminal else { return }
        guard played else {
            terminal = true
            inputClosed = true
            continuation.finish()
            task?.cancel()
            player.cancelPlayback()
            onTerminal()
            subject.send(.failed(id: id, message: "Unable to schedule an audio buffer."))
            subject.send(completion: .finished)
            return
        }
        pending -= 1
        if !heardAudio {
            heardAudio = true
            subject.send(.firstAudio(id: id))
        }
        completeIfDrained()
    }

    private func completeIfDrained() {
        guard !terminal, synthesisDone, pending == 0 else { return }
        terminal = true
        player.cancelPlayback()
        onTerminal()
        subject.send(.finished(id: id))
        subject.send(completion: .finished)
        task = nil
    }
}
