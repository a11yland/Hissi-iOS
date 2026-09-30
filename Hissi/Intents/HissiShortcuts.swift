import AppIntents

// The presets: shortcuts that show up in the Shortcuts app, Spotlight and Siri
// on their own, without the user assembling anything. Exactly one
// AppShortcutsProvider per app, and the declaration order is the order they are
// listed — status first, since that is the question the app exists to answer.
//
// Every phrase must contain \(.applicationName); those phrases are extracted
// into a *separate* string catalog (Hissi/AppShortcuts.xcstrings, recognized
// by its file name), not into Shared/Localizable.xcstrings, which keeps holding
// the titles and dialogs.
nonisolated struct HissiShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CheckElevatorsIntent(),
            phrases: [
                "Aufzugstatus in \(.applicationName) prüfen",
                "Sind meine Aufzüge in \(.applicationName) in Betrieb?",
            ],
            shortTitle: "Aufzugstatus",
            systemImageName: "arrow.up.arrow.down.circle"
        )
        AppShortcut(
            intent: CheckElevatorIntent(),
            phrases: [
                "\(\.$elevator) in \(.applicationName) prüfen",
            ],
            shortTitle: "Aufzug prüfen",
            systemImageName: "arrow.up.arrow.down"
        )
        AppShortcut(
            intent: OpenFavoritesIntent(),
            phrases: [
                "Favoriten in \(.applicationName) öffnen",
            ],
            shortTitle: "Favoriten",
            systemImageName: "star"
        )
    }
}
