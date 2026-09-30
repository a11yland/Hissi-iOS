import Foundation

// What the favorites look like in iCloud's key-value store: membership, the
// stored (= displayed) order and the sort mode. Statuses are stripped — they
// are stale by the time another device or a reinstall reads them, and the
// next refresh fetches them anyway; it also keeps a status-only refresh from
// rewriting the cloud copy every 30 minutes.
nonisolated struct FavoritesCloudSnapshot: Codable, Equatable {
    var favorites: [MonitoredElevator]
    // FavoritesOrder raw value; an unknown one (a newer app version) falls
    // back to the default instead of failing the whole snapshot.
    var order: String

    init(favorites: [MonitoredElevator], order: FavoritesOrder) {
        self.favorites = favorites.map(\.withoutStatus)
        self.order = order.rawValue
    }

    var favoritesOrder: FavoritesOrder {
        FavoritesOrder(rawValue: order) ?? .default
    }

    func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }

    static func decoded(from data: Data) -> FavoritesCloudSnapshot? {
        try? JSONDecoder().decode(FavoritesCloudSnapshot.self, from: data)
    }
}

nonisolated extension MonitoredElevator {
    // The favorite without its status — what leaves the device (iCloud copy,
    // export file): membership and placement, never a status that is stale
    // by the time anyone reads it.
    var withoutStatus: MonitoredElevator {
        var identity = self
        identity.isWorking = nil
        identity.lastChecked = nil
        identity.lastUpdated = nil
        identity.stateExplanation = nil
        return identity
    }
}

// Pure merge rules between the local favorites and the iCloud copy —
// Foundation only, unit-tested. The plumbing (NSUbiquitousKeyValueStore,
// notifications) lives in the app target (FavoritesCloudSync).
nonisolated enum FavoritesCloudMerge {
    // How a cloud copy meets the local list.
    enum Mode {
        // This installation has never synced (fresh install, first launch
        // with sync, iCloud account switch): nothing may get lost, so both
        // sides are united. A reinstall has an empty local list, so this is
        // simply "take the cloud copy".
        case union
        // An already-synced installation hears from another device: the
        // cloud copy is that device's latest word — removals included — and
        // replaces the local list. Last writer wins; uniting here would bring
        // back every favorite removed elsewhere.
        case adopt
    }

    static func merged(
        local: [MonitoredElevator],
        localOrder: FavoritesOrder,
        cloud: FavoritesCloudSnapshot,
        mode: Mode
    ) -> (favorites: [MonitoredElevator], order: FavoritesOrder) {
        // Known elevators keep their local status, so adopting a list doesn't
        // flash every row to "unknown" until the next refresh.
        let fromCloud = cloud.favorites.map { remote -> MonitoredElevator in
            guard let known = local.first(where: { $0.id == remote.id }) else { return remote }
            var merged = remote
            merged.isWorking = known.isWorking
            merged.lastChecked = known.lastChecked
            merged.lastUpdated = known.lastUpdated
            merged.stateExplanation = known.stateExplanation
            return merged
        }
        switch mode {
        case .adopt:
            return (deduplicated(fromCloud), cloud.favoritesOrder)
        case .union:
            // An empty side has no say in the order mode.
            let order = cloud.favorites.isEmpty ? localOrder : cloud.favoritesOrder
            let cloudIds = Set(cloud.favorites.map(\.id))
            // Local-only favorites go on top, like any new favorite
            // (FavoritesOrdering.inserting); the default order re-sorts by
            // addedAt anyway.
            let localOnly = local.filter { !cloudIds.contains($0.id) }
            return (FavoritesOrdering.apply(order, to: deduplicated(localOnly + fromCloud)), order)
        }
    }

    private static func deduplicated(_ favorites: [MonitoredElevator]) -> [MonitoredElevator] {
        var seen = Set<String>()
        return favorites.filter { seen.insert($0.id).inserted }
    }
}
