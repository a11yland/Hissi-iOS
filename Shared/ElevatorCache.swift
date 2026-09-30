import Foundation

enum ElevatorCache {
    // nonisolated: also read by LiveStatusFlag from outside the main actor.
    nonisolated static let appGroupID = "group.com.a11yland.Hissi"
    private static let key = "cachedMonitoredElevators"
    private static let hasStoredKey = "cachedMonitoredElevatorsStored"

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: appGroupID) ?? .standard
    }

    // Whether anything was ever written — on the watch this is what separates
    // "no favorites synced yet" (membership unknown) from an actually empty
    // favorites list.
    static var hasStoredOnce: Bool {
        defaults.bool(forKey: hasStoredKey)
    }

    static func load() -> [MonitoredElevator] {
        guard
            let data = defaults.data(forKey: key),
            let cached = try? JSONDecoder().decode([MonitoredElevator].self, from: data)
        else { return [] }
        return cached
    }

    static func save(_ elevators: [MonitoredElevator]) {
        guard let data = try? JSONEncoder().encode(elevators) else { return }
        defaults.set(data, forKey: key)
        defaults.set(true, forKey: hasStoredKey)
    }
}
