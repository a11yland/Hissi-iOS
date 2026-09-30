import Testing
import Foundation
@testable import HissiCore

@Suite struct TransitRegionTests {
    @Test func agsPrefixDecidesRegion() {
        #expect(TransitRegion.from(originalPlaceInfoId: "de:11000:900100015") == .berlin)
        #expect(TransitRegion.from(originalPlaceInfoId: "de:12054:900230999") == .brandenburg)
    }

    @Test func nonAgsIdsYieldNil() {
        // BVG records put the station name into originalPlaceInfoId.
        #expect(TransitRegion.from(originalPlaceInfoId: "S+U Rathaus Spandau (Berlin)") == nil)
        #expect(TransitRegion.from(originalPlaceInfoId: "") == nil)
        #expect(TransitRegion.from(originalPlaceInfoId: nil) == nil)
    }

    @Test func nameHeuristicCoversAllConventions() {
        #expect(TransitRegion.inferred(from: "S Adlershof (Berlin)") == .berlin)
        #expect(TransitRegion.inferred(from: "U Klosterstraße") == .berlin)      // BVG, no suffix
        #expect(TransitRegion.inferred(from: "S+U Pankow (Berlin)") == .berlin)
        #expect(TransitRegion.inferred(from: "Berlin Ostbahnhof") == .berlin)    // DB prefix
        #expect(TransitRegion.inferred(from: "Waßmannsdorf") == .brandenburg)
        #expect(TransitRegion.inferred(from: "Potsdam Hauptbahnhof") == .brandenburg)
    }
}

@Suite struct TransitNetworkTests {
    private let bvg = "BVG Elevators (2025)"

    @Test func sourceFeedsSettleUnambiguousRecords() {
        #expect(TransitNetwork.classify(
            description: "Prenzlauer Promenade ⟷ S-Bahnsteig Gl. 1/2",
            stationName: "S Pankow-Heinersdorf (Berlin)",
            sourceName: "VBB Anlagen (S-Bahn)"
        ) == .sBahn)
        #expect(TransitNetwork.classify(
            description: "Zugang Bahnsteig Gl. 11/12",
            stationName: "S+U Lichtenberg Bhf (Berlin)",
            sourceName: "VBB-Anlagen (DB Regio)"
        ) == .regional)
    }

    @Test func fastaFallsBackToStationPrefix() {
        #expect(TransitNetwork.classify(
            description: "zu Gleis 1", stationName: "S Mahlow", sourceName: "DB FaSta"
        ) == .sBahn)
        // Without station modes (seed-only records), unprefixed S-Bahn
        // stations still classify as regional.
        #expect(TransitNetwork.classify(
            description: "zu Gleis 2", stationName: "Waßmannsdorf", sourceName: "DB FaSta"
        ) == .regional)
    }

    // The stop place's transport modes settle what neither feed nor name
    // carries: DB records at unprefixed S-Bahn stations, and unmarked
    // elevators at single-network stations.
    @Test func stationModesSettleUnprefixedAndUnmarkedRecords() {
        #expect(TransitNetwork.classify(
            description: "zu Gleis 2", stationName: "Waßmannsdorf",
            sourceName: "DB FaSta", stationModes: [.sBahn]
        ) == .sBahn)
        // Mixed DB station without an "S " prefix stays regional.
        #expect(TransitNetwork.classify(
            description: "zu Gleis 2", stationName: "Königs Wusterhausen",
            sourceName: "DB FaSta", stationModes: [.sBahn, .regional]
        ) == .regional)
        // Unmarked elevator, no source: the station's single network wins.
        #expect(TransitNetwork.classify(
            description: "zu Gleis 1/1a", stationName: "Wittenberge, Bahnhof",
            sourceName: "", stationModes: [.regional]
        ) == .regional)
        // Multi-network station keeps the "Zugang" bucket for unmarked lifts.
        #expect(TransitNetwork.classify(
            description: "Straße ⟷ Zwischenebene",
            stationName: "S+U Rathaus Spandau (Berlin)",
            sourceName: "BVG Elevators (2025)", stationModes: [.sBahn, .uBahn]
        ) == .access)
    }

    @Test func transportModeIdsMapToNetworks() {
        #expect(TransitNetwork(transportModeId: 1) == .sBahn)
        #expect(TransitNetwork(transportModeId: 2) == .uBahn)
        #expect(TransitNetwork(transportModeId: 3) == .regional)
        #expect(TransitNetwork(transportModeId: 9) == nil)
    }

    // The BVG feed carries U- and S-platform elevators at S+U stations; the
    // description has to tell them apart (e.g. Pankow).
    @Test func descriptionSplitsBvgRecordsAtMixedStations() {
        #expect(TransitNetwork.classify(
            description: "Vorhalle ⟷ Bahnsteig U2",
            stationName: "S+U Pankow (Berlin)", sourceName: bvg
        ) == .uBahn)
        #expect(TransitNetwork.classify(
            description: "Vorhalle ⟷ Bahnsteig S-Bahn",
            stationName: "S+U Pankow (Berlin)", sourceName: bvg
        ) == .sBahn)
        #expect(TransitNetwork.classify(
            description: "Zwischenebene Klosterstraße (Süd) ⟷ Bahnsteig U7 Richtung Rudow",
            stationName: "S+U Rathaus Spandau (Berlin)", sourceName: bvg
        ) == .uBahn)
    }

    @Test func unmarkedElevatorsAtMixedStationsAreAccess() {
        #expect(TransitNetwork.classify(
            description: "Straße ⟷ Zwischenebene Klosterstraße (Süd)",
            stationName: "S+U Rathaus Spandau (Berlin)", sourceName: bvg
        ) == .access)
        // "Übergang S1" must not count as an S-Bahn platform marker.
        #expect(TransitNetwork.classify(
            description: "Straße Kuhligkshofstraße Übergang S1 ⟷ Zwischenebene",
            stationName: "S+U Rathaus Steglitz (Berlin)", sourceName: bvg
        ) == .access)
    }

    @Test func stationPrefixAndSourceCoverUnmarkedRecords() {
        #expect(TransitNetwork.classify(
            description: "Aufzug zwischen U-Bahnsteig und Zugang Klosterstraße",
            stationName: "U Klosterstraße", sourceName: "brokenlifts.org"
        ) == .uBahn)
        #expect(TransitNetwork.classify(
            description: "Straße ⟷ Bahnsteig",
            stationName: "U Vinetastr. (Berlin)", sourceName: bvg
        ) == .uBahn)
        // Renamed BVG station without a "U " prefix.
        #expect(TransitNetwork.classify(
            description: "Zwischenebene ⟷ Bahnsteig",
            stationName: "Anton-Wilhelm-Amo-Straße  (Berlin)", sourceName: bvg
        ) == .uBahn)
    }
}

@Suite struct SearchGroupingTests {
    private func equipment(
        id: String, station: String, description: String, source: String,
        region: TransitRegion? = nil
    ) -> AccessibilityCloudClient.Equipment {
        AccessibilityCloudClient.Equipment(
            id: id, stationId: "1", stationName: station, description: description,
            isWorking: true, lastUpdate: nil, sourceName: source, region: region
        )
    }

    private var pankowMixed: [AccessibilityCloudClient.Equipment] {
        [
            equipment(id: "u1", station: "S+U Pankow (Berlin)",
                      description: "Vorhalle ⟷ Bahnsteig U2",
                      source: "BVG Elevators (2025)", region: .berlin),
            equipment(id: "s1", station: "S+U Pankow (Berlin)",
                      description: "Vorhalle ⟷ Bahnsteig S-Bahn",
                      source: "BVG Elevators (2025)", region: .berlin),
            equipment(id: "b1", station: "Bernau, Bahnhof",
                      description: "Zugang Gleis 1",
                      source: "VBB-Anlagen (DB Regio)", region: .brandenburg),
        ]
    }

    // The detail view's targeted refresh flows back into the row: same
    // grouping, same order, one elevator swapped — id adoption included.
    @Test func replacingSwapsOneElevatorAndKeepsTheShape() throws {
        let regions = SearchGrouping.group(pankowMixed)
        let before = try #require(regions.first?.stations.first)
        let old = try #require(before.sections.flatMap(\.elevators).first { $0.id == "s1" })
        var fresh = MonitoredElevator(
            id: "4711", stationId: old.stationId, elevatorId: "4711",
            stationName: old.stationName, elevatorDescription: old.elevatorDescription,
            isWorking: false, lastChecked: Date()
        )
        fresh.stateExplanation = "Defekt"

        let after = SearchGrouping.replacing(regions, id: "s1", with: fresh)
        #expect(after.map(\.region) == regions.map(\.region))
        #expect(after.map { $0.stations.map(\.id) } == regions.map { $0.stations.map(\.id) })
        let station = try #require(after.first?.stations.first)
        #expect(station.sections.map(\.network) == before.sections.map(\.network))
        let ids = station.sections.flatMap(\.elevators).map(\.id)
        #expect(ids.contains("4711") && !ids.contains("s1") && ids.contains("u1"))
        let swapped = try #require(station.sections.flatMap(\.elevators).first { $0.id == "4711" })
        #expect(swapped.isWorking == false && swapped.stateExplanation == "Defekt")
        // Unknown id: nothing changes.
        #expect(SearchGrouping.replacing(regions, id: "nope", with: fresh) == regions)
    }

    @Test func splitsRegionsBerlinFirst() throws {
        let regions = SearchGrouping.group(pankowMixed)
        #expect(regions.map(\.region) == [.berlin, .brandenburg])
        #expect(regions[0].stations.map(\.station.name) == ["S+U Pankow (Berlin)"])
        #expect(regions[1].stations.map(\.station.name) == ["Bernau, Bahnhof"])
    }

    @Test func mixedStationSplitsIntoOrderedNetworkSections() throws {
        let regions = SearchGrouping.group(pankowMixed)
        let pankow = try #require(regions.first?.stations.first)
        #expect(pankow.networks == [.uBahn, .sBahn])
        #expect(pankow.sections[0].elevators.map(\.id) == ["u1"])
        #expect(pankow.sections[1].elevators.map(\.id) == ["s1"])
    }

    @Test func missingRegionFallsBackToNameHeuristic() throws {
        let regions = SearchGrouping.group([
            equipment(id: "k1", station: "U Klosterstraße",
                      description: "Aufzug zwischen U-Bahnsteig und Zugang Klosterstraße",
                      source: "brokenlifts.org"),
            equipment(id: "w1", station: "Waßmannsdorf",
                      description: "zu Gleis 2", source: "DB FaSta"),
        ])
        #expect(regions.map(\.region) == [.berlin, .brandenburg])
    }

    @Test func singleRegionYieldsSingleGroup() {
        let regions = SearchGrouping.group([pankowMixed[0], pankowMixed[1]])
        #expect(regions.count == 1)
        #expect(regions[0].region == .berlin)
    }
}
