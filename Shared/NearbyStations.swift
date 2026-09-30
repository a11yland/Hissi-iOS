import Foundation

// Distance sort behind the "In der Nähe" suggestions: stations from the
// catalog within walking distance, nearest first, each with the status of its
// elevators. Pure Foundation (haversine, no CoreLocation) so the package tests
// cover it; the iOS app supplies the user coordinate.
//
// Distance and status read different slices of the same station: coordinates
// come from the seed overlay, so a station without any stays out entirely,
// but an elevator without coordinates still counts towards the station's
// status — it is one of the lifts the user would take.
nonisolated enum NearbyStations {
    // "Nearby" means reachable on foot: the suggestion is the station the user
    // could walk to now, not the nearest one in the region — in Brandenburg
    // the nearest station can be a car ride away, and listing it would only
    // pretend otherwise. One kilometre is a 12–15 minute walk. The UI names
    // the radius so an empty list reads as "nothing within reach", not as a
    // failure.
    static let walkingRadiusMeters = 1_000.0

    // Hashable: the watch pushes a station as a navigation value.
    struct Station: Hashable, Identifiable {
        struct Elevator: Hashable {
            let id: String
            let isWorking: Bool?
        }

        let name: String
        let distanceMeters: Double
        // Every elevator of the station, in catalog order. Carried per id (not
        // as counts) so a partial status refresh can replace what it resolved
        // and leave the rest standing — see `restated(_:with:)`.
        let elevators: [Elevator]
        var id: String { name }

        var total: Int { elevators.count }
        // filter().count rather than count(where:) — the latter needs
        // stdlib 6.0 (iOS 18), the app ships to iOS 17.
        var brokenCount: Int { elevators.filter { $0.isWorking == false }.count }
        var unknownCount: Int { elevators.filter { $0.isWorking == nil }.count }

        // Same precedence as the favorites verdict (ElevatorSummary): broken
        // outranks unknown outranks all-clear, so a station never reads as
        // working while one of its lifts is out.
        var status: ElevatorStatus {
            // A station without elevators can only be a construction error —
            // "Alle in Betrieb" would be a false all-clear.
            if elevators.isEmpty { return .unknown }
            if brokenCount > 0 { return .broken }
            if unknownCount > 0 { return .unknown }
            return .working
        }

        // What the row says next to the symbol. A station is not an elevator:
        // the ratio is the useful part ("1 von 3" leaves an alternative, "1 von
        // 1" does not), so the counts appear as soon as there is more than one
        // lift. Never claims an all-clear while something is unknown.
        var statusLabel: String {
            guard total > 1 else { return status.label }
            if brokenCount > 0 {
                return String(localized: "\(brokenCount) von \(total) außer Betrieb")
            }
            if unknownCount == total { return ElevatorStatus.unknown.label }
            if unknownCount > 0 {
                return String(localized: "\(unknownCount) von \(total) unbekannt")
            }
            return String(localized: "Alle in Betrieb")
        }
    }

    static func nearest(
        toLatitude latitude: Double,
        longitude: Double,
        in catalog: [AccessibilityCloudClient.Equipment],
        limit: Int = 5,
        withinMeters radius: Double = walkingRadiusMeters
    ) -> [Station] {
        let named = catalog.filter { !$0.stationName.isEmpty }
        // Grouped by the plain station name — the same key SearchGrouping
        // uses, so tapping a row lists exactly the elevators counted here.
        let stations = Dictionary(grouping: named, by: \.stationName)
            .compactMap { name, records -> Station? in
                let distances = records.compactMap { record -> Double? in
                    guard let recordLatitude = record.latitude,
                          let recordLongitude = record.longitude
                    else { return nil }
                    return distanceMeters(latitude, longitude, recordLatitude, recordLongitude)
                }
                // A station is as close as its closest elevator; one without
                // any coordinates at all can't be placed and stays out, and
                // so does one beyond walking distance.
                guard let closest = distances.min(), closest <= radius else { return nil }
                return Station(
                    name: name,
                    distanceMeters: closest,
                    elevators: records.map { Station.Elevator(id: $0.id, isWorking: $0.isWorking) }
                )
            }
            // Name breaks distance ties so the order is deterministic
            // (dictionary grouping isn't).
            .sorted { ($0.distanceMeters, $0.name) < ($1.distanceMeters, $1.name) }
        return Array(stations.prefix(limit))
    }

    // Every elevator id the given stations are made of — the batch a status
    // refresh asks for (EquipmentCatalog.equipment(for:)).
    static func elevatorIds(of stations: [Station]) -> Set<String> {
        Set(stations.flatMap { $0.elevators.map(\.id) })
    }

    // Folds freshly fetched records into the stations: only statuses change,
    // never names, distances or order — the list must not reshuffle under the
    // user's finger while a request lands. Elevators the refresh didn't
    // resolve keep the status they had (a partial answer beats downgrading
    // them all to unknown). Keyed by the requested id, which is what
    // EquipmentCatalog.equipment(for:) returns — a bridged record may carry a
    // different id of its own, and adopting it here would break the next fold.
    static func restated(
        _ stations: [Station],
        with fresh: [String: AccessibilityCloudClient.Equipment]
    ) -> [Station] {
        guard !fresh.isEmpty else { return stations }
        return stations.map { station in
            Station(
                name: station.name,
                distanceMeters: station.distanceMeters,
                elevators: station.elevators.map { elevator in
                    guard let record = fresh[elevator.id] else { return elevator }
                    return Station.Elevator(id: elevator.id, isWorking: record.isWorking)
                }
            )
        }
    }

    // Haversine over the mean earth radius — meter-accurate at city scale.
    static func distanceMeters(
        _ latitude1: Double, _ longitude1: Double,
        _ latitude2: Double, _ longitude2: Double
    ) -> Double {
        let radius = 6_371_000.0
        let deltaLatitude = (latitude2 - latitude1) * .pi / 180
        let deltaLongitude = (longitude2 - longitude1) * .pi / 180
        let a = sin(deltaLatitude / 2) * sin(deltaLatitude / 2)
            + cos(latitude1 * .pi / 180) * cos(latitude2 * .pi / 180)
            * sin(deltaLongitude / 2) * sin(deltaLongitude / 2)
        return radius * 2 * atan2(sqrt(a), sqrt(1 - a))
    }
}
