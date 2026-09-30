import Testing
import Foundation
@testable import HissiCore

// Records which ids the refresher resolved against the catalog.
private actor CallLog {
    var equipmentRequests: [Set<String>] = []
    func equipment(_ ids: Set<String>) { equipmentRequests.append(ids) }
}

@Suite struct ElevatorRefresherTests {
    private let log = CallLog()

    private func favorite(id: String, stationId: String = "1") -> MonitoredElevator {
        MonitoredElevator(
            id: id, stationId: stationId, elevatorId: id,
            stationName: "S Teststadt", elevatorDescription: "Aufzug",
            isWorking: true, lastChecked: nil
        )
    }

    private func sources(
        equipment: [String: AccessibilityCloudClient.Equipment] = [:]
    ) -> StatusSources {
        let log = log
        return StatusSources(
            equipment: { ids in await log.equipment(ids); return equipment }
        )
    }

    private func equipment(id: String, isWorking: Bool?) -> AccessibilityCloudClient.Equipment {
        AccessibilityCloudClient.Equipment(
            id: id, stationId: "900000001", stationName: "S Teststadt",
            description: "Straße ⟷ Bahnsteig", isWorking: isWorking, lastUpdate: Date()
        )
    }

    @Test func allFavoritesResolveFromOneCatalogBatch() async throws {
        let (updated, failed) = await ElevatorRefresher.refreshAll(
            [favorite(id: "101"), favorite(id: "102")],
            sources: sources(equipment: [
                "101": equipment(id: "101", isWorking: false),
                "102": equipment(id: "102", isWorking: true),
            ])
        )
        #expect(updated.map(\.isWorking) == [false, true])
        #expect(failed.isEmpty)
        // One batch covering both ids — never one request per favorite.
        #expect(await log.equipmentRequests == [["101", "102"]])
    }

    @Test func totalFailureKeepsValuesAndReportsIds() async throws {
        let favorites = [favorite(id: "101"), favorite(id: "102")]
        let (updated, failed) = await ElevatorRefresher.refreshAll(favorites, sources: sources())
        // Nothing resolved: previous values survive, both ids are reported.
        #expect(updated.map(\.isWorking) == [true, true])
        #expect(failed == ["101", "102"])
    }

    @Test func emptyFavoritesDoNotTouchTheCatalog() async {
        let (updated, failed) = await ElevatorRefresher.refreshAll([], sources: sources())
        #expect(updated.isEmpty && failed.isEmpty)
        #expect(await log.equipmentRequests.isEmpty)
    }

    // A seed-id favorite answered with its bridged live record adopts the
    // live identity (the app then persists the id migration).
    @Test func bridgedFavoriteAdoptsTheLiveIdentity() async {
        let (updated, failed) = await ElevatorRefresher.refreshAll(
            [favorite(id: "fasta-42")],
            sources: sources(equipment: ["fasta-42": equipment(id: "456", isWorking: false)])
        )
        #expect(updated.map(\.id) == ["456"])
        #expect(updated.map(\.isWorking) == [false])
        #expect(failed.isEmpty)
    }
}

// The favorites store: the one-time deletion of favorites created under the
// pre-migration id schemes (old Mongo _id, "fasta-…", "brokenlifts-…" — the
// new API's ids are numeric, and a notice flag surfaces the deletion once),
// and the order the store keeps them in. Serialized as one suite because
// every test here writes the same App Group keys.
@Suite(.serialized) struct FavoritesStoreTests {
    private let reference = Date(timeIntervalSince1970: 1_700_000_000)

    private func reset() {
        // Same store FavoritesStore writes to.
        let defaults = UserDefaults(suiteName: ElevatorCache.appGroupID) ?? .standard
        for key in [
            "favoriteElevators",
            "favoritesCleanedForTransitAPI",
            "legacyFavoritesRemovalNoticePending",
            "favoritesOrder",
            "favoritesAddedAtBackfilled",
        ] { defaults.removeObject(forKey: key) }
    }

    private func favorite(id: String, addedAt: Date? = nil) -> MonitoredElevator {
        MonitoredElevator(
            id: id, stationId: "1", elevatorId: id,
            stationName: "S Teststadt", elevatorDescription: "Aufzug",
            isWorking: nil, lastChecked: nil, addedAt: addedAt
        )
    }

    @Test func removesOldPatternIdsOnceAndFlagsTheNotice() {
        reset()
        defer { reset() }
        for id in ["z87ZFWJs5aB2seuYf", "fasta-10466003", "brokenlifts-900009103-0", "6225"] {
            FavoritesStore.add(favorite(id: id))
        }
        FavoritesStore.removeLegacyFavoritesIfNeeded()
        #expect(FavoritesStore.load().map(\.id) == ["6225"])
        #expect(FavoritesStore.removalNoticePending)

        FavoritesStore.dismissRemovalNotice()
        #expect(!FavoritesStore.removalNoticePending)

        // Idempotent: a later old-pattern favorite (offline seed record) must
        // not be deleted by a re-run.
        FavoritesStore.add(favorite(id: "brokenlifts-900320006-0"))
        FavoritesStore.removeLegacyFavoritesIfNeeded()
        // Newest first — the fresh favorite sits at the top.
        #expect(FavoritesStore.load().map(\.id) == ["brokenlifts-900320006-0", "6225"])
        #expect(!FavoritesStore.removalNoticePending)
    }

    @Test func cleanFavoritesTriggerNoNotice() {
        reset()
        defer { reset() }
        FavoritesStore.add(favorite(id: "6225"))
        FavoritesStore.removeLegacyFavoritesIfNeeded()
        #expect(FavoritesStore.load().map(\.id) == ["6225"])
        #expect(!FavoritesStore.removalNoticePending)
    }

    // The id migration after a bridged refresh rewrites only the listed
    // favorites — a favorite added while the refresh ran survives, and the
    // same elevator favorited under both its seed and live id collapses.
    @Test func migrateIdsRewritesOnlyTheListedFavorites() {
        reset()
        defer { reset() }
        FavoritesStore.add(favorite(id: "fasta-42"))
        FavoritesStore.add(favorite(id: "6225"))
        FavoritesStore.add(favorite(id: "456"))
        let live = MonitoredElevator(
            id: "456", stationId: "900000001", elevatorId: "456",
            stationName: "S Teststadt", elevatorDescription: "Aufzug",
            isWorking: true, lastChecked: nil
        )
        FavoritesStore.migrateIds(["fasta-42": live])
        #expect(FavoritesStore.load().map(\.id) == ["456", "6225"])
        FavoritesStore.migrateIds([:])
        #expect(FavoritesStore.load().map(\.id) == ["456", "6225"])
    }

    @Test func defaultsToRecentlyAddedAndPrepends() {
        reset()
        defer { reset() }
        #expect(FavoritesStore.order == .recentlyAdded)
        FavoritesStore.add(favorite(id: "1"), now: reference)
        FavoritesStore.add(favorite(id: "2"), now: reference.addingTimeInterval(60))
        #expect(FavoritesStore.load().map(\.id) == ["2", "1"])
        #expect(FavoritesStore.load().allSatisfy { $0.addedAt != nil })
    }

    @Test func manualOrderSurvivesAFurtherAdd() {
        reset()
        defer { reset() }
        FavoritesStore.add(favorite(id: "1"), now: reference)
        FavoritesStore.add(favorite(id: "2"), now: reference.addingTimeInterval(60))
        FavoritesStore.setManualOrder(Array(FavoritesStore.load().reversed()))
        #expect(FavoritesStore.order == .manual)
        #expect(FavoritesStore.load().map(\.id) == ["1", "2"])

        FavoritesStore.add(favorite(id: "3"), now: reference.addingTimeInterval(120))
        #expect(FavoritesStore.load().map(\.id) == ["3", "1", "2"])

        // Back to the default order: derived from the add timestamps again.
        FavoritesStore.setOrder(.recentlyAdded)
        #expect(FavoritesStore.load().map(\.id) == ["3", "2", "1"])
    }

    // Favorites stored before the timestamp existed were appended, so the
    // upgrade flips them into newest-first once — and only once.
    @Test func backfillFlipsALegacyListOnce() throws {
        reset()
        defer { reset() }
        let defaults = UserDefaults(suiteName: ElevatorCache.appGroupID) ?? .standard
        let legacy = [favorite(id: "old"), favorite(id: "mid"), favorite(id: "new")]
        defaults.set(try JSONEncoder().encode(legacy), forKey: "favoriteElevators")

        FavoritesStore.backfillAddedAtIfNeeded(now: reference)
        #expect(FavoritesStore.load().map(\.id) == ["new", "mid", "old"])

        FavoritesStore.setManualOrder(Array(FavoritesStore.load().reversed()))
        FavoritesStore.backfillAddedAtIfNeeded()
        #expect(FavoritesStore.load().map(\.id) == ["old", "mid", "new"])
    }
}
