import Foundation

public struct TalkModeConfiguration: Codable, Equatable, Sendable {
    public var enabledAgentIds: [UUID] = []
    private var silenceOverrideMs: Int?
    public var endOfTurnSilenceMs: Int {
        get { silenceOverrideMs ?? 700 }
        set { silenceOverrideMs = min(3000, max(300, newValue)) }
    }
    /// A saved choice wins over availability; without a model this preference
    /// is inert. No download or model load is triggered by decoding settings.
    public var smartTurnEnabled: Bool = true
    public var smartTurnCheckSilenceMs: Int = 250
    public func effectiveEndSilenceMs(smartTurnActive: Bool) -> Int {
        silenceOverrideMs ?? (smartTurnActive ? 900 : 700)
    }
    public var bargeInEnabled: Bool = true
    public var bargeInMinSpeechMs: Int = 160
    public var echoCancellationEnabled: Bool = true
    public var showCaptions: Bool = true
    public var thinkBeforeSpeaking: Bool = false

    func requiresCaptureRestart(comparedTo previous: Self) -> Bool {
        silenceOverrideMs != previous.silenceOverrideMs
            || smartTurnEnabled != previous.smartTurnEnabled
            || smartTurnCheckSilenceMs != previous.smartTurnCheckSilenceMs
            || echoCancellationEnabled != previous.echoCancellationEnabled
    }

    public init() {}
    public static let `default` = TalkModeConfiguration()

    private enum CodingKeys: String, CodingKey {
        case enabledAgentIds, endOfTurnSilenceMs, bargeInEnabled, bargeInMinSpeechMs
        case echoCancellationEnabled, showCaptions, thinkBeforeSpeaking, smartTurnEnabled, smartTurnCheckSilenceMs
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabledAgentIds, forKey: .enabledAgentIds)
        try c.encodeIfPresent(silenceOverrideMs, forKey: .endOfTurnSilenceMs)
        try c.encode(smartTurnEnabled, forKey: .smartTurnEnabled)
        try c.encode(smartTurnCheckSilenceMs, forKey: .smartTurnCheckSilenceMs)
        try c.encode(bargeInEnabled, forKey: .bargeInEnabled)
        try c.encode(bargeInMinSpeechMs, forKey: .bargeInMinSpeechMs)
        try c.encode(echoCancellationEnabled, forKey: .echoCancellationEnabled)
        try c.encode(showCaptions, forKey: .showCaptions)
        try c.encode(thinkBeforeSpeaking, forKey: .thinkBeforeSpeaking)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabledAgentIds = try c.decodeIfPresent([UUID].self, forKey: .enabledAgentIds) ?? []
        silenceOverrideMs = try c.decodeIfPresent(Int.self, forKey: .endOfTurnSilenceMs).map { min(3000, max(300, $0)) }
        smartTurnEnabled = try c.decodeIfPresent(Bool.self, forKey: .smartTurnEnabled) ?? true
        smartTurnCheckSilenceMs = min(1000, max(100, try c.decodeIfPresent(Int.self, forKey: .smartTurnCheckSilenceMs) ?? 250))
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
