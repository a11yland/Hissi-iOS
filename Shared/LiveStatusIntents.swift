// Mac Catalyst has no ActivityKit either (the SDK marks it unavailable).
#if os(iOS) && !targetEnvironment(macCatalyst) && canImport(ActivityKit)
import ActivityKit
import AppIntents
import Foundation

// The "Beenden" button on the Live Activity. Without it the live status could
// only be stopped by opening the app — on the Lock Screen, where the activity
// actually lives, that is a detour.
//
// Unlike the App Shortcut intents (Hissi/Intents/, app target only) this one
// has to exist in *both* binaries: the widget extension references the type to
// build the button, the app is where it runs. Shared/ is the only place that
// compiles into both, hence its location — LiveActivityIntent guarantees the
// perform() itself happens in the app process.
//
// Not discoverable: it is a button on a running activity, not something anyone
// would assemble a Shortcut from.
nonisolated struct EndLiveStatusIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Live-Status beenden"
    static let description = IntentDescription("Beendet den laufenden Live-Status.")
    static let isDiscoverable = false

    init() {}

    func perform() async throws -> some IntentResult {
        // Ended here rather than through LiveActivityController: the intent can
        // run before the app's UI exists. The controller observes the activity's
        // state and clears itself when this lands.
        for activity in Activity<LiveStatusAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        LiveStatusFlag.isRunning = false
        return .result()
    }
}
#endif
