import Foundation

// Screenshot runs (scripts/screenshots.sh) show fixed data instead of the
// live API, so every run renders the same stations and statuses. DEBUG
// builds only — in Release every check is a constant false.
//
// Switched on per launch with `-HissiDemoData YES` (the argument domain of
// the standard defaults, never persisted). The app mirrors it into the App
// Group so the widget extension, which gets no launch arguments, follows;
// a launch without the argument clears the mirror again.
nonisolated enum DemoMode {
    static let argument = "HissiDemoData"
    // Additionally replaces the favorites with DemoFixtures.favorites.
    static let favoritesArgument = "HissiDemoFavorites"
    // `-HissiDemoOpen nearby`: starts on an AppDeepLink's screen. The scheme
    // is not registered (AppDeepLink), so a test can't open the URL itself.
    static let openArgument = "HissiDemoOpen"

    #if DEBUG
    private static let groupFlagKey = "demoData"

    private static var group: UserDefaults? {
        UserDefaults(suiteName: ElevatorCache.appGroupID)
    }

    static var isActive: Bool {
        UserDefaults.standard.bool(forKey: argument) || group?.bool(forKey: groupFlagKey) == true
    }

    static var seedsFavorites: Bool {
        UserDefaults.standard.bool(forKey: favoritesArgument)
    }

    static var launchLink: AppDeepLink? {
        UserDefaults.standard.string(forKey: openArgument)
            .flatMap { URL(string: "hissi://\($0)") }
            .flatMap(AppDeepLink.init)
    }

    // App launch only: carries the launch argument over to the extensions.
    static func adoptLaunchArguments() {
        group?.set(UserDefaults.standard.bool(forKey: argument), forKey: groupFlagKey)
    }
    #else
    static let isActive = false
    static let seedsFavorites = false
    static let launchLink: AppDeepLink? = nil
    static func adoptLaunchArguments() {}
    #endif
}
