import Foundation

// Persistence side of WelcomeGate (iOS app only — the sheets exist nowhere
// else). Standard defaults, not the App Group: widget/watch don't care.
@MainActor
enum OnboardingState {
    private static let welcomeKey = "hasSeenWelcome"
    private static let whatsNewKey = "whatsNewShownForVersion"

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    static func pendingSheet() -> WelcomeGate.Sheet? {
        WelcomeGate.sheet(
            hasSeenWelcome: UserDefaults.standard.bool(forKey: welcomeKey),
            shownWhatsNewVersion: UserDefaults.standard.string(forKey: whatsNewKey),
            currentVersion: currentVersion
        )
    }

    // The welcome also stamps the current version: it already presents the
    // app as of today, a "Was ist neu" right after would be noise.
    static func markWelcomeSeen() {
        UserDefaults.standard.set(true, forKey: welcomeKey)
        UserDefaults.standard.set(currentVersion, forKey: whatsNewKey)
    }

    static func markWhatsNewSeen(_ version: String) {
        UserDefaults.standard.set(version, forKey: whatsNewKey)
    }
}
