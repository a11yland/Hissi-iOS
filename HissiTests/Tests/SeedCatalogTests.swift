import Testing
import Foundation
@testable import HissiCore

private let seedJSON = Data("""
{
"version":2,
"generatedAt":"2026-11-21T20:00:00Z",
"elevators":[
 {"id":"6696","inventoryId":"5279","stationId":"900130002","stationName":"Pankow (Berlin)","stationModes":[1,2],"region":"berlin","description":"Vorhalle ↔ Bahnsteig U2","latitude":52.567,"longitude":13.412,"sourceName":"BVG","organizationName":"Berliner Verkehrsbetriebe (BVG)"},
 {"id":"6697","stationId":"900130002","stationName":"Pankow (Berlin)","stationModes":[1,2],"region":"berlin","description":"Vorhalle ↔ S-Bahnsteig","sourceName":"BVG","organizationName":"Berliner Verkehrsbetriebe (BVG)"},
 {"id":"3910","inventoryId":"10855569","stationId":"name:Dinslaken Bahnhof","stationName":"Dinslaken Bahnhof","stationModes":[],"region":"nordrhein-westfalen","description":"→ Bahnsteig 2","latitude":51.567681,"longitude":6.738101,"sourceName":"DB FaSta","organizationName":"DB InfraGO"},
 {"id":"4011","stationId":"name:Wernau (N)","stationName":"Wernau (N)","description":"→ Gleis 1"}
],
"stations":[
 {"stationId":"900130002","dhid":"de:11000:900130002","name":"Pankow (Berlin)","region":"berlin","latitude":52.5671,"longitude":13.4121},
 {"stationId":"name:Wernau (N)","name":"Wernau (N)","region":"baden-wuerttemberg","latitude":48.6890,"longitude":9.4160}
],
"legacyIds":{
 "fasta-10855569":"3910",
 "z87ZFWJs5aB2seuYf":"6696"
}
}
""".utf8)

@Suite struct SeedCatalogParsingTests {
    @Test func parsesAllRecordsWithOptionalFields() throws {
        let records = SeedCatalog.parse(seedJSON)
        #expect(records.count == 4)
        let pankow = try #require(records.first)
        #expect(pankow.id == "6696")
        #expect(pankow.inventoryId == "5279")
        #expect(pankow.networks == [.sBahn, .uBahn])
        #expect(pankow.transitRegion == .berlin)
        // Missing fields decode to their empty values.
        let bare = try #require(records.last)
        #expect(bare.inventoryId == nil)
        #expect(bare.stationModes.isEmpty)
        #expect(bare.region == nil)
        #expect(bare.latitude == nil)
        #expect(bare.sourceName.isEmpty)
    }

    @Test func parsesStationsAndLegacyIds() {
        let stations = SeedCatalog.parseStations(seedJSON)
        #expect(stations.map(\.stationId) == ["900130002", "name:Wernau (N)"])
        #expect(stations[1].dhid == nil)
        #expect(SeedCatalog.parseLegacyIds(seedJSON) == ["fasta-10855569": "3910", "z87ZFWJs5aB2seuYf": "6696"])
    }

    @Test func unparseableDataYieldsEmpty() {
        #expect(SeedCatalog.parse(Data("nonsense".utf8)).isEmpty)
        #expect(SeedCatalog.parseStations(Data("{}".utf8)).isEmpty)
        #expect(SeedCatalog.parseLegacyIds(Data("{}".utf8)).isEmpty)
    }

    // The bundled seed itself: live ids only, every record at a station, and
    // every station known to the coordinate list.
    @Test func bundledSeedIsConsistent() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Shared/Resources/seed-catalog.json"))
        let records = SeedCatalog.parse(data)
        let stations = Set(SeedCatalog.parseStations(data).map(\.stationId))
        #expect(records.count > 1000)
        #expect(records.allSatisfy { ElevatorSource(id: $0.id).isLive })
        #expect(Set(records.map(\.id)).count == records.count)
        #expect(records.allSatisfy { !$0.stationName.isEmpty && stations.contains($0.stationId) })
        #expect(records.allSatisfy { $0.transitRegion != nil })
        let ids = Set(records.map(\.id))
        #expect(SeedCatalog.parseLegacyIds(data).values.allSatisfy { ids.contains($0) })
    }
}

@Suite struct SeedOverlayTests {
    private let seed = SeedCatalog.parse(seedJSON)
    private let stations = SeedCatalog.parseStations(seedJSON)

    private func live(
        id: String,
        stationId: String = "",
        stationName: String = "",
        description: String = "",
        latitude: Double? = nil,
        longitude: Double? = nil
    ) -> AccessibilityCloudClient.Equipment {
        AccessibilityCloudClient.Equipment(
            id: id, inventoryId: nil, stationId: stationId, stationName: stationName,
            description: description, isWorking: true, lastUpdate: Date(),
            latitude: latitude, longitude: longitude
        )
    }

    // An elevator upstream hasn't linked to a stop place arrives without a
    // station — the seed's (assigned) station makes it searchable.
    @Test func unlinkedLiveRecordTakesTheSeedStation() throws {
        let merged = EquipmentCatalog.overlaid(
            live: [live(id: "3910", description: "→ Bahnsteig 2", latitude: 51.5, longitude: 6.7)],
            seed: seed, stations: stations
        )
        let record = try #require(merged.first)
        #expect(record.stationId == "name:Dinslaken Bahnhof")
        #expect(record.stationName == "Dinslaken Bahnhof")
        #expect(record.region == .nordrheinWestfalen)
        #expect(record.sourceName == "DB FaSta")
        #expect(record.organizationName == "DB InfraGO")
        #expect(record.inventoryId == "10855569")
        // Live wins where it has a value.
        #expect(record.latitude == 51.5)
        #expect(record.isWorking == true)
    }

    // A linked live record keeps its own station; the seed only fills the
    // rest.
    @Test func linkedLiveRecordKeepsItsStation() throws {
        let merged = EquipmentCatalog.overlaid(
            live: [live(id: "6696", stationId: "900130002", stationName: "Pankow (Berlin)",
                        description: "Vorhalle ↔ Bahnsteig U2")],
            seed: seed, stations: stations
        )
        let record = try #require(merged.first)
        #expect(record.stationName == "Pankow (Berlin)")
        #expect(record.stationNetworks == [.sBahn, .uBahn])
        #expect(record.latitude == 52.567)
        #expect(record.sourceName == "BVG")
    }

    // With live data, a seed record live doesn't answer for is gone upstream
    // and stays out — no duplicates, no ghosts.
    @Test func seedRecordsMissingLiveAreNotAppended() {
        let merged = EquipmentCatalog.overlaid(live: [live(id: "3910")], seed: seed, stations: stations)
        #expect(merged.map(\.id) == ["3910"])
    }

    @Test func offlineFallbackServesWholeSeedUnknown() {
        let merged = EquipmentCatalog.overlaid(live: [], seed: seed, stations: stations)
        #expect(merged.map(\.id) == ["6696", "6697", "3910", "4011"])
        #expect(merged.allSatisfy { $0.isWorking == nil })
    }

    // No centroid: the station's coordinate (and region) from the list.
    @Test func stationListPlacesRecordsWithoutCoordinates() throws {
        let merged = EquipmentCatalog.overlaid(live: [], seed: seed, stations: stations)
        let pankowS = try #require(merged.first { $0.id == "6697" })
        #expect(pankowS.latitude == 52.5671)
        let wernau = try #require(merged.first { $0.id == "4011" })
        #expect(wernau.latitude == 48.6890)
        #expect(wernau.region == .badenWuerttemberg)
    }

    // An elevator added upstream after the generation: its station's seed
    // records answer for coordinates, region and the unanimous operator.
    @Test func unknownLiveRecordIsBackfilledFromItsStation() throws {
        let merged = EquipmentCatalog.overlaid(
            live: [live(id: "9001", stationId: "900130002", stationName: "Pankow (Berlin)")],
            seed: seed, stations: stations
        )
        let record = try #require(merged.first)
        #expect(record.latitude == 52.567)
        #expect(record.region == .berlin)
        #expect(record.sourceName == "BVG")
        #expect(record.organizationName == "Berliner Verkehrsbetriebe (BVG)")
    }

    @Test func stationFallbackNeverReachesAcrossStations() throws {
        let merged = EquipmentCatalog.overlaid(
            live: [live(id: "9003", stationName: "Ostkreuz (Berlin)")],
            seed: seed, stations: stations
        )
        let record = try #require(merged.first)
        #expect(record.latitude == nil)
        #expect(record.sourceName.isEmpty)
        #expect(record.region == nil)
    }

    // Station names differ by the network prefix between operator feeds;
    // everything else must keep stations apart.
    @Test func stationKeyFoldsOnlyTheNetworkPrefix() {
        #expect(EquipmentCatalog.stationKey("U Spittelmarkt (Berlin)")
            == EquipmentCatalog.stationKey("Spittelmarkt (Berlin)"))
        #expect(EquipmentCatalog.stationKey("S+U Pankow (Berlin)")
            == EquipmentCatalog.stationKey("Pankow (Berlin)"))
        #expect(EquipmentCatalog.stationKey("S Ostkreuz (Berlin)")
            == EquipmentCatalog.stationKey("ostkreuz (berlin)"))
        #expect(EquipmentCatalog.stationKey("Pankow (Berlin)")
            != EquipmentCatalog.stationKey("Pankow-Heinersdorf (Berlin)"))
        #expect(EquipmentCatalog.stationKey("Ostkreuz")
            != EquipmentCatalog.stationKey("Ostkreuz (Berlin)"))
        #expect(EquipmentCatalog.stationKey("").isEmpty)
    }
}
