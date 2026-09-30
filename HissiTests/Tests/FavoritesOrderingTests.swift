import Testing
import Foundation
@testable import HissiCore

@Suite struct FavoritesOrderingTests {
    private let reference = Date(timeIntervalSince1970: 1_700_000_000)

    private func favorite(_ id: String, addedAt: Date? = nil) -> MonitoredElevator {
        MonitoredElevator(
            id: id, stationId: "1", elevatorId: id,
            stationName: "S Teststadt", elevatorDescription: "Aufzug",
            isWorking: true, lastChecked: nil, addedAt: addedAt
        )
    }

    // MARK: - Default order

    @Test func recentlyAddedSortsNewestFirst() {
        let sorted = FavoritesOrdering.byRecentlyAdded([
            favorite("a", addedAt: reference),
            favorite("b", addedAt: reference.addingTimeInterval(60)),
            favorite("c", addedAt: reference.addingTimeInterval(-60)),
        ])
        #expect(sorted.map(\.id) == ["b", "a", "c"])
    }

    // Favorites stored before addedAt existed must not jump to the top just
    // because they carry no timestamp.
    @Test func favoritesWithoutTimestampSortLastKeepingTheirOrder() {
        let sorted = FavoritesOrdering.byRecentlyAdded([
            favorite("legacy1"),
            favorite("new", addedAt: reference),
            favorite("legacy2"),
        ])
        #expect(sorted.map(\.id) == ["new", "legacy1", "legacy2"])
    }

    @Test func equalTimestampsKeepTheirRelativeOrder() {
        let sorted = FavoritesOrdering.byRecentlyAdded([
            favorite("a", addedAt: reference),
            favorite("b", addedAt: reference),
        ])
        #expect(sorted.map(\.id) == ["a", "b"])
    }

    @Test func manualOrderIsLeftAlone() {
        let list = [favorite("a", addedAt: reference), favorite("b", addedAt: reference.addingTimeInterval(60))]
        #expect(FavoritesOrdering.apply(.manual, to: list).map(\.id) == ["a", "b"])
        #expect(FavoritesOrdering.apply(.recentlyAdded, to: list).map(\.id) == ["b", "a"])
    }

    @Test func defaultOrderIsRecentlyAdded() {
        #expect(FavoritesOrder.default == .recentlyAdded)
    }

    // MARK: - Adding

    @Test func newFavoriteGoesToTheTopAndIsStamped() {
        let existing = [favorite("a", addedAt: reference)]
        let updated = FavoritesOrdering.inserting(favorite("b"), into: existing, at: reference.addingTimeInterval(60))
        #expect(updated.map(\.id) == ["b", "a"])
        #expect(updated.first?.addedAt == reference.addingTimeInterval(60))
    }

    @Test func insertingKeepsAnExistingTimestamp() {
        let updated = FavoritesOrdering.inserting(favorite("b", addedAt: reference), into: [], at: reference.addingTimeInterval(60))
        #expect(updated.first?.addedAt == reference)
    }

    @Test func insertingIgnoresDuplicates() {
        let existing = [favorite("a", addedAt: reference)]
        let updated = FavoritesOrdering.inserting(favorite("a"), into: existing, at: reference.addingTimeInterval(60))
        #expect(updated.map(\.id) == ["a"])
        #expect(updated.first?.addedAt == reference)
    }

    // MARK: - Manual moves

    @Test func moveReordersLikeSwiftUI() {
        let list = [favorite("a"), favorite("b"), favorite("c")]
        #expect(FavoritesOrdering.moved(list, from: IndexSet(integer: 2), to: 0).map(\.id) == ["c", "a", "b"])
        #expect(FavoritesOrdering.moved(list, from: IndexSet(integer: 0), to: 3).map(\.id) == ["b", "c", "a"])
    }

    // MARK: - Upgrade backfill

    // The stored order of a pre-timestamp list is its add order (appended),
    // so the first entry is the oldest — and the default order flips it.
    @Test func backfillDerivesTimestampsFromTheStoredOrder() {
        let stamped = FavoritesOrdering.backfillingAddedAt(
            [favorite("first"), favorite("second"), favorite("third")],
            now: reference
        )
        let dates = stamped.compactMap(\.addedAt)
        #expect(dates.count == 3)
        #expect(dates == dates.sorted())
        #expect(dates.allSatisfy { $0 < reference })
        #expect(FavoritesOrdering.byRecentlyAdded(stamped).map(\.id) == ["third", "second", "first"])
    }

    @Test func backfillLeavesExistingTimestampsUntouched() {
        let stamped = FavoritesOrdering.backfillingAddedAt(
            [favorite("kept", addedAt: reference), favorite("new")],
            now: reference.addingTimeInterval(600)
        )
        #expect(stamped.first?.addedAt == reference)
        #expect(stamped.last?.addedAt != nil)
    }

    @Test func backfillIsANoOpWithoutMissingTimestamps() {
        let list = [favorite("a", addedAt: reference)]
        #expect(FavoritesOrdering.backfillingAddedAt(list, now: reference) == list)
    }
}
