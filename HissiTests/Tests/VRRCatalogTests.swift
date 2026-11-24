import Testing
import Foundation
@testable import HissiCore

private typealias Equipment = AccessibilityCloudClient.Equipment

private let vrrId = "vrr:de:05112:16580:31"
private let vrrSiblingId = "vrr:de:05112:16580:32"
private let dhid = "de:05112:16580"

private let seed = [
    SeedCatalog.Record(id: "101", stationId: "900000001", stationName: "S Teststadt", description: "Aufzug"),
    SeedCatalog.Record(id: "102", stationId: "900000001", stationName: "S Teststadt", description: "Aufzug 2"),
    SeedCatalog.Record(
        id: vrrId, stationId: dhid, stationName: "Duisburg Duissern U-Bf", region: "nordrhein-westfalen",
        description: "Straßenebene zum Bahnsteig", sourceName: "VRR"
    ),
]

private let stations = [
    SeedCatalog.Station(
        stationId: dhid, dhid: dhid, name: "Duisburg Duissern U-Bf", region: "nordrhein-westfalen",
        latitude: 51.439212, longitude: 6.782882
    ),
]

private func live(_ id: String, isWorking: Bool? = true, station: String = "") -> Equipment {
    let isVRR = ElevatorSource(id: id) == .vrr
    return Equipment(
        id: id, stationId: isVRR ? dhid : "", stationName: station, description: "", isWorking: isWorking,
        lastUpdate: Date(), sourceName: isVRR ? "VRR" : ""
    )
}

// Two sources, one catalog: each answers for its own elevators only.
@Suite struct PerSourceOverlayTests {
    private func overlaid(_ records: [Equipment]) -> [Equipment] {
        EquipmentCatalog.overlaid(live: records, seed: seed, stations: stations)
    }

    // accessibility.cloud answered, VRR didn't: the VRR elevators stand in
    // from the seed, status unknown — and an accessibility.cloud elevator
    // missing from its own answer is still gone.
    @Test func vrrOutageKeepsTheVRRSeedRecords() {
        let merged = overlaid([live("101", isWorking: false)])
        #expect(merged.map(\.id) == ["101", vrrId])
        #expect(merged.first?.isWorking == false)
        let standIn = merged.last
        #expect(standIn?.isWorking == nil)
        #expect(standIn?.stationName == "Duisburg Duissern U-Bf")
        #expect(standIn?.latitude == 51.439212)
    }

    @Test func accessibilityCloudOutageKeepsItsSeedRecords() {
        let merged = overlaid([live(vrrId, isWorking: false)])
        #expect(merged.map(\.id) == [vrrId, "101", "102"])
        #expect(merged.first?.isWorking == false)
        #expect(merged.dropFirst().allSatisfy { $0.isWorking == nil })
    }

    @Test func bothAnswerAndEachDropsWhatItNoLongerHas() {
        let merged = overlaid([live("102"), live(vrrSiblingId)])
        // 101 is gone at accessibility.cloud, the seeded VRR lift at VRR.
        #expect(merged.map(\.id) == ["102", vrrSiblingId])
    }

    @Test func noLiveDataAtAllServesTheWholeSeedUnknown() {
        let merged = overlaid([])
        #expect(merged.map(\.id) == ["101", "102", vrrId])
        #expect(merged.allSatisfy { $0.isWorking == nil })
    }

    // The feed's raw stop name would split the station in search and nearby
    // (they group by name) — the seed's normalised one wins.
    @Test func vrrStationNameComesFromTheSeed() {
        let merged = overlaid([live(vrrId, station: "DU-Duissern U")])
        #expect(merged.first?.stationName == "Duisburg Duissern U-Bf")
        #expect(merged.first?.stationId == dhid)
        #expect(merged.first?.description == "Straßenebene zum Bahnsteig")
    }

    // A lift added since the generation, at a stop the seed knows.
    @Test func newVRRLiftTakesItsStopsSeedName() {
        let merged = overlaid([live(vrrSiblingId, station: "DU-Duissern U")])
        #expect(merged.first?.stationName == "Duisburg Duissern U-Bf")
        #expect(merged.first?.latitude == 51.439212)
        #expect(merged.first?.region == .nordrheinWestfalen)
    }

    // accessibility.cloud records keep the old rule: live names win.
    @Test func accessibilityCloudStationNameStaysLive() {
        #expect(overlaid([live("101", station: "S Teststadt (neu)")]).first?.stationName == "S Teststadt (neu)")
    }
}

private actor Calls {
    var builds = 0
    var targeted: [[String]] = []
    var vrr = 0
    func build() { builds += 1 }
    func targeted(_ ids: [String]) { targeted.append(ids) }
    func vrrFetch() { vrr += 1 }
}

@Suite struct VRRCatalogTests {
    private let calls = Calls()

    private func tempCacheURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("vrr-catalog-\(UUID().uuidString).json")
    }

    private func catalog(
        ttl: TimeInterval = 600,
        cacheFileURL: URL? = nil,
        accessibilityCloud: [Equipment]? = [live("101"), live("102")],
        vrr: [Equipment]? = [live(vrrId, isWorking: false)],
        vrrEnabled: Bool = true
    ) -> EquipmentCatalog {
        let calls = calls
        return EquipmentCatalog(
            ttl: ttl,
            cacheFileURL: cacheFileURL ?? tempCacheURL(),
            seed: seed.filter { FeatureToggle.includes($0.id, vrr: vrrEnabled) },
            stations: stations,
            legacyIds: [:],
            buildLive: { await calls.build(); return accessibilityCloud },
            fetchTargeted: { ids in
                await calls.targeted(ids)
                return accessibilityCloud?.filter { ids.contains($0.id) }
            },
            fetchVRR: { await calls.vrrFetch(); return vrrEnabled ? vrr : nil },
            includes: { FeatureToggle.includes($0, vrr: vrrEnabled) }
        )
    }

    @Test func buildCombinesBothSources() async throws {
        let built = try #require(await catalog().all())
        #expect(built.map(\.id) == ["101", "102", vrrId])
        #expect(built.last?.isWorking == false)
        #expect(await calls.builds == 1)
        #expect(await calls.vrr == 1)
    }

    @Test func buildSurvivesAVRROutage() async throws {
        let built = try #require(await catalog(vrr: nil).all())
        #expect(built.map(\.id) == ["101", "102", vrrId])
        #expect(built.last?.isWorking == nil)
    }

    // Without accessibility.cloud there is no catalog build — as before; the
    // seed answers, nothing is cached as fresh.
    @Test func buildFailsWithoutAccessibilityCloud() async throws {
        let catalog = catalog(accessibilityCloud: nil)
        let fallback = try #require(await catalog.all())
        #expect(fallback.allSatisfy { $0.isWorking == nil })
        #expect(await catalog.snapshot(rebuildingIfStale: false) == nil)
    }

    // The targeted path asks each source only for what is its own.
    @Test func targetedRefreshRoutesBySource() async {
        let catalog = catalog(ttl: 0)
        let onlyNumeric = await catalog.equipment(for: ["101"])
        #expect(onlyNumeric.keys.sorted() == ["101"])
        #expect(await calls.targeted == [["101"]])
        #expect(await calls.vrr == 0)

        let mixed = await catalog.equipment(for: ["102", vrrId])
        #expect(mixed["102"]?.isWorking == true)
        #expect(mixed[vrrId]?.isWorking == false)
        #expect(mixed[vrrId]?.stationName == "Duisburg Duissern U-Bf")
        #expect(await calls.targeted == [["101"], ["102"]])
        #expect(await calls.vrr == 1)

        _ = await catalog.equipment(for: [vrrId])
        // No accessibility.cloud request for a VRR id.
        #expect(await calls.targeted.count == 2)
        #expect(await calls.vrr == 2)
    }

    @Test func targetedVRROutageAnswersUnknownWhileTheOtherSourceIsLive() async {
        let answer = await catalog(ttl: 0, vrr: nil).equipment(for: ["101", vrrId])
        #expect(answer["101"]?.isWorking == true)
        #expect(answer[vrrId] != nil)
        #expect(answer[vrrId]?.isWorking == nil)
    }

    @Test func targetedAccessibilityCloudOutageLeavesVRRLive() async {
        let answer = await catalog(ttl: 0, accessibilityCloud: nil).equipment(for: ["101", vrrId])
        #expect(answer["101"]?.isWorking == nil)
        #expect(answer[vrrId]?.isWorking == false)
    }

    // A fresh catalog answers both sources without a request …
    @Test func freshCatalogAnswersBothSources() async {
        let catalog = catalog()
        _ = await catalog.all()
        let answer = await catalog.equipment(for: ["101", vrrId])
        #expect(answer[vrrId]?.isWorking == false)
        #expect(await calls.targeted.isEmpty)
        #expect(await calls.vrr == 1)
    }

    // … unless it was built while VRR didn't answer: its VRR records are
    // seed stand-ins, so a VRR favorite asks again instead of reading
    // "unbekannt" until the cache expires. Other favorites still cost nothing.
    @Test func freshCatalogBuiltDuringAVRROutageAsksVRRAgain() async {
        let url = tempCacheURL()
        _ = await catalog(cacheFileURL: url, vrr: nil).all()
        let reader = catalog(cacheFileURL: url)
        #expect(await reader.equipment(for: ["101"])["101"]?.isWorking == true)
        #expect(await calls.vrr == 1)
        let answer = await reader.equipment(for: ["101", vrrId])
        #expect(answer[vrrId]?.isWorking == false)
        #expect(answer["101"]?.isWorking == true)
        #expect(await calls.vrr == 2)
        #expect(await calls.targeted.isEmpty)
    }

    // Switching the source off hides what an earlier run persisted.
    @Test func toggleOffFiltersPersistedVRRRecords() async throws {
        let url = tempCacheURL()
        _ = await catalog(cacheFileURL: url).all()
        let reader = catalog(cacheFileURL: url, vrrEnabled: false)
        let snapshot = try #require(await reader.snapshot(rebuildingIfStale: false))
        #expect(snapshot.map(\.id) == ["101", "102"])
        #expect(await reader.equipment(for: [vrrId]).isEmpty)
    }
}

// One refresh over favorites of both sources.
@Suite struct MixedSourceRefreshTests {
    @Test func favoritesOfBothSourcesRefreshTogether() async {
        func favorite(_ id: String) -> MonitoredElevator {
            MonitoredElevator(
                id: id, stationId: "1", elevatorId: id, stationName: "S", elevatorDescription: "",
                isWorking: nil, lastChecked: nil
            )
        }
        let since = Date(timeIntervalSince1970: 1_800_000_000)
        let vrrRecord = Equipment(
            id: vrrId, stationId: dhid, stationName: "Duisburg Duissern U-Bf", description: "Aufzug",
            isWorking: false, lastUpdate: Date(), statusSince: since, sourceName: "VRR",
            stateExplanation: "Kein Betrieb"
        )
        let sources = StatusSources(equipment: { _ in ["101": live("101"), vrrId: vrrRecord] })
        let (updated, failed) = await ElevatorRefresher.refreshAll([favorite("101"), favorite(vrrId)], sources: sources)
        #expect(failed.isEmpty)
        #expect(updated.map(\.isWorking) == [true, false])
        #expect(updated.last?.id == vrrId)
        #expect(updated.last?.statusSince == since)
        #expect(updated.last?.stateExplanation == "Kein Betrieb")
        #expect(updated.last?.sourceName == "VRR")
    }
}
