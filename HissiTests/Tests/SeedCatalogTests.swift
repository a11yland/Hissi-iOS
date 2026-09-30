import Testing
import Foundation
@testable import HissiCore

private let seedJSON = Data("""
{
 "generatedAt": "2026-07-19T21:00:00Z",
 "elevators": [
  {
   "id": "g9DnAE6CioBKy6kbn",
   "source": "accessibilityCloud",
   "acId": "g9DnAE6CioBKy6kbn",
   "stationName": "S Pankow-Heinersdorf (Berlin)",
   "description": "Prenzlauer Promenade ⟷ S-Bahnsteig Gl. 1/2",
   "latitude": 52.577603,
   "longitude": 13.42909,
   "sourceName": "VBB Anlagen (S-Bahn)",
   "organizationName": "VBB",
   "fastaEquipmentNumber": 10906243,
   "region": "berlin"
  },
  {
   "id": "hugGa4c2AnzMaWWQu",
   "source": "accessibilityCloud",
   "acId": "hugGa4c2AnzMaWWQu",
   "stationName": "Waßmannsdorf",
   "description": "Waßmannsdorf zu Gleis 1",
   "latitude": null,
   "longitude": null,
   "sourceName": "VBB Anlagen (S-Bahn)",
   "organizationName": "VBB",
   "fastaEquipmentNumber": 10466002
  },
  {
   "id": "fasta-10466003",
   "source": "fasta",
   "fastaEquipmentNumber": 10466003,
   "stationNumber": 7723,
   "stationName": "Waßmannsdorf",
   "description": "zu Gleis 2",
   "latitude": 52.3683272,
   "longitude": 13.4637534,
   "sourceName": "DB FaSta",
   "organizationName": "DB InfraGO",
   "region": "brandenburg"
  },
  {
   "id": "brokenlifts-900009103-0",
   "source": "brokenlifts",
   "brokenliftsStationId": "900009103",
   "brokenliftsIndex": 0,
   "stationName": "U Seestr.",
   "description": "Aufzug zwischen U-Bahnsteig i. Ri. Alt-Tegel und Müllerstr.",
   "latitude": 52.550471,
   "longitude": 13.351966,
   "sourceName": "brokenlifts.org",
   "organizationName": "Berliner Verkehrsbetriebe (BVG)"
  }
 ]
}
""".utf8)

@Suite struct SeedCatalogTests {
    @Test func parsesAllRecordsWithOptionalFields() throws {
        let records = SeedCatalog.parse(seedJSON)
        #expect(records.count == 4)
        let heinersdorf = try #require(records.first { $0.id == "g9DnAE6CioBKy6kbn" })
        #expect(heinersdorf.fastaEquipmentNumber == 10906243)
        #expect(heinersdorf.stationNumber == nil)
        let fastaOnly = try #require(records.first { $0.source == "fasta" })
        #expect(fastaOnly.stationNumber == 7723)
        let brokenlifts = try #require(records.first { $0.source == "brokenlifts" })
        #expect(brokenlifts.brokenliftsStationId == "900009103")
        #expect(brokenlifts.brokenliftsIndex == 0)
    }

    @Test func unparseableDataYieldsEmpty() {
        #expect(SeedCatalog.parse(Data("nonsense".utf8)).isEmpty)
    }
}

@Suite struct CatalogOverlayTests {
    private var seed: [SeedCatalog.Record] { SeedCatalog.parse(seedJSON) }

    private func liveEquipment(
        id: String = "6225",
        inventoryId: String? = "10906243",
        stationName: String = "Pankow-Heinersdorf (Berlin)"
    ) -> AccessibilityCloudClient.Equipment {
        AccessibilityCloudClient.Equipment(
            id: id,
            inventoryId: inventoryId,
            stationId: "900130011",
            stationName: stationName,
            description: "Straßenland ⟷ Gleis 1/2 (S-Bahn)",
            isWorking: true,
            lastUpdate: Date()
        )
    }

    // The operator inventory number (= the seed's FaSta equipment number)
    // matches live records to the seed, which backfills what the API doesn't
    // serve — names, coordinates, region.
    @Test func inventoryNumberMatchBackfillsSeedMetadata() throws {
        let merged = EquipmentCatalog.overlaid(live: [liveEquipment()], seed: seed)
        let record = try #require(merged.first { $0.id == "6225" })
        #expect(record.fastaEquipmentNumber == 10906243)
        #expect(record.sourceName == "VBB Anlagen (S-Bahn)")
        #expect(record.latitude == 52.577603)
        #expect(record.region == .berlin)
        #expect(record.isWorking == true)
        // The matched seed record must not reappear as a duplicate.
        #expect(!merged.contains { $0.id == "g9DnAE6CioBKy6kbn" })
        #expect(merged.count == 3) // live + fasta and brokenlifts gap records
    }

    @Test func emptyStationNameIsBackfilledFromSeed() throws {
        let merged = EquipmentCatalog.overlaid(
            live: [liveEquipment(id: "5034", inventoryId: "10466002", stationName: "")],
            seed: seed
        )
        let record = try #require(merged.first { $0.id == "5034" })
        #expect(record.stationName == "Waßmannsdorf")
    }

    // A "fasta" record whose inventory number appears live is answered by the
    // API — it must not be appended on top.
    @Test func fastaRecordMatchedByInventoryIsNotAppended() throws {
        let live = liveEquipment(id: "4972", inventoryId: "10466003", stationName: "Waßmannsdorf")
        let merged = EquipmentCatalog.overlaid(live: [live], seed: seed)
        #expect(!merged.contains { $0.id == "fasta-10466003" })
        #expect(merged.first { $0.id == "4972" }?.fastaEquipmentNumber == 10466003)
    }

    // Seed records the live catalog does not answer for stay searchable with
    // unknown status: "fasta" records missing upstream, "brokenlifts" records
    // while their whole station is absent. Unmatched accessibilityCloud
    // records must not duplicate live elevators.
    @Test func unansweredGapRecordsAreAppendedWithUnknownStatus() throws {
        let merged = EquipmentCatalog.overlaid(live: [liveEquipment()], seed: seed)
        let fastaOnly = try #require(merged.first { $0.id == "fasta-10466003" })
        #expect(fastaOnly.isWorking == nil)
        #expect(fastaOnly.stationId == "7723")
        #expect(fastaOnly.region == .brandenburg)
        // Live catalog has no station 900009103 ⇒ the brokenlifts record fills
        // the gap… (see next test for the covered-station case)
        #expect(merged.contains { $0.id == "brokenlifts-900009103-0" })
        #expect(!merged.contains { $0.id == "hugGa4c2AnzMaWWQu" })
    }

    @Test func brokenliftsRecordAtLiveStationIsDropped() {
        let seestrasse = AccessibilityCloudClient.Equipment(
            id: "6743",
            stationId: "900009103",
            stationName: "Seestraße (Berlin)",
            description: "Straße ⟷ U6 (→ Alt-Tegel)",
            isWorking: true,
            lastUpdate: Date()
        )
        let merged = EquipmentCatalog.overlaid(live: [seestrasse], seed: seed)
        // The station is live — a stale seed record would just sit next to
        // the real elevator.
        #expect(!merged.contains { $0.id == "brokenlifts-900009103-0" })
    }

    // The inventory number goes stale upstream (~30 of the seed's numbers,
    // e.g. U Spittelmarkt) and thousands of live records have no seed
    // counterpart at all. Since the API serves neither coordinates nor
    // source/operator names, such a record would lose its map and both name
    // rows — the seed records of the same station answer for it.
    @Test func unmatchedRecordIsBackfilledFromItsStation() throws {
        let merged = EquipmentCatalog.overlaid(
            live: [liveEquipment(id: "9001", inventoryId: "5279")],
            seed: seed
        )
        let record = try #require(merged.first { $0.id == "9001" })
        #expect(record.latitude == 52.577603)
        #expect(record.longitude == 13.42909)
        #expect(record.sourceName == "VBB Anlagen (S-Bahn)")
        #expect(record.organizationName == "VBB")
        #expect(record.region == .berlin)
        // The station answers for metadata, never for identity: the number
        // is what favorites bridge on.
        #expect(record.fastaEquipmentNumber == nil)
        // …and the seed record it borrowed from stays a match for its own
        // live record, not a duplicate.
        #expect(!merged.contains { $0.id == "g9DnAE6CioBKy6kbn" })
    }

    // Waßmannsdorf carries a VBB and a DB FaSta record — who runs this lift
    // is genuinely unknown, so those rows stay empty. The coordinates are a
    // station property and fill regardless.
    @Test func ambiguousStationLeavesSourceAndOperatorEmpty() throws {
        let merged = EquipmentCatalog.overlaid(
            live: [liveEquipment(id: "9002", inventoryId: "5279", stationName: "Waßmannsdorf")],
            seed: seed
        )
        let record = try #require(merged.first { $0.id == "9002" })
        #expect(record.latitude == 52.3683272)
        #expect(record.sourceName.isEmpty)
        #expect(record.organizationName.isEmpty)
        #expect(record.region == .brandenburg)
    }

    // A matched seed record can itself carry no coordinates — its siblings
    // at the same station do.
    @Test func matchedRecordWithoutSeedCoordinatesFallsBackToItsStation() throws {
        let merged = EquipmentCatalog.overlaid(
            live: [liveEquipment(id: "5034", inventoryId: "10466002", stationName: "Waßmannsdorf")],
            seed: seed
        )
        let record = try #require(merged.first { $0.id == "5034" })
        #expect(record.latitude == 52.3683272)
        // The match itself named the source — no ambiguity to resolve.
        #expect(record.sourceName == "VBB Anlagen (S-Bahn)")
    }

    @Test func stationFallbackNeverReachesAcrossStations() throws {
        let merged = EquipmentCatalog.overlaid(
            live: [liveEquipment(id: "9003", inventoryId: nil, stationName: "Ostkreuz (Berlin)")],
            seed: seed
        )
        let record = try #require(merged.first { $0.id == "9003" })
        #expect(record.latitude == nil)
        #expect(record.sourceName.isEmpty)
        #expect(record.region == nil)
    }

    // The two datasets differ by the network prefix; everything else must
    // keep stations apart.
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

    @Test func offlineFallbackServesWholeSeed() {
        let merged = EquipmentCatalog.overlaid(live: [], seed: seed)
        #expect(merged.count == 4)
        #expect(merged.allSatisfy { $0.isWorking == nil })
        // Seeds from before the region field existed decode to nil.
        #expect(merged.first { $0.id == "brokenlifts-900009103-0" }?.region == nil)
    }
}
