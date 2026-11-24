import Testing
import Foundation
@testable import HissiCore

// The id names the source. Everything that used to ask "is this id numeric?"
// asks this type instead — so a VRR id is never mistaken for a pre-migration
// one.
@Suite struct ElevatorSourceTests {
    @Test func numericIdsAreAccessibilityCloud() {
        #expect(ElevatorSource(id: "7368") == .accessibilityCloud)
    }

    @Test func prefixedIdsAreVRR() {
        #expect(ElevatorSource(id: "vrr:de:05112:16580:31") == .vrr)
        #expect(ElevatorSource.vrrId(resourceId: "de:05112:16580:31") == "vrr:de:05112:16580:31")
    }

    @Test func everythingElseIsLegacy() {
        #expect(ElevatorSource(id: "fasta-10315619") == .legacy)
        #expect(ElevatorSource(id: "brokenlifts-900100003-2") == .legacy)
        #expect(ElevatorSource(id: "23ZEJX7dztP3iQnYN") == .legacy)
        #expect(ElevatorSource(id: "") == .legacy)
        // A bare prefix names no elevator.
        #expect(ElevatorSource(id: "vrr:") == .legacy)
    }

    @Test func onlyLegacyIdsAreNotLive() {
        #expect(ElevatorSource.accessibilityCloud.isLive)
        #expect(ElevatorSource.vrr.isLive)
        #expect(!ElevatorSource.legacy.isLive)
    }

    private func favorite(_ id: String, since: Date? = nil) -> MonitoredElevator {
        MonitoredElevator(
            id: id, stationId: "1", elevatorId: id, stationName: "S", elevatorDescription: "",
            isWorking: true, lastChecked: nil, statusSince: since
        )
    }

    // The one-time cleanup of pre-migration favorites must never take a VRR
    // favorite with it.
    @Test func legacyCleanupKeepsVRRFavorites() {
        let kept = FavoritesStore.withoutLegacy(
            [favorite("7368"), favorite("vrr:de:05112:16580:31"), favorite("fasta-1")]
        )
        #expect(kept.map(\.id) == ["7368", "vrr:de:05112:16580:31"])
    }

    // The seed's legacyIds bridge is for pre-migration ids only.
    @Test func bridgeIgnoresVRRIds() {
        let bridged = EquipmentCatalog.bridgedLiveIds(
            for: ["vrr:de:05112:16580:31", "fasta-1", "7368"],
            legacyIds: ["vrr:de:05112:16580:31": "1", "fasta-1": "2", "7368": "3"]
        )
        #expect(bridged == ["fasta-1": "2"])
    }

    // A legacy favorite adopts the identity of the live record it resolves
    // to — whichever source that record is from; a legacy record never
    // replaces an identity.
    @Test func statusMergeAdoptsLiveIdentitiesOnly() {
        func equipment(_ id: String) -> AccessibilityCloudClient.Equipment {
            .init(id: id, stationId: "1", stationName: "S", description: "", isWorking: true, lastUpdate: nil)
        }
        #expect(StatusMerge.apply(equipment("101"), to: favorite("fasta-1")).id == "101")
        #expect(StatusMerge.apply(equipment("vrr:de:05112:16580:31"), to: favorite("fasta-1")).id == "vrr:de:05112:16580:31")
        #expect(StatusMerge.apply(equipment("fasta-2"), to: favorite("101")).id == "101")
    }

    // Only accessibility.cloud keeps a span history: an undated VRR favorite
    // is not asked about.
    @Test func historyIsNotRequestedForVRRIds() async {
        actor Log {
            var requests: [Set<String>] = []
            func record(_ ids: Set<String>) { requests.append(ids) }
        }
        let log = Log()
        var sources = StatusSources(equipment: { _ in [:] })
        sources.latestSpans = { ids in
            await log.record(ids)
            return []
        }
        _ = await ElevatorRefresher.withHistory(
            [favorite("7368"), favorite("vrr:de:05112:16580:31")], sources: sources
        )
        #expect(await log.requests == [["7368"]])
        _ = await ElevatorRefresher.withHistory([favorite("vrr:de:05112:16580:31")], sources: sources)
        #expect(await log.requests.count == 1)
    }

    // The toggle's filter: a VRR record only counts while the feature is on;
    // everything else always does.
    @Test func toggleFiltersVRRIdsOnly() {
        #expect(FeatureToggle.includes("7368", vrr: false))
        #expect(FeatureToggle.includes("fasta-1", vrr: false))
        #expect(!FeatureToggle.includes("vrr:de:05112:16580:31", vrr: false))
        #expect(FeatureToggle.includes("vrr:de:05112:16580:31", vrr: true))
    }
}
