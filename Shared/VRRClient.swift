import Foundation

// The second elevator source: the VRR infrastructure API ("MIP", published
// on https://www.opendata-oepnv.de/ht/de/api, CC BY 4.0) — the elevators of
// the municipal networks in Nordrhein-Westfalen that
// transit.accessibility.cloud doesn't carry. One request returns every stop
// with its infrastructure and each lift's current state; there is nothing to
// join. The app always asks for the whole list: it is one cheap request
// (~430 KB), and it tells the operator nothing about which lifts a user
// follows.
//
// Not wired into the catalog yet (FeatureToggle.vrr): this file is the
// parser and the request.
nonisolated enum VRRClient {
    typealias Equipment = AccessibilityCloudClient.Equipment

    static let infrastructureURL = URL(string: "https://mip.vrr.de/vrr-api/rest/stop/all/infrastructure")!
    // Printed on the portal page above — public, not a secret, which is why
    // it lives here and not in Secrets.swift.
    static let apiKey = "F3E46748D2DED"
    static let sourceName = "VRR"

    // A lift's own coordinate counts only this close to its stop: the feed
    // places some lifts kilometres away (a few in the Norwegian Sea). Same
    // rule and radius as scripts/generate-seed-catalog.py.
    static let plausibleLiftDistanceMeters = 300.0

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        return URLSession(configuration: configuration)
    }()

    // Every VRR elevator with its live status; nil when the request fails or
    // the answer doesn't parse — callers then keep what they have (seed
    // records with status unknown), never a guess.
    static func fetchAll(now: Date = Date()) async -> [Equipment]? {
        #if DEBUG
        if DemoMode.isActive {
            return DemoFixtures.catalog().filter { ElevatorSource(id: $0.id) == .vrr }
        }
        #endif
        var request = URLRequest(url: infrastructureURL)
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return parse(data, now: now)
    }

    // MARK: - Parsing (pure, unit-tested)

    // Elevators only — the feed also lists escalators and ramps. nil when
    // the data is not the expected list.
    static func parse(_ data: Data, now: Date = Date()) -> [Equipment]? {
        guard let stops = try? JSONDecoder().decode([Stop].self, from: data) else { return nil }
        var byId: [String: Equipment] = [:]
        var order: [String] = []
        for stop in stops {
            guard let dhid = stop.ifopt?.trimmed, !dhid.isEmpty else { continue }
            for lift in stop.infrastructure ?? [] where lift.type == "Aufzug" {
                guard let resourceId = lift.resourceId?.trimmed, !resourceId.isEmpty else { continue }
                let equipment = equipment(lift, resourceId: resourceId, at: stop, dhid: dhid, now: now)
                // The feed lists a lift twice now and then — the fuller
                // description wins.
                if let previous = byId[equipment.id] {
                    if equipment.description.count > previous.description.count { byId[equipment.id] = equipment }
                } else {
                    byId[equipment.id] = equipment
                    order.append(equipment.id)
                }
            }
        }
        return order.compactMap { byId[$0] }
    }

    private static func equipment(
        _ lift: Infrastructure, resourceId: String, at stop: Stop, dhid: String, now: Date
    ) -> Equipment {
        let isWorking = statusMeansWorking(lift.state?.state)
        // The state's timestamp is the time of the last state change —
        // exactly "seit". Only with a known status, and never from the
        // future (a clock ahead of ours).
        let changed = AccessibilityCloudClient.date(from: lift.state?.timestamp)
        let coordinate = coordinate(of: lift, at: stop)
        return Equipment(
            id: ElevatorSource.vrrId(resourceId: resourceId),
            stationId: dhid,
            // The raw stop name ("D-Kirchplatz U"); the seed carries the
            // normalised one and wins in the overlay.
            stationName: (stop.name ?? "").collapsedWhitespace,
            // The area label ("Allgemeiner Bereich", "SWB_O") says nothing;
            // the description tells two lifts apart.
            description: (lift.description ?? "").collapsedWhitespace,
            isWorking: isWorking,
            // "Datenstand" is the moment of the answer: this is the
            // operator's live system, its answer a current assertion. The
            // transition time would flag every lift that has simply worked
            // for weeks as stale.
            lastUpdate: now,
            statusSince: isWorking != nil ? changed.flatMap { $0 <= now ? $0 : nil } : nil,
            sourceName: sourceName,
            stateExplanation: isWorking == false ? explanation(lift.state?.description) : nil,
            latitude: coordinate?.latitude,
            longitude: coordinate?.longitude,
            region: TransitRegion.from(originalPlaceInfoId: dhid)
        )
    }

    // "in Ordnung" / "Störung"; anything else — a missing state, a word this
    // version doesn't know — is unknown, never a false "working".
    static func statusMeansWorking(_ state: String?) -> Bool? {
        switch state?.trimmed.lowercased() {
        case "in ordnung": true
        case "störung", "stoerung": false
        default: nil
        }
    }

    // The state's description is operator free text — status codes, but also
    // ticket notes with staff names. Only the known codes are shown, in the
    // app's own words; everything else is left out.
    static func explanation(_ description: String?) -> String? {
        switch description?.collapsedWhitespace.lowercased() {
        case "kein betrieb": String(localized: "Kein Betrieb")
        case "nicht betriebsbereit": String(localized: "Nicht betriebsbereit")
        case "fernabschaltung": String(localized: "Ferngesteuert abgeschaltet")
        case "stoerung personbefreiung", "störung personenbefreiung": String(localized: "Störung (Personenbefreiung)")
        default: nil
        }
    }

    // The lift's own coordinate if it is plausible, else the stop's.
    private static func coordinate(of lift: Infrastructure, at stop: Stop) -> (latitude: Double, longitude: Double)? {
        let stopCoordinate = stop.latitude.flatMap { latitude in stop.longitude.map { (latitude, $0) } }
        guard let latitude = lift.latitude, let longitude = lift.longitude else { return stopCoordinate }
        guard let stopCoordinate else { return (latitude, longitude) }
        let distance = NearbyStations.distanceMeters(latitude, longitude, stopCoordinate.0, stopCoordinate.1)
        return distance <= plausibleLiftDistanceMeters ? (latitude, longitude) : stopCoordinate
    }

    // MARK: - DTOs (every field optional: one odd record must not cost the
    // whole list)

    private struct Stop: Decodable {
        let ifopt: String?
        let name: String?
        let latitude: Double?
        let longitude: Double?
        let infrastructure: [Infrastructure]?
    }

    private struct Infrastructure: Decodable {
        let resourceId: String?
        let type: String?
        let description: String?
        let latitude: Double?
        let longitude: Double?
        let state: State?
    }

    private struct State: Decodable {
        let timestamp: String?
        let state: String?
        let description: String?
    }
}

private nonisolated extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }

    // "Bochum  Gesundheitscampus" → "Bochum Gesundheitscampus".
    var collapsedWhitespace: String {
        split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
