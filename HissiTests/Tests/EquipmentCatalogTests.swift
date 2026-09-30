import Testing
import Foundation
@testable import HissiCore

// Counts and answers catalog builds, one generation per call — lets tests
// distinguish "served from cache/disk" from "rebuilt".
private actor BuildStub {
    private(set) var builds = 0
    private let generations: [[AccessibilityCloudClient.Equipment]?]

    init(_ generations: [[AccessibilityCloudClient.Equipment]?]) {
        self.generations = generations
    }

    func next() -> [AccessibilityCloudClient.Equipment]? {
        defer { builds += 1 }
        return builds < generations.count ? generations[builds] : generations.last ?? nil
    }
}

private func equipment(id: String, isWorking: Bool?) -> AccessibilityCloudClient.Equipment {
    AccessibilityCloudClient.Equipment(
        id: id,
        stationId: "900000001",
        stationName: "S Teststadt",
        stationNetworks: [.sBahn],
        description: "Straße ⟷ Bahnsteig",
        isWorking: isWorking,
        lastUpdate: Date(timeIntervalSince1970: 1_750_000_000),
        region: .berlin
    )
}

private func tempCacheURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("catalog-test-\(UUID().uuidString).json")
}

// The pure name filter behind every search phase (seed preview, snapshot,
// fresh catalog).
@Suite struct MatchStationsTests {
    private var catalog: [AccessibilityCloudClient.Equipment] {
        [
            AccessibilityCloudClient.Equipment(
                id: "1", stationId: "1", stationName: "Schönhauser Allee (Berlin)",
                description: "", isWorking: nil, lastUpdate: nil
            ),
            AccessibilityCloudClient.Equipment(
                id: "2", stationId: "2", stationName: "S Ostkreuz (Berlin)",
                description: "", isWorking: nil, lastUpdate: nil
            ),
        ]
    }

    // Umlauts fold ("schonhauser" finds Schönhauser); note "ß" is its own
    // letter, not a diacritic — "weissensee" would NOT match Weißensee.
    @Test func matchesCaseAndDiacriticInsensitive() {
        #expect(AccessibilityCloudClient.matchStations("schonhauser", in: catalog).map(\.id) == ["1"])
        #expect(AccessibilityCloudClient.matchStations("SCHÖNHAUSER", in: catalog).map(\.id) == ["1"])
        #expect(AccessibilityCloudClient.matchStations("OSTKREUZ", in: catalog).map(\.id) == ["2"])
    }

    @Test func matchesSubstringsAnywhereInTheName() {
        #expect(AccessibilityCloudClient.matchStations("kreuz", in: catalog).map(\.id) == ["2"])
    }

    @Test func blankQueryMatchesNothing() {
        #expect(AccessibilityCloudClient.matchStations("  ", in: catalog).isEmpty)
        #expect(AccessibilityCloudClient.matchStations("Pankow", in: catalog).isEmpty)
    }
}

// The match-highlighting behind search result headers: bold exactly the
// matched substring, plain when nothing matches contiguously.
@Suite struct HighlightedStationNameTests {
    private func boldRuns(_ attributed: AttributedString) -> [String] {
        attributed.runs
            .filter { $0.inlinePresentationIntent == .stronglyEmphasized }
            .map { String(attributed[$0.range].characters) }
    }

    @Test func boldsTheMatchedSubstringOnly() {
        let highlighted = AccessibilityCloudClient.highlightedStationName(
            "S Ostkreuz (Berlin)", matching: "kreuz"
        )
        #expect(boldRuns(highlighted) == ["kreuz"])
        #expect(String(highlighted.characters) == "S Ostkreuz (Berlin)")
    }

    // The bold range must live in the original spelling even when the match
    // succeeded only via case/diacritic folding.
    @Test func caseAndDiacriticInsensitiveMatchBoldsOriginalSpelling() {
        let highlighted = AccessibilityCloudClient.highlightedStationName(
            "Schönhauser Allee (Berlin)", matching: "schonhauser"
        )
        #expect(boldRuns(highlighted) == ["Schönhauser"])
    }

    @Test func noMatchOrBlankQueryStaysPlain() {
        let plain = AccessibilityCloudClient.highlightedStationName(
            "S Ostkreuz (Berlin)", matching: "Pankow"
        )
        #expect(boldRuns(plain).isEmpty)
        let blank = AccessibilityCloudClient.highlightedStationName(
            "S Ostkreuz (Berlin)", matching: "   "
        )
        #expect(boldRuns(blank).isEmpty)
    }
}

// The persisted catalog is what makes the search instant across launches —
// stale-while-revalidate: serve whatever exists, rebuild in the background.
@Suite struct CatalogPersistenceTests {
    @Test func equipmentSurvivesACodableRoundTrip() throws {
        let full = equipment(id: "101", isWorking: false)
        let minimal = AccessibilityCloudClient.Equipment(
            id: "7", stationId: "", stationName: "", description: "", isWorking: nil, lastUpdate: nil
        )
        let data = try JSONEncoder().encode([full, minimal])
        let decoded = try JSONDecoder().decode([AccessibilityCloudClient.Equipment].self, from: data)
        #expect(decoded == [full, minimal])
    }

    @Test func firstLaunchHasNoSnapshotUntilABuildLands() async throws {
        let url = tempCacheURL()
        let stub = BuildStub([[equipment(id: "101", isWorking: true)]])
        let catalog = EquipmentCatalog(cacheFileURL: url) { await stub.next() }

        #expect(await catalog.snapshot() == nil)
        let built = try #require(await catalog.all())
        #expect(built.map(\.id) == ["101"])
        #expect(await catalog.snapshot()?.map(\.id) == ["101"])
    }

    @Test func freshPersistedCatalogServesANewInstanceWithoutABuild() async throws {
        let url = tempCacheURL()
        let writerStub = BuildStub([[equipment(id: "101", isWorking: false)]])
        let writer = EquipmentCatalog(cacheFileURL: url) { await writerStub.next() }
        _ = await writer.all()

        // Fresh process, same container: the snapshot answers instantly and,
        // still inside the TTL, no rebuild fires.
        let readerStub = BuildStub([nil])
        let reader = EquipmentCatalog(cacheFileURL: url) { await readerStub.next() }
        let snapshot = try #require(await reader.snapshot())
        #expect(snapshot.map(\.id) == ["101"])
        #expect(snapshot.first?.isWorking == false)
        #expect(await readerStub.builds == 0)
    }

    @Test func staleSnapshotIsServedImmediatelyAndRevalidated() async throws {
        let url = tempCacheURL()
        let stub = BuildStub([
            [equipment(id: "101", isWorking: true)],
            [equipment(id: "101", isWorking: false)],
        ])
        // ttl 0: nothing is ever fresh — every snapshot revalidates.
        let catalog = EquipmentCatalog(ttl: 0, cacheFileURL: url) { await stub.next() }

        _ = await catalog.all()
        // Old data now, rebuild in the background …
        #expect(await catalog.snapshot()?.first?.isWorking == true)
        // … and all() joins that same shared rebuild.
        let refreshed = try #require(await catalog.all())
        #expect(refreshed.first?.isWorking == false)
        #expect(await stub.builds == 2)
    }

    // The widget extension reads what the app persisted and must never kick
    // off a build of its own — stale is fine there, a 30 s build is not.
    @Test func readOnlySnapshotServesStaleDataWithoutABuild() async throws {
        let url = tempCacheURL()
        let writerStub = BuildStub([[equipment(id: "101", isWorking: true)]])
        _ = await EquipmentCatalog(cacheFileURL: url) { await writerStub.next() }.all()

        let readerStub = BuildStub([[equipment(id: "101", isWorking: false)]])
        let reader = EquipmentCatalog(ttl: 0, cacheFileURL: url) { await readerStub.next() }
        #expect(await reader.snapshot(rebuildingIfStale: false)?.map(\.id) == ["101"])
        #expect(await readerStub.builds == 0)
        #expect(await EquipmentCatalog(ttl: 0, cacheFileURL: tempCacheURL()) { await readerStub.next() }
            .snapshot(rebuildingIfStale: false) == nil)
        #expect(await readerStub.builds == 0)
    }

    @Test func failedRebuildKeepsServingTheStaleCatalog() async throws {
        let url = tempCacheURL()
        let stub = BuildStub([[equipment(id: "101", isWorking: true)], nil])
        let catalog = EquipmentCatalog(ttl: 0, cacheFileURL: url) { await stub.next() }

        _ = await catalog.all()
        let stale = try #require(await catalog.all())
        #expect(stale.map(\.id) == ["101"])
    }

    @Test func corruptCacheFileIsIgnored() async {
        let url = tempCacheURL()
        try? Data("nonsense".utf8).write(to: url)
        let catalog = EquipmentCatalog(cacheFileURL: url) { await BuildStub([nil]).next() }
        #expect(await catalog.snapshot() == nil)
    }
}

// Seed-id favorites (created from a seed preview or the offline seed
// fallback) bridge to their live records via the operator inventory number
// and stay resolvable from the bundled seed until a catalog exists.
@Suite struct SeedFavoriteBridgeTests {
    private func seedRecord(
        id: String,
        number: Int?,
        source: String = "fasta"
    ) -> SeedCatalog.Record {
        SeedCatalog.Record(
            id: id, source: source, acId: nil, fastaEquipmentNumber: number,
            stationNumber: nil, brokenliftsStationId: nil, brokenliftsIndex: nil,
            stationName: "S Teststadt", description: "Straße ⟷ Bahnsteig",
            latitude: nil, longitude: nil, sourceName: "DB FaSta",
            organizationName: "DB", region: "berlin"
        )
    }

    private func liveEquipment(
        id: String,
        inventoryId: String? = nil,
        number: Int? = nil
    ) -> AccessibilityCloudClient.Equipment {
        AccessibilityCloudClient.Equipment(
            id: id, inventoryId: inventoryId, stationId: "900000001",
            stationName: "S Teststadt", description: "Straße ⟷ Bahnsteig",
            isWorking: true, lastUpdate: nil, fastaEquipmentNumber: number
        )
    }

    @Test func bridgesSeedIdToLiveIdViaInventoryNumber() {
        let map = EquipmentCatalog.bridgedLiveIds(
            for: ["fasta-42", "7"],
            seed: [seedRecord(id: "fasta-42", number: 42)],
            in: [liveEquipment(id: "456", inventoryId: "42")]
        )
        #expect(map == ["fasta-42": "456"])
    }

    // overlaid() gives matched live records the seed's number even when the
    // operator inventory id is a non-numeric string — the bridge must accept
    // both spellings.
    @Test func matchedOverlayRecordBridgesViaItsSeedNumber() {
        let map = EquipmentCatalog.bridgedLiveIds(
            for: ["z87ZFWJs5aB2seuYf"],
            seed: [seedRecord(id: "z87ZFWJs5aB2seuYf", number: 10_315_432)],
            in: [liveEquipment(id: "456", number: 10_315_432)]
        )
        #expect(map == ["z87ZFWJs5aB2seuYf": "456"])
    }

    // An appended seed record carries the number under its seed id — it must
    // not bridge to itself.
    @Test func appendedSeedRecordIsNoBridgeTarget() {
        let map = EquipmentCatalog.bridgedLiveIds(
            for: ["fasta-42"],
            seed: [seedRecord(id: "fasta-42", number: 42)],
            in: [liveEquipment(id: "fasta-42", number: 42)]
        )
        #expect(map.isEmpty)
    }

    @Test func unknownIdsAndMissingNumbersDoNotBridge() {
        let map = EquipmentCatalog.bridgedLiveIds(
            for: ["fasta-42", "brokenlifts-900009103-0"],
            seed: [seedRecord(id: "fasta-42", number: nil)],
            in: [liveEquipment(id: "456", inventoryId: "42")]
        )
        #expect(map.isEmpty)
    }

    @Test func seedFavoriteResolvesToItsLiveRecordOnceACatalogExists() async throws {
        let url = tempCacheURL()
        let stub = BuildStub([[liveEquipment(id: "456", inventoryId: "42")]])
        let catalog = EquipmentCatalog(
            cacheFileURL: url,
            seed: [seedRecord(id: "fasta-42", number: 42)]
        ) { await stub.next() }

        _ = await catalog.all()
        let resolved = await catalog.equipment(for: ["fasta-42"])
        #expect(resolved["fasta-42"]?.id == "456")
        #expect(resolved["fasta-42"]?.isWorking == true)
    }

    @Test func seedFavoriteWithoutAnyCatalogResolvesFromTheSeedUnknown() async {
        let url = tempCacheURL()
        let catalog = EquipmentCatalog(
            cacheFileURL: url,
            seed: [seedRecord(id: "fasta-42", number: 42)]
        ) { nil }

        let resolved = await catalog.equipment(for: ["fasta-42"])
        #expect(resolved["fasta-42"]?.id == "fasta-42")
        #expect(resolved["fasta-42"]?.isWorking == nil)
    }

    // An accessibilityCloud-source seed record next to live data is neither
    // appended by the overlay nor bridged (numbers differ) — the favorite
    // must still answer from the seed instead of failing every refresh.
    @Test func unbridgedSeedFavoriteNextToLiveDataFallsBackToTheSeed() async {
        let url = tempCacheURL()
        let stub = BuildStub([[liveEquipment(id: "456", inventoryId: "99")]])
        let catalog = EquipmentCatalog(
            cacheFileURL: url,
            seed: [seedRecord(id: "z87ZFWJs5aB2seuYf", number: 42, source: "accessibilityCloud")]
        ) { await stub.next() }

        _ = await catalog.all()
        let resolved = await catalog.equipment(for: ["z87ZFWJs5aB2seuYf"])
        #expect(resolved["z87ZFWJs5aB2seuYf"]?.id == "z87ZFWJs5aB2seuYf")
        #expect(resolved["z87ZFWJs5aB2seuYf"]?.isWorking == nil)
    }
}
