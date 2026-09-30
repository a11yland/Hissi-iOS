import Testing
@testable import HissiCore

// The on-device sort behind the "In der Nähe" suggestions, and the status
// roll-up each row shows.
@Suite struct NearbyStationsTests {
    private func equipment(
        station: String,
        latitude: Double?,
        longitude: Double?,
        id: String? = nil,
        isWorking: Bool? = nil
    ) -> AccessibilityCloudClient.Equipment {
        AccessibilityCloudClient.Equipment(
            id: id ?? "\(station)-\(latitude ?? 0)",
            stationId: "1",
            stationName: station,
            description: "Aufzug",
            isWorking: isWorking,
            lastUpdate: nil,
            latitude: latitude,
            longitude: longitude
        )
    }

    // Alexanderplatz → Hackescher Markt is a known ~800 m hop; haversine
    // must land in that ballpark (city-scale accuracy is what matters).
    @Test func distanceIsMeterAccurateAtCityScale() {
        let meters = NearbyStations.distanceMeters(52.5219, 13.4132, 52.5225, 13.4021)
        #expect(meters > 600 && meters < 900)
    }

    @Test func sortsStationsByTheirClosestElevator() {
        let catalog = [
            equipment(station: "S Hackescher Markt", latitude: 52.5225, longitude: 13.4021),
            // Two elevators, the near one decides the station's distance.
            equipment(station: "S+U Alexanderplatz", latitude: 52.5219, longitude: 13.4132),
            equipment(station: "S+U Alexanderplatz", latitude: 52.5210, longitude: 13.4150),
            equipment(station: "S+U Jannowitzbrücke", latitude: 52.5152, longitude: 13.4185),
        ]
        // Standing on Alexanderplatz:
        let nearest = NearbyStations.nearest(toLatitude: 52.5219, longitude: 13.4132, in: catalog)
        #expect(nearest.map(\.name) == ["S+U Alexanderplatz", "S Hackescher Markt", "S+U Jannowitzbrücke"])
        #expect(nearest.first?.distanceMeters == 0)
    }

    @Test func skipsRecordsWithoutCoordinatesAndCapsAtLimit() {
        let catalog = [
            equipment(station: "Ohne Koordinaten", latitude: nil, longitude: nil),
            equipment(station: "A", latitude: 52.52, longitude: 13.41),
            equipment(station: "B", latitude: 52.523, longitude: 13.41),
            equipment(station: "C", latitude: 52.526, longitude: 13.41),
        ]
        let nearest = NearbyStations.nearest(toLatitude: 52.52, longitude: 13.41, in: catalog, limit: 2)
        #expect(nearest.map(\.name) == ["A", "B"])
        #expect(!nearest.contains { $0.name == "Ohne Koordinaten" })
    }

    // MARK: - Walking distance

    // "Nearby" is what the user can walk to: a station beyond the radius stays
    // out even when it is the closest one there is, and the station's closest
    // elevator is what has to be within reach.
    @Test func keepsOnlyStationsWithinWalkingDistance() {
        let catalog = [
            // ~800 m north: in.
            equipment(station: "S Nah", latitude: 52.5272, longitude: 13.41),
            // ~1.6 km north: out.
            equipment(station: "S Fern", latitude: 52.5344, longitude: 13.41),
            // Two elevators, the near one (~500 m) puts the station in reach.
            equipment(station: "S+U Zwei", latitude: 52.5245, longitude: 13.41),
            equipment(station: "S+U Zwei", latitude: 52.54, longitude: 13.41),
        ]
        let nearest = NearbyStations.nearest(toLatitude: 52.52, longitude: 13.41, in: catalog)
        #expect(nearest.map(\.name) == ["S+U Zwei", "S Nah"])
        #expect(nearest.allSatisfy { $0.distanceMeters <= NearbyStations.walkingRadiusMeters })
    }

    // Nothing within reach yields nothing — the nearest station in the region
    // is not a walk, and the UI says so instead of listing it.
    @Test func nothingWithinWalkingDistanceIsEmpty() {
        let catalog = [
            equipment(station: "S Fern", latitude: 52.5344, longitude: 13.41),
        ]
        #expect(NearbyStations.nearest(toLatitude: 52.52, longitude: 13.41, in: catalog).isEmpty)
        // The radius is a parameter, not a hidden constant.
        #expect(
            NearbyStations.nearest(toLatitude: 52.52, longitude: 13.41, in: catalog, withinMeters: 2_000)
                .map(\.name) == ["S Fern"]
        )
    }

    // The watch's first use re-derives the rows from the built catalog instead
    // of re-stating the seed rows (seed ids have no live counterpart to ask
    // for). Coordinates come from the seed either way, so the order must hold
    // — only statuses and elevator counts may change.
    @Test func rederivingFromTheBuiltCatalogKeepsTheOrder() {
        func seed(_ id: String, _ station: String, number: Int, latitude: Double) -> SeedCatalog.Record {
            SeedCatalog.Record(
                id: id, source: "fasta", acId: nil, fastaEquipmentNumber: number,
                stationNumber: nil, brokenliftsStationId: nil, brokenliftsIndex: nil,
                stationName: station, description: "Aufzug", latitude: latitude, longitude: 13.41,
                sourceName: "", organizationName: "", region: "berlin"
            )
        }
        let seedRecords = [
            seed("fasta-1", "S Nah", number: 1, latitude: 52.5245),
            seed("fasta-2", "S Weiter", number: 2, latitude: 52.5272),
        ]
        let before = NearbyStations.nearest(
            toLatitude: 52.52, longitude: 13.41,
            in: EquipmentCatalog.overlaid(live: [], seed: seedRecords)
        )
        #expect(before.map(\.name) == ["S Nah", "S Weiter"])
        #expect(before.allSatisfy { $0.status == .unknown })

        // The build knows both by inventory number, plus a lift the seed
        // never had at the nearer station.
        let live = [
            AccessibilityCloudClient.Equipment(
                id: "101", inventoryId: "1", stationId: "1", stationName: "S Nah",
                description: "Aufzug", isWorking: false, lastUpdate: nil
            ),
            AccessibilityCloudClient.Equipment(
                id: "102", inventoryId: "2", stationId: "2", stationName: "S Weiter",
                description: "Aufzug", isWorking: true, lastUpdate: nil
            ),
            AccessibilityCloudClient.Equipment(
                id: "103", stationId: "1", stationName: "S Nah",
                description: "Aufzug", isWorking: true, lastUpdate: nil
            ),
        ]
        let after = NearbyStations.nearest(
            toLatitude: 52.52, longitude: 13.41,
            in: EquipmentCatalog.overlaid(live: live, seed: seedRecords)
        )
        #expect(after.map(\.name) == before.map(\.name))
        #expect(after.map(\.distanceMeters) == before.map(\.distanceMeters))
        #expect(after[0].statusLabel == "1 von 2 außer Betrieb")
        #expect(after[1].status == .working)
    }

    // MARK: - Status roll-up

    // Broken outranks unknown outranks all-clear, and the ratio is what the
    // row says: "1 von 3" leaves the user an alternative.
    @Test func brokenOutranksUnknownAndShowsTheRatio() {
        let catalog = [
            equipment(station: "S+U Pankow", latitude: 52.56, longitude: 13.41, id: "1", isWorking: false),
            equipment(station: "S+U Pankow", latitude: 52.56, longitude: 13.41, id: "2", isWorking: nil),
            equipment(station: "S+U Pankow", latitude: 52.56, longitude: 13.41, id: "3", isWorking: true),
        ]
        let station = NearbyStations.nearest(toLatitude: 52.56, longitude: 13.41, in: catalog)[0]
        #expect(station.total == 3)
        #expect(station.brokenCount == 1)
        #expect(station.unknownCount == 1)
        #expect(station.status == .broken)
        #expect(station.statusLabel == "1 von 3 außer Betrieb")
    }

    // An elevator the seed has no coordinates for is still one of the lifts at
    // that station — it can't place the station, but it counts.
    @Test func elevatorsWithoutCoordinatesStillCountTowardsTheStatus() {
        let catalog = [
            equipment(station: "U Spittelmarkt", latitude: 52.51, longitude: 13.40, id: "1", isWorking: true),
            equipment(station: "U Spittelmarkt", latitude: nil, longitude: nil, id: "2", isWorking: false),
        ]
        let station = NearbyStations.nearest(toLatitude: 52.51, longitude: 13.40, in: catalog)[0]
        #expect(station.total == 2)
        #expect(station.statusLabel == "1 von 2 außer Betrieb")
    }

    // One lift, no ratio to give — "1 von 1 außer Betrieb" reads absurd.
    @Test func singleElevatorStationSpeaksTheElevatorVocabulary() {
        let catalog = [
            equipment(station: "S Grünau", latitude: 52.41, longitude: 13.58, id: "1", isWorking: false),
        ]
        let station = NearbyStations.nearest(toLatitude: 52.41, longitude: 13.58, in: catalog)[0]
        #expect(station.status == .broken)
        #expect(station.statusLabel == ElevatorStatus.broken.label)
    }

    // Statuses the catalog doesn't know (seed preview, offline) must never
    // round up to an all-clear.
    @Test func unknownStatusesNeverReadAsAllClear() {
        let allUnknown = [
            equipment(station: "S Fredersdorf", latitude: 52.53, longitude: 13.75, id: "1"),
            equipment(station: "S Fredersdorf", latitude: 52.53, longitude: 13.75, id: "2"),
        ]
        let station = NearbyStations.nearest(toLatitude: 52.53, longitude: 13.75, in: allUnknown)[0]
        #expect(station.status == .unknown)
        #expect(station.statusLabel == ElevatorStatus.unknown.label)

        let partial = allUnknown + [
            equipment(station: "S Fredersdorf", latitude: 52.53, longitude: 13.75, id: "3", isWorking: true),
        ]
        let mixed = NearbyStations.nearest(toLatitude: 52.53, longitude: 13.75, in: partial)[0]
        #expect(mixed.status == .unknown)
        #expect(mixed.statusLabel == "2 von 3 unbekannt")
    }

    @Test func allWorkingStationSaysSo() {
        let catalog = [
            equipment(station: "S Ostkreuz", latitude: 52.50, longitude: 13.46, id: "1", isWorking: true),
            equipment(station: "S Ostkreuz", latitude: 52.50, longitude: 13.46, id: "2", isWorking: true),
        ]
        let station = NearbyStations.nearest(toLatitude: 52.50, longitude: 13.46, in: catalog)[0]
        #expect(station.status == .working)
        #expect(station.statusLabel == "Alle in Betrieb")
    }

    // MARK: - Status refresh (phase 2)

    @Test func elevatorIdsCoverEveryShownStation() {
        let catalog = [
            equipment(station: "A", latitude: 52.52, longitude: 13.41, id: "1"),
            equipment(station: "A", latitude: nil, longitude: nil, id: "2"),
            equipment(station: "B", latitude: 52.523, longitude: 13.41, id: "3"),
            equipment(station: "C", latitude: 52.526, longitude: 13.41, id: "4"),
        ]
        let nearest = NearbyStations.nearest(toLatitude: 52.52, longitude: 13.41, in: catalog, limit: 2)
        #expect(NearbyStations.elevatorIds(of: nearest) == ["1", "2", "3"])
    }

    // The refresh may answer for only some of the ids (a failed fetch degrades
    // to the seed overlay). Those it doesn't answer keep what they had — and
    // nothing about the list's order or distances may move.
    @Test func restatedUpdatesStatusesWithoutMovingRows() {
        let catalog = [
            equipment(station: "A", latitude: 52.52, longitude: 13.41, id: "1", isWorking: true),
            equipment(station: "A", latitude: 52.52, longitude: 13.41, id: "2", isWorking: true),
            equipment(station: "B", latitude: 52.523, longitude: 13.41, id: "3", isWorking: true),
        ]
        let before = NearbyStations.nearest(toLatitude: 52.52, longitude: 13.41, in: catalog)
        #expect(before.map(\.name) == ["A", "B"])

        // "1" broke since the snapshot, "3" is still working, "2" unanswered.
        let fresh = [
            "1": equipment(station: "A", latitude: 52.52, longitude: 13.41, id: "1", isWorking: false),
            "3": equipment(station: "B", latitude: 52.523, longitude: 13.41, id: "3", isWorking: true),
        ]
        let after = NearbyStations.restated(before, with: fresh)

        #expect(after.map(\.name) == before.map(\.name))
        #expect(after.map(\.distanceMeters) == before.map(\.distanceMeters))
        #expect(after[0].status == .broken)
        #expect(after[0].statusLabel == "1 von 2 außer Betrieb")
        // Unanswered "2" kept its working status instead of falling to unknown.
        #expect(after[0].unknownCount == 0)
        #expect(after[1].status == .working)
    }

    // A bridged seed favorite resolves to a record with a different (live) id;
    // the station must keep addressing it by the id it asked for, or the next
    // refresh would no longer find it.
    @Test func restatedKeepsTheRequestedIds() {
        let catalog = [
            equipment(station: "A", latitude: 52.52, longitude: 13.41, id: "fasta-4711"),
        ]
        let before = NearbyStations.nearest(toLatitude: 52.52, longitude: 13.41, in: catalog)
        let fresh = [
            "fasta-4711": equipment(
                station: "A", latitude: 52.52, longitude: 13.41, id: "90210", isWorking: false
            ),
        ]
        let after = NearbyStations.restated(before, with: fresh)
        #expect(after[0].elevators.map(\.id) == ["fasta-4711"])
        #expect(after[0].status == .broken)
    }

    @Test func restatedWithNothingFreshLeavesTheStationsAlone() {
        let catalog = [
            equipment(station: "A", latitude: 52.52, longitude: 13.41, id: "1", isWorking: true),
        ]
        let before = NearbyStations.nearest(toLatitude: 52.52, longitude: 13.41, in: catalog)
        #expect(NearbyStations.restated(before, with: [:]) == before)
    }
}
