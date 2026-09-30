import Foundation

// User-selected elevators to monitor, persisted to the App Group so the widget
// and watch read the same set. Starts empty — users add elevators via search.
// Pure persistence: reloading widget timelines after a change is the caller's
// job (ElevatorMonitorService), not a hidden side effect of saving.
enum FavoritesStore {
    private static let key = "favoriteElevators"
    private static let migrationKey = "favoritesMigratedToAccessibilityCloud"

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: ElevatorCache.appGroupID) ?? .standard
    }

    private static let transitCleanupKey = "favoritesCleanedForTransitAPI"
    private static let removalNoticeKey = "legacyFavoritesRemovalNoticePending"
    private static let orderKey = "favoritesOrder"
    private static let addedAtBackfillKey = "favoritesAddedAtBackfilled"

    // One-time cleanup on upgrade: earlier favorites were keyed by
    // "{stationId}-{elevatorId}", which no longer resolves against the
    // accessibility.cloud _id. Clear them once so no unresolvable "unknown"
    // entries linger; users re-add via search. Idempotent via a flag.
    static func migrateIfNeeded() {
        guard !defaults.bool(forKey: migrationKey) else { return }
        defaults.set(true, forKey: migrationKey)
        if !load().isEmpty { persist([]) }
    }

    // One-time cleanup on the transit.accessibility.cloud migration:
    // favorites created under the old id schemes (Mongo _id, "fasta-…",
    // "brokenlifts-…") don't exist in the new API — its ids are numeric.
    // Deliberately deleted instead of mapped; the app shows a one-time
    // notice (removalNoticePending) so users know to re-add via search.
    static func removeLegacyFavoritesIfNeeded() {
        guard !defaults.bool(forKey: transitCleanupKey) else { return }
        defaults.set(true, forKey: transitCleanupKey)
        let current = load()
        let kept = current.filter { Int($0.id) != nil }
        guard kept.count != current.count else { return }
        persist(kept)
        defaults.set(true, forKey: removalNoticeKey)
    }

    static var removalNoticePending: Bool {
        defaults.bool(forKey: removalNoticeKey)
    }

    static func dismissRemovalNotice() {
        defaults.removeObject(forKey: removalNoticeKey)
    }

    // MARK: - Order

    // How the list is sorted. The stored array is always in the order the
    // user sees, so readers (widget, watch, Shortcuts) need none of this —
    // only writers do.
    static var order: FavoritesOrder {
        defaults.string(forKey: orderKey).flatMap(FavoritesOrder.init(rawValue:)) ?? .default
    }

    // Switching the mode re-sorts what is stored, so every mirror picks the
    // new order up with the next sync instead of at its next full refresh.
    static func setOrder(_ order: FavoritesOrder) {
        defaults.set(order.rawValue, forKey: orderKey)
        persist(FavoritesOrdering.apply(order, to: load()))
    }

    // The user dragged rows into place: store that order verbatim and stop
    // re-deriving it, otherwise the next write would undo the drag.
    static func setManualOrder(_ elevators: [MonitoredElevator]) {
        defaults.set(FavoritesOrder.manual.rawValue, forKey: orderKey)
        persist(elevators)
    }

    // One-time upgrade step: favorites stored before `addedAt` existed get a
    // timestamp derived from their array order (they were appended, so the
    // first entry is the oldest), and the list is then put into the default
    // "zuletzt hinzugefügt" order — which reverses an existing list once.
    // Idempotent via a flag; a user who has since sorted manually keeps their
    // order, because setOrder/.manual is what apply() honours.
    static func backfillAddedAtIfNeeded(now: Date = Date()) {
        guard !defaults.bool(forKey: addedAtBackfillKey) else { return }
        defaults.set(true, forKey: addedAtBackfillKey)
        let current = load()
        guard !current.isEmpty else { return }
        let stamped = FavoritesOrdering.backfillingAddedAt(current, now: now)
        persist(FavoritesOrdering.apply(order, to: stamped))
    }

    // MARK: - Contents

    static func load() -> [MonitoredElevator] {
        guard
            let data = defaults.data(forKey: key),
            let stored = try? JSONDecoder().decode([MonitoredElevator].self, from: data)
        else { return [] }
        return stored
    }

    static func configs() -> [(stationId: String, elevatorId: String)] {
        load().map { ($0.stationId, $0.elevatorId) }
    }

    static func isFavorite(_ id: String) -> Bool {
        load().contains { $0.id == id }
    }

    // Newest first: a new favorite goes to the top of the list in both
    // modes (FavoritesOrdering.inserting), stamped with the time it was added.
    static func add(_ elevator: MonitoredElevator, now: Date = Date()) {
        let current = load()
        let updated = FavoritesOrdering.inserting(elevator, into: current, at: now)
        guard updated.count != current.count else { return }
        persist(updated)
    }

    static func remove(_ id: String) {
        persist(load().filter { $0.id != id })
    }

    // Rewrites favorites whose identity changed — a seed-id favorite resolved
    // to its live record through the inventory-number bridge adopts the live
    // (numeric) id on refresh. Only the listed favorites are touched, so a
    // toggle that raced the refresh survives. Deduplicated: the same elevator
    // favorited once via its seed id and once via its live id collapses into
    // one entry when the migration unifies the ids.
    static func migrateIds(_ replacements: [String: MonitoredElevator]) {
        guard !replacements.isEmpty else { return }
        var seen = Set<String>()
        persist(load().map { replacements[$0.id] ?? $0 }.filter { seen.insert($0.id).inserted })
    }

    // Replaces list and mode wholesale — the iCloud copy arriving
    // (FavoritesCloudSync). The list is stored as given: the merge already
    // put it into the order it should be displayed in.
    static func replace(with elevators: [MonitoredElevator], order: FavoritesOrder) {
        defaults.set(order.rawValue, forKey: orderKey)
        persist(elevators)
    }

    private static func persist(_ elevators: [MonitoredElevator]) {
        guard let data = try? JSONEncoder().encode(elevators) else { return }
        defaults.set(data, forKey: key)
    }
}
