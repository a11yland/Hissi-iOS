import Foundation

// Feature toggles for work that lands on main before it is released
// (trunk-based development). A toggle is a constant in Release; DEBUG builds
// can switch it on with a launch argument, which the app mirrors into the
// App Group so the widget extension follows (the DemoMode pattern).
nonisolated enum FeatureToggle {
    // `-HissiVRR YES`: the VRR elevators (second data source, NRW).
    static let vrrArgument = "HissiVRR"

    #if DEBUG
    private static let vrrGroupKey = "featureVRR"

    private static var group: UserDefaults? {
        UserDefaults(suiteName: ElevatorCache.appGroupID)
    }

    static var vrr: Bool {
        UserDefaults.standard.bool(forKey: vrrArgument) || group?.bool(forKey: vrrGroupKey) == true
    }

    // App launch only: carries the launch argument over to the extensions.
    static func adoptLaunchArguments() {
        group?.set(UserDefaults.standard.bool(forKey: vrrArgument), forKey: vrrGroupKey)
    }
    #else
    static let vrr = false
    static func adoptLaunchArguments() {}
    #endif

    // Whether an elevator of this id is part of the app right now. The one
    // choke point is the seed (SeedCatalog.records): a source that is
    // switched off never reaches search, nearby, widgets or the watch.
    static func includes(_ id: String, vrr: Bool = FeatureToggle.vrr) -> Bool {
        ElevatorSource(id: id) != .vrr || vrr
    }
}
