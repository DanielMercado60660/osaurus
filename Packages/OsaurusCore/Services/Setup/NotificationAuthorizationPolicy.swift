/// Authorization is attempted at most once per process, and only after the
/// current onboarding flow has closed. Existing completed users ask at launch.
enum NotificationAuthorizationPolicy {
    static func shouldRequest(onboardingRequired: Bool, alreadyRequested: Bool) -> Bool {
        !onboardingRequired && !alreadyRequested
    }
}
