import Foundation

// Mirrors the favorites into iCloud's key-value store, so they survive an app
// reinstall and follow the user to a new iPhone, iPad or Mac. The App Group
// store stays the source every target reads (FR4); iCloud is one more mirror,
// written by the iOS app only and read back only by the iOS app. Without an
// iCloud account (or with iCloud turned off for Hissi) the store simply
// never syncs, and everything works locally as before.
//
// The store's identifier is pinned in Hissi.entitlements to
// `$(TeamIdentifierPrefix)com.a11yland.LiftBoy` — deliberately not
// `$(CFBundleIdentifier)`: a successor app from the same team under its own
// bundle id keeps that exact value and reads this store, which imports the
// LiftBoy favorites on its first launch (never synced → union). Changing the
// value strands every favorite already in iCloud.
//
// Conflict rule (FavoritesCloudMerge): an installation that has never synced
// unites its list with the cloud copy; afterwards the latest writer wins, so a
// removal on one device removes the favorite everywhere.
@MainActor
final class FavoritesCloudSync {
    static let shared = FavoritesCloudSync()

    private static let key = "favorites"
    // Local and deliberately *not* in iCloud: a reinstall erases it, which is
    // exactly what makes the first sync after a reinstall a union.
    private static let syncedOnceKey = "favoritesCloudSyncedOnce"

    private let store = NSUbiquitousKeyValueStore.default
    private var started = false
    // Runs after a later change from iCloud has been written to
    // FavoritesStore.
    var onChange: (() -> Void)?

    private var syncedOnce: Bool {
        get { UserDefaults.standard.bool(forKey: Self.syncedOnceKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.syncedOnceKey) }
    }

    private init() {}

    // Merges whatever the cloud already holds into the local store before the
    // caller reads it, then keeps listening.
    func start() {
        guard !started else { return }
        started = true
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store,
            queue: .main
        ) { note in
            let reason = note.userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int
            let keys = note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String] ?? []
            MainActor.assumeIsolated {
                FavoritesCloudSync.shared.handleExternalChange(reason: reason, keys: keys)
            }
        }
        store.synchronize()
        if cloudSnapshot() != nil {
            _ = merge(mode: syncedOnce ? .adopt : .union)
        } else if !FavoritesStore.load().isEmpty {
            // Nothing in iCloud yet (or not downloaded yet — an initial sync
            // arriving later is united, see handleExternalChange): offer the
            // local list.
            upload()
        }
    }

    // Writes the current favorites to iCloud — after every local change.
    // Skipped when the cloud copy already says the same, so status-only
    // refreshes never write.
    func upload() {
        let snapshot = FavoritesCloudSnapshot(favorites: FavoritesStore.load(), order: FavoritesStore.order)
        syncedOnce = true
        guard snapshot != cloudSnapshot(), let data = snapshot.encoded() else { return }
        store.set(data, forKey: Self.key)
    }

    private func handleExternalChange(reason: Int?, keys: [String]) {
        guard keys.contains(Self.key) else { return }
        let mode: FavoritesCloudMerge.Mode
        switch reason {
        case NSUbiquitousKeyValueStoreServerChange:
            mode = syncedOnce ? .adopt : .union
        case NSUbiquitousKeyValueStoreInitialSyncChange, NSUbiquitousKeyValueStoreAccountChange:
            // First contact with this account's data — nothing may get lost.
            mode = .union
        default:
            // Quota violation: the favorites are far below the limit; nothing
            // to merge.
            return
        }
        if merge(mode: mode) { onChange?() }
    }

    // Returns whether the local store changed.
    private func merge(mode: FavoritesCloudMerge.Mode) -> Bool {
        guard let cloud = cloudSnapshot() else { return false }
        let local = FavoritesStore.load()
        let localOrder = FavoritesStore.order
        let merged = FavoritesCloudMerge.merged(local: local, localOrder: localOrder, cloud: cloud, mode: mode)
        let changed = merged.favorites != local || merged.order != localOrder
        if changed {
            FavoritesStore.replace(with: merged.favorites, order: merged.order)
        }
        // A union may hold more than the cloud copy — hand it back.
        upload()
        return changed
    }

    private func cloudSnapshot() -> FavoritesCloudSnapshot? {
        store.data(forKey: Self.key).flatMap(FavoritesCloudSnapshot.decoded(from:))
    }
}
