import Testing
import Foundation
@testable import HissiCore

private let nationalJSON = Data("""
{
 "generatedAt": "2026-11-20",
 "source": "Aufzugsstatus API",
 "stations": [
  {"stationNumber": 2514, "name": "Hamburg Hbf", "latitude": 53.55316, "longitude": 10.00705,
   "lifts": [10028019, 10028022, 10804843, 10804989]},
  {"stationNumber": 4935, "name": "Pinneberg", "latitude": 53.65503, "longitude": 9.7976,
   "lifts": [10594142, 10594143, 10594156]},
  {"stationNumber": 962, "name": "Buir", "lifts": [10818160]}
 ]
}
""".utf8)

// The bundled national station list and the overlay step that names the
// nameless nationwide DB records of accessibility.cloud from it.
@Suite struct NationalStationsTests {
    private let stations = NationalStations.parse(nationalJSON)

    @Test func parsesStationsAndIndexesTheirLifts() {
        #expect(stations.map(\.stationNumber) == [2514, 4935, 962])
        #expect(stations[0].lifts.count == 4)
        // A station none of whose lifts the API places carries no coordinate.
        #expect(stations[2].latitude == nil)
        let byLift = NationalStations.byLift(stations)
        #expect(byLift["10804843"]?.name == "Hamburg Hbf")
        #expect(byLift["10594156"]?.stationNumber == 4935)
        #expect(byLift["1"] == nil)
        #expect(NationalStations.parse(Data("nonsense".utf8)).isEmpty)
    }

    private func nameless(id: String, inventoryId: String, latitude: Double? = nil) -> AccessibilityCloudClient.Equipment {
        AccessibilityCloudClient.Equipment(
            id: id, inventoryId: inventoryId, stationId: "", stationName: "",
            description: "zu Gleis 1/2 (S-Bahn)", isWorking: true, lastUpdate: nil,
            latitude: latitude, longitude: latitude.map { _ in 10.0077 }
        )
    }

    @Test func namesNamelessDBRecordsFromTheList() {
        let byLift = NationalStations.byLift(stations)
        let named = EquipmentCatalog.nationalNamed(nameless(id: "7000", inventoryId: "10804843"), from: byLift)
        #expect(named.stationName == "Hamburg Hbf")
        #expect(named.stationId == "2514")
        #expect(named.region == .national)
        #expect(named.sourceName == "DB FaSta")
        #expect(named.organizationName == "DB InfraGO")
        #expect(named.fastaEquipmentNumber == 10_804_843)
        // The station's coordinate only where the record carries none.
        #expect(named.latitude == 53.55316)
        let placed = EquipmentCatalog.nationalNamed(nameless(id: "7001", inventoryId: "10804989", latitude: 53.5531808), from: byLift)
        #expect(placed.latitude == 53.5531808)
        // The record's own identity and status are untouched.
        #expect(named.id == "7000")
        #expect(named.isWorking == true)
        #expect(named.description == "zu Gleis 1/2 (S-Bahn)")
    }

    @Test func leavesNamedRecordsAndUnknownNumbersAlone() {
        let byLift = NationalStations.byLift(stations)
        // A VBB record (stop-place linked) keeps its name and region.
        let berlin = AccessibilityCloudClient.Equipment(
            id: "6225", inventoryId: "10804843", stationId: "900077106", stationName: "Sonnenallee (Berlin)",
            description: "zu Gleis 1/2", isWorking: true, lastUpdate: nil, region: .berlin
        )
        #expect(EquipmentCatalog.nationalNamed(berlin, from: byLift) == berlin)
        // A number the list doesn't know stays nameless (and invisible)
        // rather than guessed.
        let unknown = nameless(id: "7002", inventoryId: "99")
        #expect(EquipmentCatalog.nationalNamed(unknown, from: byLift) == unknown)
        #expect(EquipmentCatalog.nationalNamed(unknown, from: [:]) == unknown)
    }

    // The overlay as a whole: a nameless DB record comes out named, the
    // national API's copy of the same elevator is then a known one.
    @Test func overlaidCatalogNamesAndTheSearchFindsIt() {
        let live = [nameless(id: "7000", inventoryId: "10804843"), nameless(id: "7003", inventoryId: "10594156")]
        let catalog = EquipmentCatalog.overlaid(live: live, seed: [], stations: [], national: stations)
        #expect(catalog.map(\.stationName) == ["Hamburg Hbf", "Pinneberg"])
        #expect(catalog.allSatisfy { $0.region == .national })
        #expect(AufzugsstatusClient.knownInventoryNumbers(in: catalog) == ["10804843", "10594156"])
        let grouped = SearchGrouping.group(catalog)
        #expect(grouped.map(\.region) == [.national])
        #expect(grouped[0].stations.map(\.station.name) == ["Hamburg Hbf", "Pinneberg"])
    }

    // The nearby gate: the national API is asked only while no VBB station
    // is in walking distance — a local DB station beyond the VBB is no
    // reason not to ask (its city-operator neighbours are not local).
    @Test func nationalLookupOnlyWithoutAVBBStationInReach() {
        let hamburg = EquipmentCatalog.nationalNamed(nameless(id: "7000", inventoryId: "10804843"), from: NationalStations.byLift(stations))
        let berlin = AccessibilityCloudClient.Equipment(
            id: "6225", stationId: "900077106", stationName: "Sonnenallee (Berlin)",
            description: "zu Gleis 1/2", isWorking: true, lastUpdate: nil,
            latitude: 52.4727, longitude: 13.4555, region: .berlin
        )
        // Seed-only VBB record without a region counts as VBB too.
        let brandenburg = AccessibilityCloudClient.Equipment(
            id: "fasta-1", stationId: "1", stationName: "Waßmannsdorf",
            description: "zu Gleis 2", isWorking: nil, lastUpdate: nil,
            latitude: 52.3645, longitude: 13.4651
        )
        let catalog = [hamburg, berlin, brandenburg]
        #expect(AufzugsstatusClient.needsNationalLookup(latitude: 53.5531, longitude: 10.0065, in: catalog))
        #expect(!AufzugsstatusClient.needsNationalLookup(latitude: 52.4727, longitude: 13.4555, in: catalog))
        #expect(!AufzugsstatusClient.needsNationalLookup(latitude: 52.3645, longitude: 13.4651, in: catalog))
        // Nowhere near anything: ask.
        #expect(AufzugsstatusClient.needsNationalLookup(latitude: 50.9, longitude: 6.95, in: catalog))
        #expect(AufzugsstatusClient.needsNationalLookup(latitude: 52.4727, longitude: 13.4555, in: []))
    }
}
