import AppIntents
import Foundation
import Combine

@MainActor
class ElevatorMonitorService: ObservableObject {
    @Published var elevators: [MonitoredElevator]
    @Published var isLoading = false
    @Published var errorMessage: String?
    // Favorites from before the transit.accessibility.cloud migration were
    // deleted once (their old ids don't exist in the new API) — surfaced as a
    // dismissible notice in the favorites area.
    @Published var showsLegacyRemovalNotice: Bool
    // How the favorites list is sorted. The stored array is always in the
    // displayed order, so this only steers writes — the widget and the watch
    // mirror whatever order lands in the store.
    @Published private(set) var order: FavoritesOrder

    init() {
        FavoritesStore.migrateIfNeeded()
        FavoritesStore.removeLegacyFavoritesIfNeeded()
        FavoritesStore.backfillAddedAtIfNeeded()
        // After the one-time migrations, so iCloud never receives a list they
        // are about to clean up, and before the first read, so the cloud copy
        // already on the device (a reinstall) is what the list starts with.
        FavoritesCloudSync.shared.start()
        showsLegacyRemovalNotice = FavoritesStore.removalNoticePending
        order = FavoritesStore.order
        elevators = FavoritesStore.load()
        loadCache()
        // A cloud copy that arrives later — another device, or iCloud's
        // initial download after a reinstall.
        FavoritesCloudSync.shared.onChange = { [weak self] in self?.cloudFavoritesChanged() }
    }

    // Another device (or iCloud's initial download) changed the favorites:
    // take them over like a local toggle would — same mirrors, same shortcut
    // set — and fetch statuses for elevators this device hasn't seen yet.
    private func cloudFavoritesChanged() {
        order = FavoritesStore.order
        elevators = FavoritesStore.load()
        loadCache()
        HissiShortcuts.updateAppShortcutParameters()
        fanOut()
        if elevators.contains(where: { $0.isWorking == nil }) {
            Task { await refresh() }
        }
    }

    func dismissLegacyRemovalNotice() {
        FavoritesStore.dismissRemovalNotice()
        showsLegacyRemovalNotice = false
    }

    // A refresh the user actually asked for — pull-to-refresh or the toolbar
    // button. Donated so the system can learn *when* checking elevators matters
    // to this person and propose it back (Siri Suggestions, Spotlight), with
    // the wording from CheckElevatorsIntent.predictionConfiguration.
    //
    // Deliberately not on every refresh: the 30-minute poll, the on-appear load
    // and the foreground refresh happen whether or not anyone wanted them, and
    // donating those would teach the system a pattern the user never expressed.
    func refreshRequestedByUser() async {
        // try? on purpose: a donation is a hint to the system, and losing one
        // must never cost the user their refresh.
        _ = try? await IntentDonationManager.shared.donate(intent: CheckElevatorsIntent())
        await refresh()
    }

    func refresh() async {
        isLoading = true
        errorMessage = nil
        let current = elevators
        let (updated, failed) = await ElevatorRefresher.refreshAll(current)
        // Seed-id favorites (created from a seed preview or the offline seed
        // fallback) can come back under their live identity, bridged via the
        // operator inventory number — persist the id migration so the store,
        // widget and watch use the live id from now on.
        let migrated = Dictionary(uniqueKeysWithValues: zip(current, updated).compactMap { old, new in
            old.id != new.id ? (old.id, new) : nil
        })
        FavoritesStore.migrateIds(migrated)
        if !migrated.isEmpty { FavoritesCloudSync.shared.upload() }
        // Mirror the store's dedup: a seed-id and a live-id favorite of the
        // same elevator collapse into one entry once the bridge unifies them.
        var seen = Set<String>()
        elevators = updated.filter { seen.insert($0.id).inserted }
        if !failed.isEmpty {
            errorMessage = String(localized: "Ein oder mehrere Aufzüge konnten nicht abgerufen werden.")
        }
        await RefreshFanOut.distribute(elevators, previous: current)
        isLoading = false
    }

    // MARK: - Order

    // Switching back to "zuletzt hinzugefügt" re-sorts the stored list; the
    // mirrors learn the new order right away instead of at their next refresh.
    func setOrder(_ order: FavoritesOrder) {
        guard order != self.order else { return }
        FavoritesStore.setOrder(order)
        self.order = order
        // Re-sorted in place rather than re-read: the in-memory list carries
        // the freshest statuses, the store only what was last persisted.
        elevators = FavoritesOrdering.apply(order, to: elevators)
        fanOut()
    }

    // A drag is what puts the list into manual mode — re-deriving the order
    // afterwards would silently undo it.
    func move(from source: IndexSet, to destination: Int) {
        let reordered = FavoritesOrdering.moved(elevators, from: source, to: destination)
        guard reordered.map(\.id) != elevators.map(\.id) else { return }
        FavoritesStore.setManualOrder(reordered)
        elevators = reordered
        order = .manual
        fanOut()
    }

    // MARK: - Favorites

    func isFavorite(_ id: String) -> Bool {
        elevators.contains { $0.id == id }
    }

    func toggleFavorite(_ elevator: MonitoredElevator) {
        if isFavorite(elevator.id) {
            FavoritesStore.remove(elevator.id)
            elevators.removeAll { $0.id == elevator.id }
        } else {
            // Same stamp on both sides, so store and view agree on where the
            // new favorite sits (newest first).
            let now = Date()
            FavoritesStore.add(elevator, now: now)
            elevators = FavoritesOrdering.inserting(elevator, into: elevators, at: now)
            // Search results can carry no status (e.g. a superseded catalog
            // build) — fetch it now instead of waiting for the next cycle.
            if elevator.isWorking == nil {
                Task { await refresh() }
            }
        }
        // The per-elevator App Shortcut set is enumerated from the favorites,
        // so a toggle changes which phrases exist.
        HissiShortcuts.updateAppShortcutParameters()
        // Every mirror learns the change now instead of at its next scheduled
        // refresh; a running live status monitors the favorites as a set, so
        // removing the last one ends it instead of leaving an empty activity.
        fanOut()
    }

    // Pushes the current favorites to every mirror (cache, widget timelines,
    // watch, live status) — the same fan-out a refresh ends with — and the
    // membership to iCloud (a no-op when iCloud already holds it).
    private func fanOut() {
        FavoritesCloudSync.shared.upload()
        let current = elevators
        Task { await RefreshFanOut.distribute(current) }
    }

    private func loadCache() {
        let cached = ElevatorCache.load()
        guard !cached.isEmpty else { return }
        for i in elevators.indices {
            if let hit = cached.first(where: { $0.id == elevators[i].id }) {
                // Favorites stay authoritative for identity and placement —
                // the cache only supplies the status.
                let index = elevators[i].elevatorIndex
                let addedAt = elevators[i].addedAt
                elevators[i] = hit
                elevators[i].elevatorIndex = index
                elevators[i].addedAt = addedAt
            }
        }
    }

    private func saveCache() {
        ElevatorCache.save(elevators)
    }
}
