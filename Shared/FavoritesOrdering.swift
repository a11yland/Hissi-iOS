import Foundation

// How the favorites list is ordered. The stored order *is* the displayed
// order — every mirror (widget, watch, complications, Shortcuts) reads the
// favorites array as it stands, so ordering is applied once when writing and
// nowhere else. The mode only decides what happens on the next write:
// `.recentlyAdded` re-derives the order from `addedAt`, `.manual` leaves the
// order the user dragged into place alone.
nonisolated enum FavoritesOrder: String, CaseIterable, Sendable {
    // Default: newest favorite first.
    case recentlyAdded
    // Set implicitly the moment the user drags a row — nobody has to pick it
    // first, and a manual order that a re-sort would silently undo is not
    // worth persisting. Named after Fotos' "Eigene Reihenfolge": it labels
    // the state the list is in, not an action to take.
    case manual

    static let `default` = FavoritesOrder.recentlyAdded

    var label: String {
        switch self {
        case .recentlyAdded: String(localized: "Zuletzt hinzugefügt")
        case .manual:        String(localized: "Eigene Reihenfolge")
        }
    }
}

// Pure ordering rules, platform-free and unit-tested. Persistence and the
// UI live elsewhere (FavoritesStore, ContentView).
nonisolated enum FavoritesOrdering {
    // Newest first. Stable: equal (or missing) timestamps keep their relative
    // position, and favorites without one — stored before the timestamp
    // existed — sort after the timestamped ones rather than jumping to the top.
    static func byRecentlyAdded(_ favorites: [MonitoredElevator]) -> [MonitoredElevator] {
        favorites.enumerated()
            .sorted { lhs, rhs in
                switch (lhs.element.addedAt, rhs.element.addedAt) {
                case let (left?, right?): return left == right ? lhs.offset < rhs.offset : left > right
                case (nil, _?):           return false
                case (_?, nil):           return true
                case (nil, nil):          return lhs.offset < rhs.offset
                }
            }
            .map(\.element)
    }

    // Applies `order` to a favorites list. `.manual` is the identity — the
    // stored order already is the user's order.
    static func apply(_ order: FavoritesOrder, to favorites: [MonitoredElevator]) -> [MonitoredElevator] {
        switch order {
        case .recentlyAdded: byRecentlyAdded(favorites)
        case .manual:        favorites
        }
    }

    // A new favorite goes to the top in both modes: it is the most recent one,
    // and in a manually sorted list a fresh entry is easier to move from a
    // visible position than to find at the bottom.
    static func inserting(
        _ elevator: MonitoredElevator,
        into favorites: [MonitoredElevator],
        at date: Date
    ) -> [MonitoredElevator] {
        guard !favorites.contains(where: { $0.id == elevator.id }) else { return favorites }
        var stamped = elevator
        stamped.addedAt = elevator.addedAt ?? date
        return [stamped] + favorites
    }

    // SwiftUI's `onMove` contract (IndexSet of source rows + an insertion
    // offset into the *original* list), spelled out here rather than via
    // SwiftUI's `move(fromOffsets:toOffset:)` — this file must stay
    // Foundation-only so the watch targets and the test package build it.
    static func moved(_ favorites: [MonitoredElevator], from source: IndexSet, to destination: Int) -> [MonitoredElevator] {
        let moving = source.compactMap { favorites.indices.contains($0) ? favorites[$0] : nil }
        guard !moving.isEmpty else { return favorites }
        var remaining = favorites
        for index in source.sorted(by: >) where remaining.indices.contains(index) {
            remaining.remove(at: index)
        }
        let insertion = destination - source.filter { $0 < destination }.count
        remaining.insert(contentsOf: moving, at: min(max(insertion, 0), remaining.count))
        return remaining
    }

    // One-time backfill for favorites stored before `addedAt` existed: their
    // array order was the order they were added in (appended), so the first
    // entry is the oldest. Timestamps are spaced a second apart ending just
    // before `now`, which makes the existing order sortable without claiming
    // a precision it doesn't have. Timestamped entries are left untouched.
    static func backfillingAddedAt(_ favorites: [MonitoredElevator], now: Date) -> [MonitoredElevator] {
        let missing = favorites.filter { $0.addedAt == nil }.count
        guard missing > 0 else { return favorites }
        var remaining = missing
        return favorites.map { favorite in
            guard favorite.addedAt == nil else { return favorite }
            var stamped = favorite
            stamped.addedAt = now.addingTimeInterval(-Double(remaining))
            remaining -= 1
            return stamped
        }
    }
}
