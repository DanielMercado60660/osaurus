import Foundation

/// Talk-only acoustic policy. Values live here so fixtures and the capture path
/// use the same contract; these are not model generation or parser settings.
struct TalkEchoPolicy: Sendable {
    var listeningThreshold: Float = 0.5
    var aecPlaybackThreshold: Float = 0.65
    var fallbackPlaybackThreshold: Float = 0.75
    var cooldownSeconds: Double = 0.250
    var aecBargeInSeconds: Double = 0.250
    var fallbackBargeInSeconds: Double = 0.300
    var floorMultiplier: Float = 2.5
    var floorEMAAlpha: Float = 0.2
    var floorDecaySeconds: Double = 0.3
    var transcriptWindowSeconds: Double = 10
    var transcriptOverlap: Double = 0.6

    func threshold(aec: Bool, protected: Bool) -> Float {
        protected ? (aec ? aecPlaybackThreshold : fallbackPlaybackThreshold) : listeningThreshold
    }
    func bargeInSeconds(aec: Bool, configuredMs: Int) -> Double {
        max(Double(configuredMs) / 1000, aec ? aecBargeInSeconds : fallbackBargeInSeconds)
    }
}

/// RMS uses linear, unscaled PCM on both sides, never the UI's compressed meter.
/// Learn the acoustic coupling only on low-VAD frames. The concurrent render
/// reference predicts a louder echo floor without assuming equal mic/speaker gain.
struct TalkEchoFloor: Sendable {
    private(set) var echoFloor: Float = 0
    private var coupling: Float?
    private var lastTime: TimeInterval?
    mutating func reset() { self = Self() }
    mutating func detects(probability: Float, micRMS: Float, outputRMS: Float,
                          playback: Bool, threshold: Float, at time: TimeInterval,
                          policy: TalkEchoPolicy) -> Bool {
        let elapsed = max(0, time - (lastTime ?? time))
        lastTime = time
        guard probability.isFinite, micRMS.isFinite, micRMS >= 0 else { return false }
        if !playback {
            echoFloor *= Float(exp(-elapsed / policy.floorDecaySeconds))
            return probability >= threshold
        }
        if probability < threshold {
            echoFloor = echoFloor == 0 ? micRMS : echoFloor + policy.floorEMAAlpha * (micRMS - echoFloor)
            if outputRMS.isFinite && outputRMS > 0 {
                let ratio = micRMS / outputRMS
                coupling = coupling.map { $0 + policy.floorEMAAlpha * (ratio - $0) } ?? ratio
            }
            return false
        }
        let predicted = outputRMS.isFinite ? (coupling ?? 0) * max(0, outputRMS) : 0
        return micRMS >= max(echoFloor, predicted) * policy.floorMultiplier
    }
}

struct TalkEchoTranscripts: Equatable, Sendable {
    struct Sentence: Equatable, Sendable { let text: String; let at: TimeInterval }
    private(set) var sentences: [Sentence] = []
    static func normalize(_ text: String) -> String {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: " ")
    }
    mutating func record(_ text: String, at time: TimeInterval, policy: TalkEchoPolicy) {
        sentences.removeAll { time - $0.at > policy.transcriptWindowSeconds }
        // Released chunks can contain several sentences. Match each independently.
        var recorded: [Sentence] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .bySentences) { part, _, _, _ in
            let normalized = Self.normalize(part ?? "")
            if !normalized.isEmpty { recorded.append(.init(text: normalized, at: time)) }
        }
        sentences.append(contentsOf: recorded)
    }
    func isEcho(_ text: String, at time: TimeInterval, policy: TalkEchoPolicy) -> Bool {
        let normalized = Self.normalize(text)
        guard !normalized.isEmpty else { return false }
        let tokens = Set(normalized.split(separator: " "))
        return sentences.contains { sentence in
            guard time >= sentence.at, time - sentence.at <= policy.transcriptWindowSeconds else { return false }
            // Token-bounded substring avoids matching "he" inside "the".
            if (" " + sentence.text + " ").contains(" " + normalized + " ") { return true }
            let reference = Set(sentence.text.split(separator: " "))
            return Double(tokens.intersection(reference).count) / Double(tokens.count) >= policy.transcriptOverlap
        }
    }
}
