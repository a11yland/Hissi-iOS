import Foundation

#if DEBUG
// The catalog DemoMode serves instead of the API: every bundled seed record
// as a live record with a numeric id and a fixed status — mostly working, a
// few curated disruptions at stations the screenshots show. Derived from the
// seed rather than written by hand so search and nearby look like the real
// thing, and so the seed overlay matches every record (via the inventory
// number, or the station for the brokenlifts records) instead of appending
// status-unknown duplicates. Dates are relative to `now`: fixed dates would
// drift into "vor 3 Tagen" and, after two weeks, the stale-data warning.
// Pure, unit-tested.
nonisolated enum DemoFixtures {
    typealias Equipment = AccessibilityCloudClient.Equipment

    struct Pick: Equatable {
        let station: String
        let description: String

        func matches(_ record: SeedCatalog.Record) -> Bool {
            record.stationName.contains(station) && record.description.contains(description)
        }
    }

    static let broken = [
        Pick(station: "Alexanderplatz", description: "Bahnsteig U8 ⟷ Bahnhofspassage"),
        Pick(station: "Hackescher Markt", description: "S-Bahnsteig"),
    ]
    static let unknown = [
        Pick(station: "Schillingstr", description: "Straße ⟷ Bahnsteig"),
    ]
    // The favorites a screenshot run starts with, newest first.
    static let favoritePicks = [
        Pick(station: "Alexanderplatz", description: "Straße ⟷ Bahnsteig U2"),
        Pick(station: "Alexanderplatz", description: "Bahnsteig U8 ⟷ Bahnhofspassage"),
        Pick(station: "S+U Berlin Hauptbahnhof", description: "Straße ⟷ Zwischenebene ⟷ Bahnsteig U5"),
        Pick(station: "S+U Pankow", description: "Vorhalle ⟷ Bahnsteig U2"),
    ]

    static let firstId = 900_000

    static func catalog(
        seed: [SeedCatalog.Record] = SeedCatalog.records,
        now: Date = Date(),
        language: String = AccessibilityCloudClient.requestLocale(
            appLocalization: Bundle.main.preferredLocalizations.first
        )
    ) -> [Equipment] {
        // Each pick names one elevator: its first match.
        let firstMatch = { (picks: [Pick]) in Set(picks.compactMap { pick in seed.firstIndex(where: pick.matches) }) }
        let brokenIndices = firstMatch(broken), unknownIndices = firstMatch(unknown)
        var inventoryIds = Set<Int>()
        return seed.enumerated().compactMap { index, record in
            // A few seed records share an inventory number; the overlay
            // matches only the first and adds the other back itself
            // (status unknown, as with the live catalog).
            if let number = record.fastaEquipmentNumber, !inventoryIds.insert(number).inserted { return nil }
            let isBroken = brokenIndices.contains(index)
            let isUnknown = unknownIndices.contains(index)
            // Spread the "Stand" times over the last three hours; a
            // disruption is older than that.
            let minutesAgo = isBroken ? 26 * 60 : 8 + (index * 37) % 170
            return Equipment(
                id: String(firstId + index),
                inventoryId: record.fastaEquipmentNumber.map(String.init),
                stationId: record.brokenliftsStationId ?? record.stationNumber.map(String.init) ?? "",
                stationName: record.stationName,
                description: record.description,
                isWorking: isUnknown ? nil : !isBroken,
                lastUpdate: isUnknown ? nil : now.addingTimeInterval(-Double(minutesAgo) * 60),
                stateExplanation: isBroken ? explanation(language) : nil,
                latitude: record.latitude,
                longitude: record.longitude,
                region: record.region.flatMap(TransitRegion.init(rawValue:))
            )
        }
    }

    static func favorites(from catalog: [Equipment], now: Date = Date()) -> [MonitoredElevator] {
        favoritePicks.enumerated().compactMap { offset, pick in
            guard let equipment = catalog.first(where: {
                $0.stationName.contains(pick.station) && $0.description.contains(pick.description)
            }) else { return nil }
            var elevator = MonitoredElevator(
                id: equipment.id,
                stationId: equipment.stationId,
                elevatorId: equipment.id,
                stationName: equipment.stationName,
                elevatorDescription: equipment.description,
                isWorking: equipment.isWorking,
                lastChecked: now,
                lastUpdated: equipment.lastUpdate,
                stateExplanation: equipment.stateExplanation,
                latitude: equipment.latitude,
                longitude: equipment.longitude
            )
            elevator.addedAt = now.addingTimeInterval(-Double(offset) * 86_400)
            return elevator
        }
    }

    private static func explanation(_ language: String) -> String {
        language == "en" ? "Out of order – repair scheduled" : "Außer Betrieb – Reparatur beauftragt"
    }
}
#endif
