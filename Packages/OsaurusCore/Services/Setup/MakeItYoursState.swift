import Foundation

/// Projection of real prerequisites, never a separate set of completion flags.
struct MakeItYoursState: Equatable {
    enum Row: Equatable {
        case pending
        /// nil means a manager cannot report measurable progress.
        case inProgress(Double?)
        case done
        case failed(String)
    }

    var onboardingComplete: Bool
    var dismissed: Bool
    var speech: Row
    var voice: Row
    var microphoneGranted: Bool
    var agentEnabled: Bool
    var requestingMicrophone = false
    var setupError: String?
    var companionEnabled: Bool
    var phone: Row

    var talk: Row {
        if let setupError { return .failed(setupError) }
        if requestingMicrophone { return .inProgress(nil) }
        for row in [speech, voice] {
            if case .failed(let error) = row { return .failed(error) }
        }
        if speech == .done && voice == .done && microphoneGranted && agentEnabled { return .done }
        if case .inProgress = speech { return .inProgress(combinedDownloadProgress) }
        if case .inProgress = voice { return .inProgress(combinedDownloadProgress) }
        return .pending
    }

    /// Equal-weight model preparation, not an invented byte percentage.
    var combinedDownloadProgress: Double? {
        func fraction(_ row: Row) -> Double? {
            switch row {
            case .done: return 1
            case .inProgress(let value):
                guard let value, value.isFinite else { return nil }
                return min(1, max(0, value))
            case .pending, .failed: return 0
            }
        }
        guard let a = fraction(speech), let b = fraction(voice) else { return nil }
        return (a + b) / 2
    }

    var companion: Row { companionEnabled ? .done : .pending }
    var isVisible: Bool {
        onboardingComplete && !dismissed && !(talk == .done && companion == .done && phone == .done)
    }
}

/// AppStorage and tests share the same persistent dismissal key.
enum MakeItYoursPreference {
    static let dismissedKey = "makeItYoursDismissed"
    static func isDismissed(in defaults: UserDefaults) -> Bool { defaults.bool(forKey: dismissedKey) }
    static func setDismissed(_ value: Bool, in defaults: UserDefaults) {
        defaults.set(value, forKey: dismissedKey)
    }
}
