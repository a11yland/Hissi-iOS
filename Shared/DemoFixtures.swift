import Foundation

#if DEBUG
// The catalog DemoMode serves instead of the API: every bundled seed record
// as a live record under its own (live) id and a fixed status — mostly
// working, a few curated disruptions at stations the screenshots show.
// Derived from the seed rather than written by hand so search and nearby
// look like the real thing; the seed overlay matches every record by id. Dates are relative to `now`: fixed dates would
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
        Pick(station: "Alexanderplatz", description: "U8 ↔ Passage"),
        Pick(station: "Hackescher Markt", description: "(S-Bahn)"),
    ]
    static let unknown = [
        Pick(station: "Schillingstraße", description: "Straße ↔ Bahnsteig"),
    ]
    // The favorites a screenshot run starts with, newest first.
    static let favoritePicks = [
        Pick(station: "Alexanderplatz", description: "U2 ↔ Passage"),
        Pick(station: "Alexanderplatz", description: "U8 ↔ Passage"),
        Pick(station: "Berlin Hauptbahnhof", description: "↔ U5"),
        Pick(station: "Pankow (Berlin)", description: "Bahnsteig U2"),
    ]

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
        return seed.enumerated().map { index, record in
            let isBroken = brokenIndices.contains(index)
            let isUnknown = unknownIndices.contains(index)
            // Spread the "Stand" times over the last three hours; a
            // disruption is older than that.
            let minutesAgo = isBroken ? 26 * 60 : 8 + (index * 37) % 170
            // "Seit": the disruption began with its "Stand"; working lifts
            // have been running for days, an unknown status is recent.
            let sinceMinutesAgo = isBroken ? minutesAgo : isUnknown ? 2 * 60 : (2 + index % 19) * 1440
            return Equipment(
                id: record.id,
                inventoryId: record.inventoryId,
                stationId: record.stationId,
                stationName: record.stationName,
                stationNetworks: record.networks,
                description: record.description,
                isWorking: isUnknown ? nil : !isBroken,
                lastUpdate: isUnknown ? nil : now.addingTimeInterval(-Double(minutesAgo) * 60),
                statusSince: now.addingTimeInterval(-Double(sinceMinutesAgo) * 60),
                sourceName: record.sourceName,
                organizationName: record.organizationName,
                stateExplanation: isBroken ? explanation(language) : nil,
                latitude: record.latitude,
                longitude: record.longitude,
                region: record.transitRegion
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
                statusSince: equipment.statusSince,
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
