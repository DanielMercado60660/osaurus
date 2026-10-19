import Foundation

public struct TalkModeConfiguration: Codable, Equatable, Sendable {
    public var enabledAgentIds: [UUID] = []
    public var endOfTurnSilenceMs: Int = 700
    public var bargeInEnabled: Bool = true
    public var bargeInMinSpeechMs: Int = 160
    public var echoCancellationEnabled: Bool = true
    public var showCaptions: Bool = true
    public var thinkBeforeSpeaking: Bool = false

    public init() {}
    public static let `default` = TalkModeConfiguration()

    private enum CodingKeys: String, CodingKey {
        case enabledAgentIds, endOfTurnSilenceMs, bargeInEnabled, bargeInMinSpeechMs
        case echoCancellationEnabled, showCaptions, thinkBeforeSpeaking
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabledAgentIds = try c.decodeIfPresent([UUID].self, forKey: .enabledAgentIds) ?? []
        endOfTurnSilenceMs = min(3000, max(300, try c.decodeIfPresent(Int.self, forKey: .endOfTurnSilenceMs) ?? 700))
        bargeInEnabled = try c.decodeIfPresent(Bool.self, forKey: .bargeInEnabled) ?? true
        bargeInMinSpeechMs = min(1000, max(100, try c.decodeIfPresent(Int.self, forKey: .bargeInMinSpeechMs) ?? 160))
        echoCancellationEnabled = try c.decodeIfPresent(Bool.self, forKey: .echoCancellationEnabled) ?? true
        thinkBeforeSpeaking = try c.decodeIfPresent(Bool.self, forKey: .thinkBeforeSpeaking) ?? false
        showCaptions = try c.decodeIfPresent(Bool.self, forKey: .showCaptions) ?? true
    }
}

/// Talk-only explicit choice. Unknown capabilities preserve the bundle contract.
enum TalkThinkingPolicy {
    static func enableThinking(thinkBeforeSpeaking: Bool, toggleable: Bool) -> Bool? {
        !thinkBeforeSpeaking && toggleable ? false : nil
    }
    static func caption(supportsThinking: Bool?, toggleable: Bool) -> String {
        guard let supportsThinking else { return "The model's reasoning capability is not available. Its default is preserved." }
        if toggleable { return "Off skips thinking when the model supports it. On uses the model's default. Applies to the next spoken turn; chat Thinking is unchanged." }
        return supportsThinking ? "This model always reasons" : "This model doesn't reason"
    }
}
