import Foundation

// Decides which onboarding sheet a launch shows: the full welcome once per
// install, afterwards a slim "Was ist neu" only for releases with curated
// notes — bugfix releases stay silent. Pure; the iOS app feeds it the
// persisted state and the running version (OnboardingState), tests cover the
// matrix. Existing installs that predate the welcome see it once on their
// next update, which doubles as that release's what's-new.
nonisolated enum WelcomeGate {
    enum Sheet: Equatable {
        case welcome
        case whatsNew(version: String)
    }

    // Releases with curated notes; the note content lives with the UI
    // (WhatsNewSheet), where the literals double as localization keys.
    static let curatedVersions: Set<String> = []

    static func sheet(
        hasSeenWelcome: Bool,
        shownWhatsNewVersion: String?,
        currentVersion: String,
        curatedVersions: Set<String> = curatedVersions
    ) -> Sheet? {
        guard hasSeenWelcome else { return .welcome }
        guard curatedVersions.contains(currentVersion),
              shownWhatsNewVersion != currentVersion
        else { return nil }
        return .whatsNew(version: currentVersion)
    }
}
