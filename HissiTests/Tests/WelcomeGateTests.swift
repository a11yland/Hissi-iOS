import Testing
@testable import HissiCore

// Welcome once per install; afterwards "Was ist neu" only for releases with
// curated notes, once per version.
@Suite struct WelcomeGateTests {
    @Test func freshInstallGetsTheWelcome() {
        let sheet = WelcomeGate.sheet(
            hasSeenWelcome: false,
            shownWhatsNewVersion: nil,
            currentVersion: "3.0",
            curatedVersions: ["3.0"]
        )
        #expect(sheet == .welcome)
    }

    // Existing installs from before the welcome existed also see it once —
    // it doubles as that release's what's-new.
    @Test func welcomeWinsEvenWhenNotesExist() {
        let sheet = WelcomeGate.sheet(
            hasSeenWelcome: false,
            shownWhatsNewVersion: "2.1",
            currentVersion: "3.0",
            curatedVersions: ["3.0"]
        )
        #expect(sheet == .welcome)
    }

    @Test func curatedUpdateShowsWhatsNewOnce() {
        let first = WelcomeGate.sheet(
            hasSeenWelcome: true,
            shownWhatsNewVersion: "2.1",
            currentVersion: "3.0",
            curatedVersions: ["3.0"]
        )
        #expect(first == .whatsNew(version: "3.0"))

        let again = WelcomeGate.sheet(
            hasSeenWelcome: true,
            shownWhatsNewVersion: "3.0",
            currentVersion: "3.0",
            curatedVersions: ["3.0"]
        )
        #expect(again == nil)
    }

    // Bugfix releases without curated notes stay silent.
    @Test func uncuratedVersionsShowNothing() {
        let sheet = WelcomeGate.sheet(
            hasSeenWelcome: true,
            shownWhatsNewVersion: "3.0",
            currentVersion: "3.0.1",
            curatedVersions: ["3.0"]
        )
        #expect(sheet == nil)
    }
}
