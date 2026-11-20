import Testing
import Foundation
@testable import HissiCore

// The Aufzugsstatus API client's pure half: parsing the /lifts and
// /stations/near responses (fixtures are real records, trimmed to the cases
// below), mapping them onto catalog records, the freshness rule, the id
// namespace and the dedup against the local catalog.
@Suite struct AufzugsstatusClientTests {
    private func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    // Shortly after the fixtures' fresh `last_seen` (18:08:28Z), well past
    // the stale one (17:30Z).
    private let now = AccessibilityCloudClient.date(from: "2026-11-20T18:10:00+00:00")!

    private func records() throws -> [AccessibilityCloudClient.Equipment] {
        let lifts = try #require(AufzugsstatusClient.parseLifts(try fixture("aufzugsstatus_lifts")))
        #expect(lifts.count == 10)
        return AufzugsstatusClient.equipment(from: lifts, now: now)
    }

    @Test func mapsLiftsOntoCatalogRecords() throws {
        let records = try records()
        let hamburg = try #require(records.first { $0.id == "fasta:10804843" })
        #expect(hamburg.stationName == "Hamburg Hbf")
        #expect(hamburg.stationId == "2514")
        #expect(hamburg.description == "zu Gleis 1/2 (S-Bahn)")
        #expect(hamburg.isWorking == true)
        // A working lift's "available" is no disruption reason.
        #expect(hamburg.stateExplanation == nil)
        #expect(hamburg.sourceName == "DB FaSta")
        #expect(hamburg.organizationName == "DB InfraGO")
        // Only DB records carry the FaSta equipment number, the key the
        // local catalog knows too.
        #expect(hamburg.inventoryId == "10804843")
        #expect(hamburg.fastaEquipmentNumber == 10_804_843)
        #expect(hamburg.latitude == 53.5532639)
        #expect(hamburg.lastUpdate == AccessibilityCloudClient.date(from: "2026-11-20T18:08:28+00:00"))
        #expect(hamburg.region == .national)

        let kvb = try #require(records.first { $0.id == "kvb:034-01" })
        #expect(kvb.stationId.isEmpty)
        #expect(kvb.inventoryId == nil)
        #expect(kvb.fastaEquipmentNumber == nil)
        #expect(kvb.sourceName == "KVB")
        #expect(kvb.organizationName == "KVB")
    }

    @Test func dropsExcludedFeedsAndNamelessStations() throws {
        let ids = Set(try records().map(\.id))
        // VBB feeds (accessibility.cloud's territory) and the OSM inventories
        // without a live feed stay out, so does the DB record whose station
        // has no name ("Bahnhof 962").
        #expect(!ids.contains { $0.hasPrefix("bvg:") })
        #expect(!ids.contains { $0.hasPrefix("osm-ch:") })
        #expect(!ids.contains("fasta:10818160"))
        #expect(ids.count == 7)
    }

    // The docs' freshness rule: ACTIVE holds only while the feed reported
    // within 15 minutes; INACTIVE is believed either way; UNKNOWN stays
    // unknown and keeps its explanation.
    @Test func appliesTheFreshnessRule() throws {
        let records = try records()
        let byId = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        #expect(byId["fasta:10804843"]?.isWorking == true)
        // ACTIVE, last seen 40 minutes ago: the feed went quiet, not the lift.
        #expect(byId["fasta:10804989"]?.isWorking == nil)
        #expect(byId["fasta:10455451"]?.isWorking == false)
        #expect(byId["fasta:10455451"]?.stateExplanation == "not available")
        #expect(byId["hvv:Master:11950-E"]?.isWorking == false)
        #expect(byId["hvv:Master:11950-E"]?.stateExplanation == nil)
        #expect(byId["fasta:10028019"]?.isWorking == nil)
        #expect(byId["fasta:10028019"]?.stateExplanation == "under construction")
    }

    @Test func freshnessRuleEdges() {
        let seen = now.addingTimeInterval(-AufzugsstatusClient.freshnessWindow)
        #expect(AufzugsstatusClient.isWorking(state: "ACTIVE", lastSeen: seen, now: now) == true)
        #expect(AufzugsstatusClient.isWorking(state: "ACTIVE", lastSeen: seen.addingTimeInterval(-1), now: now) == nil)
        #expect(AufzugsstatusClient.isWorking(state: "active", lastSeen: now, now: now) == true)
        #expect(AufzugsstatusClient.isWorking(state: "ACTIVE", lastSeen: nil, now: now) == nil)
        #expect(AufzugsstatusClient.isWorking(state: "INACTIVE", lastSeen: nil, now: now) == false)
        #expect(AufzugsstatusClient.isWorking(state: "UNKNOWN", lastSeen: now, now: now) == nil)
        // A new word must read "unbekannt", never "defekt" or "in Betrieb".
        #expect(AufzugsstatusClient.isWorking(state: "PARTIAL", lastSeen: now, now: now) == nil)
        #expect(AufzugsstatusClient.isWorking(state: nil, lastSeen: now, now: now) == nil)
    }

    // "source:…" is the API's namespace; everything the app ever stored as a
    // favorite id before (numeric, Mongo, seed ids with hyphens) is not.
    @Test func tellsNationalIdsFromLocalOnes() {
        #expect(AufzugsstatusClient.isNationalId("fasta:10804843"))
        #expect(AufzugsstatusClient.isNationalId("hvv:Master:11950-E"))
        #expect(AufzugsstatusClient.isNationalId("kvb:034-01"))
        #expect(AufzugsstatusClient.isNationalId("osm-ch:3858714670"))
        #expect(!AufzugsstatusClient.isNationalId("6225"))
        #expect(!AufzugsstatusClient.isNationalId("fasta-10466003"))
        #expect(!AufzugsstatusClient.isNationalId("brokenlifts-900009103-0"))
        #expect(!AufzugsstatusClient.isNationalId("z87ZFWJs5aB2seuYf"))
        #expect(!AufzugsstatusClient.isNationalId(""))
    }

    // The local catalog shadows a national DB record only where it can show
    // it: a record without a station name is invisible in search and nearby.
    @Test func dedupsAgainstTheSearchableLocalCatalog() throws {
        let local = [
            AccessibilityCloudClient.Equipment(
                id: "6225", inventoryId: "10455451", stationId: "900077106",
                stationName: "Sonnenallee (Berlin)", description: "zu Gleis 1/2",
                isWorking: true, lastUpdate: nil
            ),
            // Nationwide DB record the platform carries without a station.
            AccessibilityCloudClient.Equipment(
                id: "7000", inventoryId: "10804843", stationId: "",
                stationName: "", description: "zu Gleis 1/2 (S-Bahn)",
                isWorking: true, lastUpdate: nil
            ),
            // Seed-only record: the number lives in fastaEquipmentNumber.
            AccessibilityCloudClient.Equipment(
                id: "fasta-10594156", stationId: "4935", stationName: "Pinneberg",
                description: "PU Ausgang Süd", isWorking: nil, lastUpdate: nil,
                fastaEquipmentNumber: 10_594_156
            ),
        ]
        let known = AufzugsstatusClient.knownInventoryNumbers(in: local)
        #expect(known == ["10455451", "10594156"])

        let kept = AufzugsstatusClient.excludingKnown(try records(), knownInventoryNumbers: known)
        let ids = Set(kept.map(\.id))
        #expect(!ids.contains("fasta:10455451"))
        #expect(ids.contains("fasta:10804843"))
        // Non-DB records carry no inventory id and are never shadowed.
        #expect(ids.contains("kvb:034-01"))
        #expect(ids.contains("hvv:Master:11950-A"))
        #expect(AufzugsstatusClient.excludingKnown(kept, knownInventoryNumbers: []).count == kept.count)
    }

    @Test func sourceLabels() {
        #expect(AufzugsstatusClient.sourceLabel(for: "fasta") == "DB FaSta")
        #expect(AufzugsstatusClient.sourceLabel(for: "hvv") == "HVV")
        #expect(AufzugsstatusClient.sourceLabel(for: "vagn") == "VAG Nürnberg")
    }

    // MARK: - Nearby

    @Test func parsesNearbyStationsAndSpotsThePlaceholder() throws {
        let stations = try #require(AufzugsstatusClient.parseNearbyStations(try fixture("aufzugsstatus_near")))
        #expect(stations.count == 6)
        #expect(stations[0].name == "Hamburg Hbf")
        #expect(stations[0].stationNumber == 2514)
        #expect(stations[0].lifts == 8)
        // The API lists the nameless lifts of a station as "Bahnhof <n>"
        // next to the station itself.
        #expect(AufzugsstatusClient.isPlaceholderName(stations[1].name))
        #expect(!AufzugsstatusClient.isPlaceholderName("Bahnhof Zoo"))
        #expect(stations.filter { !AufzugsstatusClient.isPlaceholderName($0.name) }.count == 5)
    }

    // Lifts answered for a station: a name query is a substring match, so
    // only the station asked for is kept, and lifts without coordinates
    // (HVV) take the station's so they are placed and counted.
    @Test func placesLiftsAtTheirStation() throws {
        let lifts = try #require(AufzugsstatusClient.parseLifts(try fixture("aufzugsstatus_lifts")))
        let jungfernstieg = AufzugsstatusClient.NearbyStation(
            name: "Jungfernstieg", stationNumber: nil, lifts: 5, latitude: 53.5527, longitude: 9.9935
        )
        let placed = AufzugsstatusClient.placed(lifts, at: jungfernstieg)
        #expect(placed.map(\.id) == ["hvv:Master:11950-E", "hvv:Master:11950-A"])
        #expect(placed.allSatisfy { $0.latitude == 53.5527 && $0.longitude == 9.9935 })

        let hamburg = AufzugsstatusClient.NearbyStation(
            name: "hamburg hbf", stationNumber: 2514, lifts: 8, latitude: 53.5531, longitude: 10.007
        )
        let own = AufzugsstatusClient.placed(lifts, at: hamburg)
        #expect(own.count == 3)
        // Lifts with coordinates keep their own.
        #expect(own.first { $0.id == "fasta:10804843" }?.latitude == 53.5532639)
    }

    // The nearby rows come out of the same sort as the local ones, over the
    // true device coordinate — so the cut at walking distance holds even
    // though the server was asked with a coarsened position and a wider
    // radius.
    @Test func nearbyRowsFollowTheWalkingRadius() throws {
        let lifts = try #require(AufzugsstatusClient.parseLifts(try fixture("aufzugsstatus_lifts")))
        let equipment = AufzugsstatusClient.equipment(from: lifts, now: now)
        // Standing at Hamburg Hbf: Hamburg Hbf is in reach, Neumarkt (Köln),
        // Jungfernstieg (no coordinates) and Sonnenallee (Berlin) are not.
        let stations = NearbyStations.nearest(toLatitude: 53.5531, longitude: 10.0065, in: equipment)
        #expect(stations.map(\.name) == ["Hamburg Hbf"])
        let hamburg = try #require(stations.first)
        #expect(hamburg.total == 3)
        // One ACTIVE, one stale ACTIVE, one UNKNOWN under construction.
        #expect(hamburg.unknownCount == 2)
        #expect(hamburg.status == .unknown)
    }

    @Test func coarsensTheCoordinateToAKilometreCell() {
        #expect(AufzugsstatusClient.coarsened(53.55318) == 53.55)
        #expect(AufzugsstatusClient.coarsened(10.00616) == 10.01)
        #expect(AufzugsstatusClient.coarsened(-0.004) == 0)
        // The request radius covers the walking radius plus the rounding
        // error, so nothing in walking distance is cut server-side.
        let halfCellDiagonalMeters = NearbyStations.distanceMeters(53.55, 10.0, 53.555, 10.005)
        #expect(AufzugsstatusClient.nearbyRequestRadiusKm * 1000 >= NearbyStations.walkingRadiusMeters + halfCellDiagonalMeters)
    }
}
