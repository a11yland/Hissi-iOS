import Testing
import Foundation
@testable import HissiCore

@Suite struct FavoritesCloudMergeTests {
    private let reference = Date(timeIntervalSince1970: 1_700_000_000)

    private func favorite(_ id: String, addedAt: Date? = nil, isWorking: Bool? = true) -> MonitoredElevator {
        MonitoredElevator(
            id: id, stationId: "1", elevatorId: id,
            stationName: "S Teststadt", elevatorDescription: "Aufzug",
            isWorking: isWorking, lastChecked: isWorking == nil ? nil : reference,
            stateExplanation: isWorking == false ? "Außer Betrieb" : nil,
            addedAt: addedAt
        )
    }

    private func cloud(_ favorites: [MonitoredElevator], order: FavoritesOrder = .manual) -> FavoritesCloudSnapshot {
        FavoritesCloudSnapshot(favorites: favorites, order: order)
    }

    // MARK: - Snapshot

    // Statuses go stale in transit, and leaving them out means a status-only
    // refresh never rewrites the cloud copy.
    @Test func snapshotStripsStatuses() {
        let snapshot = cloud([favorite("a", isWorking: false)])
        let stored = snapshot.favorites[0]
        #expect(stored.isWorking == nil)
        #expect(stored.lastChecked == nil)
        #expect(stored.lastUpdated == nil)
        #expect(stored.stateExplanation == nil)
        #expect(snapshot == cloud([favorite("a", isWorking: true)]))
    }

    @Test func snapshotKeepsIdentityAndPlacement() {
        let snapshot = cloud([favorite("a", addedAt: reference)])
        #expect(snapshot.favorites[0].id == "a")
        #expect(snapshot.favorites[0].stationName == "S Teststadt")
        #expect(snapshot.favorites[0].addedAt == reference)
    }

    @Test func snapshotRoundTrips() throws {
        let snapshot = cloud([favorite("a", addedAt: reference), favorite("b")], order: .recentlyAdded)
        let data = try #require(snapshot.encoded())
        #expect(FavoritesCloudSnapshot.decoded(from: data) == snapshot)
    }

    // A newer app version may introduce a sort mode this one doesn't know.
    @Test func unknownOrderFallsBackToDefault() {
        var snapshot = cloud([favorite("a")])
        snapshot.order = "byStatus"
        #expect(snapshot.favoritesOrder == .default)
    }

    // MARK: - Union (never synced)

    // The reinstall case: nothing local, everything comes from iCloud.
    @Test func reinstallTakesTheCloudCopy() {
        let merged = FavoritesCloudMerge.merged(
            local: [], localOrder: .default,
            cloud: cloud([favorite("b"), favorite("a")], order: .manual),
            mode: .union
        )
        #expect(merged.favorites.map(\.id) == ["b", "a"])
        #expect(merged.order == .manual)
    }

    @Test func unionKeepsLocalOnlyFavoritesOnTop() {
        let merged = FavoritesCloudMerge.merged(
            local: [favorite("x"), favorite("a")], localOrder: .manual,
            cloud: cloud([favorite("a"), favorite("b")], order: .manual),
            mode: .union
        )
        #expect(merged.favorites.map(\.id) == ["x", "a", "b"])
    }

    @Test func unionReSortsInRecentlyAddedOrder() {
        let merged = FavoritesCloudMerge.merged(
            local: [favorite("new", addedAt: reference.addingTimeInterval(60))], localOrder: .recentlyAdded,
            cloud: cloud([favorite("older", addedAt: reference), favorite("newest", addedAt: reference.addingTimeInterval(120))],
                         order: .recentlyAdded),
            mode: .union
        )
        #expect(merged.favorites.map(\.id) == ["newest", "new", "older"])
    }

    // An empty cloud copy has no opinion on how the list is sorted.
    @Test func unionWithEmptyCloudKeepsTheLocalOrderMode() {
        let merged = FavoritesCloudMerge.merged(
            local: [favorite("a"), favorite("b")], localOrder: .manual,
            cloud: cloud([], order: .recentlyAdded),
            mode: .union
        )
        #expect(merged.favorites.map(\.id) == ["a", "b"])
        #expect(merged.order == .manual)
    }

    // MARK: - Adopt (already synced)

    // A removal on another device must stick — a union would bring it back.
    @Test func adoptPropagatesRemovals() {
        let merged = FavoritesCloudMerge.merged(
            local: [favorite("a"), favorite("b")], localOrder: .manual,
            cloud: cloud([favorite("b")], order: .manual),
            mode: .adopt
        )
        #expect(merged.favorites.map(\.id) == ["b"])
    }

    @Test func adoptTakesTheCloudOrderAndMode() {
        let merged = FavoritesCloudMerge.merged(
            local: [favorite("a"), favorite("b")], localOrder: .recentlyAdded,
            cloud: cloud([favorite("b"), favorite("a")], order: .manual),
            mode: .adopt
        )
        #expect(merged.favorites.map(\.id) == ["b", "a"])
        #expect(merged.order == .manual)
    }

    // Known elevators keep their status instead of flashing to "unknown";
    // new ones arrive without one and get fetched.
    @Test func mergeKeepsLocalStatusForKnownElevators() {
        let merged = FavoritesCloudMerge.merged(
            local: [favorite("a", isWorking: false)], localOrder: .manual,
            cloud: cloud([favorite("a"), favorite("b")], order: .manual),
            mode: .adopt
        )
        #expect(merged.favorites[0].isWorking == false)
        #expect(merged.favorites[0].stateExplanation == "Außer Betrieb")
        #expect(merged.favorites[0].lastChecked == reference)
        #expect(merged.favorites[1].isWorking == nil)
    }

    @Test func mergeDeduplicatesIds() {
        let snapshot = cloud([favorite("a"), favorite("a")])
        let adopted = FavoritesCloudMerge.merged(local: [], localOrder: .manual, cloud: snapshot, mode: .adopt)
        let united = FavoritesCloudMerge.merged(local: [favorite("a")], localOrder: .manual, cloud: snapshot, mode: .union)
        #expect(adopted.favorites.map(\.id) == ["a"])
        #expect(united.favorites.map(\.id) == ["a"])
    }
}
