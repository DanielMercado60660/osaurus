import Foundation

public struct TalkModeConfiguration: Codable, Equatable, Sendable {
    public var enabledAgentIds: [UUID] = []
    public var endOfTurnSilenceMs: Int = 700
    public var bargeInEnabled: Bool = true
    public var bargeInMinSpeechMs: Int = 160
    public var echoCancellationEnabled: Bool = true
    public var showCaptions: Bool = true

    public init() {}
    public static let `default` = TalkModeConfiguration()

    private enum CodingKeys: String, CodingKey {
        case enabledAgentIds, endOfTurnSilenceMs, bargeInEnabled, bargeInMinSpeechMs
        case echoCancellationEnabled, showCaptions
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabledAgentIds = try c.decodeIfPresent([UUID].self, forKey: .enabledAgentIds) ?? []
        endOfTurnSilenceMs = min(3000, max(300, try c.decodeIfPresent(Int.self, forKey: .endOfTurnSilenceMs) ?? 700))
        bargeInEnabled = try c.decodeIfPresent(Bool.self, forKey: .bargeInEnabled) ?? true
        bargeInMinSpeechMs = min(1000, max(100, try c.decodeIfPresent(Int.self, forKey: .bargeInMinSpeechMs) ?? 160))
        echoCancellationEnabled = try c.decodeIfPresent(Bool.self, forKey: .echoCancellationEnabled) ?? true
        showCaptions = try c.decodeIfPresent(Bool.self, forKey: .showCaptions) ?? true
    }
}
