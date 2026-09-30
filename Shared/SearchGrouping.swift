import Foundation

// Pure grouping behind the search results list (unit-tested in HissiCore):
// region → station (alphabetical) → network. Only the iOS app renders it,
// but it lives in Shared so the package tests cover it.

struct StationSearchResult: Identifiable, Equatable {
    let stationId: String
    let name: String

    var id: String { stationId }
}

// Elevators of one station that belong to the same network, in display order
// within the station. The subheader is only rendered when a station spans
// several networks (S+U stations).
struct NetworkSection: Identifiable, Equatable {
    let network: TransitNetwork
    var elevators: [MonitoredElevator]
    var id: Int { network.rawValue }
}

// A station grouping one or more elevators for the search results list.
struct StationGroup: Identifiable, Equatable {
    let station: StationSearchResult
    var sections: [NetworkSection]
    var id: String { station.stationId }

    var networks: [TransitNetwork] { sections.map(\.network) }
}

// Top level of the results: Berlin before Brandenburg. The header is only
// rendered when the results span both regions.
struct RegionGroup: Identifiable, Equatable {
    let region: TransitRegion
    var stations: [StationGroup]
    var id: String { region.rawValue }
}

nonisolated enum SearchGrouping {
    // Grouping stations on the name (not the source-specific station id)
    // merges S+U stations whose U-Bahn and S-Bahn elevators come from
    // different sources. A station's region comes from the first record that
    // knows it, with the name heuristic as fallback.
    static func group(_ equipment: [AccessibilityCloudClient.Equipment]) -> [RegionGroup] {
        let stations = Dictionary(grouping: equipment, by: \.stationName)
            .map { name, items in
                (region: items.compactMap(\.region).first ?? TransitRegion.inferred(from: name),
                 group: StationGroup(
                     station: StationSearchResult(stationId: name, name: name),
                     sections: networkSections(items)
                 ))
            }

        return TransitRegion.allCases.compactMap { region in
            let matching = stations
                .filter { $0.region == region }
                .map(\.group)
                .sorted { $0.station.name.localizedCaseInsensitiveCompare($1.station.name) == .orderedAscending }
            return matching.isEmpty ? nil : RegionGroup(region: region, stations: matching)
        }
    }

    private static func networkSections(_ items: [AccessibilityCloudClient.Equipment]) -> [NetworkSection] {
        Dictionary(grouping: items) { equipment in
            TransitNetwork.classify(
                description: equipment.description,
                stationName: equipment.stationName,
                sourceName: equipment.sourceName,
                stationModes: equipment.stationNetworks
            )
        }
        .map { network, items in
            NetworkSection(network: network, elevators: items.map(monitored))
        }
        .sorted { $0.network < $1.network }
    }

    // Swaps one elevator in the grouped results for a fresher copy — what the
    // detail view fetched for a search result, folded back into the row behind
    // it. Matched by the id the row carries; the replacement may bring a new
    // id (a seed record resolved to its live one), the row adopts it. Nothing
    // about grouping or order changes.
    static func replacing(
        _ regions: [RegionGroup], id: String, with elevator: MonitoredElevator
    ) -> [RegionGroup] {
        regions.map { region in
            var region = region
            region.stations = region.stations.map { station in
                var station = station
                station.sections = station.sections.map { section in
                    var section = section
                    section.elevators = section.elevators.map { $0.id == id ? elevator : $0 }
                    return section
                }
                return station
            }
            return region
        }
    }

    private static func monitored(_ equipment: AccessibilityCloudClient.Equipment) -> MonitoredElevator {
        MonitoredElevator(
            id: equipment.id,
            stationId: equipment.stationId,
            elevatorId: equipment.id,
            // brokenlifts favorites refresh by page position.
            elevatorIndex: equipment.brokenliftsIndex ?? 0,
            stationName: equipment.stationName,
            elevatorDescription: equipment.description,
            isWorking: equipment.isWorking,
            lastChecked: Date(),
            lastUpdated: equipment.lastUpdate,
            sourceName: equipment.sourceName,
            organizationName: equipment.organizationName,
            stateExplanation: equipment.stateExplanation,
            latitude: equipment.latitude,
            longitude: equipment.longitude,
            fastaEquipmentNumber: equipment.fastaEquipmentNumber
        )
    }
}
