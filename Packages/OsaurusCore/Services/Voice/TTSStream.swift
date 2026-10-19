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

public enum TTSStreamReleasePolicy: Sendable {
    case grouped
    case conversational
}

/// Incremental counterpart of TTSTextChunker.split. Retains the last chunk:
/// later deltas can still extend that sentence or pack another sentence into it.
/// This intentionally preserves the existing 240-character grouping budget.
struct TTSIncrementalChunker {
    private var text = ""
    private var emitted = 0
    private var firstPrefixCount = 0
    private let policy: TTSStreamReleasePolicy
    private(set) var releasedFirst = false

    init(policy: TTSStreamReleasePolicy = .grouped) { self.policy = policy }

    /// Called by the stream's 500 ms deadline as well as by incoming deltas.
    mutating func releaseFirst(allowClause: Bool) -> [String] {
        guard policy == .conversational, !releasedFirst else { return [] }
        // A later unfinished construct must not hold an already closed sentence.
        let candidate = Self.firstSentenceCandidate(text)
        guard Self.markdownIsClosed(candidate, includingStrong: true) else { return [] }
        let plain = MarkdownStripper.plainText(from: text)
        var boundary = Self.sentenceBoundary(in: plain)
        if boundary == nil && allowClause {
            boundary = plain.indices.first { index in
                ",;".contains(plain[index]) && plain.distance(from: plain.startIndex, to: index) >= 39
            }
        }
        guard let boundary else { return [] }
        let end = plain.index(after: boundary)
        let first = String(plain[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !first.isEmpty else { return [] }
        firstPrefixCount = plain.distance(from: plain.startIndex, to: end)
        releasedFirst = true
        return [first]
    }

    private var remainingText: String {
        String(MarkdownStripper.plainText(from: text).dropFirst(firstPrefixCount))
    }

    mutating func append(_ delta: String) -> [String] {
        text += delta
        // An unfinished Markdown construct can retroactively remove text (in
        // particular a fenced code block or link URL). Wait for its closure.
        let first = releaseFirst(allowClause: false)
        guard Self.markdownIsClosed(text, includingStrong: policy == .conversational) else { return first }
        let chunks = TTSTextChunker.split(remainingText)
        let stableCount = max(0, chunks.count - 1)
        guard stableCount > emitted else { return first }
        let ready = Array(chunks[emitted..<stableCount])
        emitted = stableCount
        return first + ready
    }

    mutating func finish() -> [String] {
        let chunks = TTSTextChunker.split(remainingText)
        let ready = Array(chunks.dropFirst(emitted))
        text = ""
        emitted = 0
        firstPrefixCount = 0
        releasedFirst = false
        return ready
    }

    private static func sentenceBoundary(in text: String) -> String.Index? {
        for index in text.indices where ".!?".contains(text[index]) {
            let next = text.index(after: index)
            guard next == text.endIndex || text[next].isWhitespace else { continue }
            if text[index] == "." {
                let before = text[..<index]
                if before.last?.isNumber == true || (next < text.endIndex && text[next].isNumber) { continue }
                let word = before.split(whereSeparator: { $0.isWhitespace }).last?.lowercased() ?? ""
                if ["dr", "mr", "mrs", "ms", "prof", "e.g", "i.e", "e", "i", "vs", "etc"].contains(word) { continue }
            }
            return index
        }
        return nil
    }

    private static func firstSentenceCandidate(_ text: String) -> String {
        // Include closing emphasis/code markers before checking the raw sentence.
        for index in text.indices where ".!?".contains(text[index]) {
            var end = text.index(after: index)
            while end < text.endIndex && "*_~`".contains(text[end]) { end = text.index(after: end) }
            guard end == text.endIndex || text[end].isWhitespace else { continue }
            let candidate = String(text[..<end])
            if markdownIsClosed(candidate, includingStrong: true),
               sentenceBoundary(in: MarkdownStripper.plainText(from: candidate)) != nil { return candidate }
        }
        return text
    }

    private static func markdownIsClosed(_ text: String, includingStrong: Bool = false) -> Bool {
        for marker in ["```", "~~~", "`"] {
            if (text.components(separatedBy: marker).count - 1) % 2 != 0 { return false }
        }
        if includingStrong {
            // Recognize actual emphasis openers (next to a word), not arithmetic,
            // identifiers, stray closing markers or punctuation such as :) / <.
            let chars = Array(text)
            var open: [String] = []
            var i = 0
            while i < chars.count {
                guard "*_~".contains(chars[i]) else { i += 1; continue }
                let start = i
                while i < chars.count && chars[i] == chars[start] { i += 1 }
                let marker = String(chars[start..<i])
                let before = start > 0 ? chars[start - 1] : nil
                let after = i < chars.count ? chars[i] : nil
                if open.last == marker, before?.isWhitespace == false {
                    open.removeLast()
                } else if (before == nil || before?.isWhitespace == true),
                          after?.isLetter == true || after?.isNumber == true {
                    open.append(marker)
                }
            }
            if !open.isEmpty { return false }
        } else {
            for marker in ["*", "_", "~~"] {
                if (text.components(separatedBy: marker).count - 1) % 2 != 0 { return false }
            }
            // Preserve the legacy grouped stream's conservative markup policy.
            for (open, close) in [("[", "]"), ("(", ")"), ("<", ">")] {
                if text.filter({ String($0) == open }).count != text.filter({ String($0) == close }).count { return false }
            }
        }
        // Only real Markdown links gate parentheses. Ordinary prose punctuation
        // and comparisons must not delay the first spoken sentence.
        if let link = text.range(of: "](", options: .backwards),
           !text[link.upperBound...].contains(")") { return false }
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
/// and requests player stop, including after finish() while draining. Hardware
/// players may enqueue that stop on their audio queue rather than block the UI.
@MainActor
public final class TTSStreamHandle {
    public let id: String
    public var events: AnyPublisher<TTSStreamEvent, Never> { subject.eraseToAnyPublisher() }
    // Observation only: text of a synthesis chunk whose first buffer completed.
    // Chunks may contain multiple sentences; this does not invent word timestamps.
    var playedChunks: AnyPublisher<String, Never> { playedChunkSubject.eraseToAnyPublisher() }
    private let playedChunkSubject = PassthroughSubject<String, Never>()
    private let subject = PassthroughSubject<TTSStreamEvent, Never>()
    private let player: any TTSStreamPlayer
    private let synthesize: @MainActor (String, @escaping @MainActor ([Float]) async throws -> Void) async throws -> Void
    private let onTerminal: @MainActor () -> Void
    private var chunker: TTSIncrementalChunker
    private let releasePolicy: TTSStreamReleasePolicy
    private var firstClauseTask: Task<Void, Never>?
    private var clauseDeadlineReached = false
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
        releasePolicy: TTSStreamReleasePolicy = .grouped,
        onTerminal: @escaping @MainActor () -> Void = {}
    ) {
        self.releasePolicy = releasePolicy
        self.chunker = TTSIncrementalChunker(policy: releasePolicy)
        self.id = id
        self.player = player
        self.synthesize = synthesize
        self.onTerminal = onTerminal
        (input, continuation) = AsyncStream.makeStream(of: String.self)
    }

    isolated deinit {
        continuation.finish()
        firstClauseTask?.cancel()
        task?.cancel()
        if !terminal { player.cancelPlayback() }
    }

    public func enqueue(text: String) {
        guard !inputClosed, !terminal else { return }
        for chunk in chunker.append(text) { continuation.yield(chunk) }
        if releasePolicy == .conversational && !chunker.releasedFirst {
            if clauseDeadlineReached {
                for chunk in chunker.releaseFirst(allowClause: true) { continuation.yield(chunk) }
            } else if firstClauseTask == nil {
                firstClauseTask = Task { [weak self] in
                    do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                    guard let self, !self.terminal, !self.inputClosed else { return }
                    self.clauseDeadlineReached = true
                    for chunk in self.chunker.releaseFirst(allowClause: true) { self.continuation.yield(chunk) }
                }
            }
        }
        startIfNeeded()
    }

    public func finish() {
        guard !inputClosed, !terminal else { return }
        inputClosed = true
        firstClauseTask?.cancel()
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
        firstClauseTask?.cancel()
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
                    var firstFrame = true
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
                            let captionText = firstFrame ? chunk : nil
                            firstFrame = false
                            self.pending += 1
                            player.schedulePlayed(samples: frame) { [weak self] played in
                                Task { @MainActor in self?.bufferCompleted(played: played, captionText: captionText) }
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
                self.firstClauseTask?.cancel()
                self.continuation.finish()
                player.cancelPlayback()
                self.onTerminal()
                self.subject.send(.failed(id: self.id, message: error.localizedDescription))
                self.subject.send(completion: .finished)
            }
        }
    }

    private func bufferCompleted(played: Bool, captionText: String?) {
        guard !terminal else { return }
        guard played else {
            terminal = true
            inputClosed = true
            firstClauseTask?.cancel()
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
        if let captionText { playedChunkSubject.send(captionText) }
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
