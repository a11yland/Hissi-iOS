import Foundation

// Client for the Aufzugsstatus API (https://aufzuege.ploetzlich-querschnitt.de/api/),
// run by plötzlich querschnitt: an aggregated, key-less JSON feed of the
// elevator disruption systems of Deutsche Bahn (DB InfraGO FaSta,
// nationwide) and local operators (HVV, KVB, MVG, VAG Nürnberg, …), polled
// every five minutes upstream. It is Hissi's **second** status source, for
// everything beyond the VBB: transit.accessibility.cloud stays the source
// for Berlin and Brandenburg (BVG, S-Bahn Berlin and the DB stations there)
// — richer there (stop places, status spans, transport modes), and the
// catalog, seed and favorites bridge are built around it. This API fills
// the rest of the country: nationwide station search, favorites beyond the
// VBB and nearby stations where the local catalog knows none.
//
// Three rules keep the two sources from colliding:
// 1. **Ids are namespaced.** The API's own ids ("fasta:10804989",
//    "hvv:Master:11950-E", "kvb:034-01") are the favorite ids verbatim —
//    `isNationalId` tells them from the numeric accessibility.cloud ids,
//    and every refresh path routes on that (StatusSources.resolve).
// 2. **VBB stays with accessibility.cloud.** The feeds that duplicate it
//    (`bvg`, `brokenlifts`) are dropped wholesale (`excludedSources`), and
//    DB records whose FaSta equipment number a *searchable* local record
//    already carries are dropped per record (`excludingKnown`) — the local
//    catalog also holds ~2500 nationwide DB records without a station
//    name, which must not block their national counterparts.
// 3. **Honest status.** The docs' freshness rule is implemented: a record
//    whose feed was last seen more than `freshnessWindow` ago reads
//    "unbekannt" even when it says ACTIVE (the feed went quiet, not the
//    elevator); INACTIVE stays "defekt" — the conservative reading.
//
// The API has no multi-id endpoint, so favorites refresh with one request
// per national id (`/lifts/{id}`) — acceptable at favorite counts, never
// for a catalog. Fair use upstream is ~60 requests/min per IP with a
// descriptive User-Agent; CC BY 4.0 on the aggregation, so the about sheet
// names the source. nonisolated: the targets default to MainActor
// isolation, which would serialise the parallel lookups.
nonisolated enum AufzugsstatusClient {
    enum API {
        static let host = "https://aufzuege.ploetzlich-querschnitt.de"
        static let lifts = "lifts"
        static let near = "stations/near"
        // /lifts matches the station name as a substring and caps at 1000;
        // 300 records (~130 KB) is plenty for any query that narrows to a
        // station, and a broader one only wants the user to keep typing.
        static let searchLimit = 300
        // Below this the substring match returns half the country.
        static let minimumQueryLength = 3
    }

    // The docs' interpretation of `last_seen`: ≤ 15 min the state holds,
    // beyond that the feed has not reported and the status is unclear.
    static let freshnessWindow: TimeInterval = 15 * 60

    // Feeds this client never surfaces: `bvg` and `brokenlifts` cover the
    // VBB, which transit.accessibility.cloud serves (and the bvg feed here
    // is one UNKNOWN record per daily observation — 7700 rows for ~500
    // elevators, verified 2026-11-20); `osm-at`, `osm-ch` and `wienogd` are
    // OpenStreetMap inventories without a live feed, every record UNKNOWN,
    // which would only pad the results with "Status unbekannt" rows.
    static let excludedSources: Set<String> = ["bvg", "brokenlifts", "osm-at", "osm-ch", "wienogd"]

    // The lookup radius sent to the server. The device coordinate is
    // coarsened to two decimals first (`coarsened`, a ~1.1 km × 0.7 km cell
    // at Germany's latitudes), so the request radius has to cover the
    // walking radius plus the half-cell diagonal (~0.65 km); the true
    // walking-distance cut is then applied on the device, from the lifts'
    // own coordinates.
    static let nearbyRequestRadiusKm = 2.0
    static let nearbyRequestLimit = 20

    // "source:anything" — the API's id scheme. Numeric accessibility.cloud
    // ids, Mongo ids and the pre-migration seed ids ("fasta-123",
    // "brokenlifts-900…-0") carry no colon.
    static func isNationalId(_ id: String) -> Bool {
        id.range(of: #"^[a-z][a-z0-9-]*:\S+$"#, options: .regularExpression) != nil
    }

    // MARK: - DTOs

    struct Lift: Decodable, Equatable {
        let id: String
        let source: String
        let sourceId: String?
        let stationNumber: Int?
        let stationName: String?
        let description: String?
        let latitude: Double?
        let longitude: Double?
        let `operator`: String?
        let state: String?
        let stateExplanation: String?
        let lastSeen: String?

        enum CodingKeys: String, CodingKey {
            case id, source, state, description
            case sourceId = "source_id"
            case stationNumber = "station_number"
            case stationName = "station_name"
            case latitude = "lat"
            case longitude = "lon"
            case `operator`
            case stateExplanation = "state_explanation"
            case lastSeen = "last_seen"
        }
    }

    struct NearbyStation: Decodable, Equatable {
        let name: String
        let stationNumber: Int?
        let lifts: Int
        let latitude: Double
        let longitude: Double

        enum CodingKeys: String, CodingKey {
            case name, lifts
            case stationNumber = "station_number"
            case latitude = "lat"
            case longitude = "lon"
        }
    }

    // MARK: - Pure parsing and mapping (unit-tested)

    // nil = not a lifts list (decode failure); the caller treats it as a
    // failed request.
    static func parseLifts(_ data: Data) -> [Lift]? {
        try? JSONDecoder().decode([Lift].self, from: data)
    }

    static func parseNearbyStations(_ data: Data) -> [NearbyStation]? {
        try? JSONDecoder().decode([NearbyStation].self, from: data)
    }

    // Lifts → catalog records, filtered to what Hissi shows: excluded feeds
    // and nameless stations (the API fills `station` with "Bahnhof 962"
    // there — unsearchable, unplaceable) are dropped. Every record is
    // region `.national`, the third section of the search results.
    static func equipment(from lifts: [Lift], now: Date = Date()) -> [AccessibilityCloudClient.Equipment] {
        lifts.compactMap { lift -> AccessibilityCloudClient.Equipment? in
            guard !excludedSources.contains(lift.source),
                  let stationName = lift.stationName?.trimmingCharacters(in: .whitespaces),
                  !stationName.isEmpty
            else { return nil }
            let lastSeen = AccessibilityCloudClient.date(from: lift.lastSeen)
            let isWorking = isWorking(state: lift.state, lastSeen: lastSeen, now: now)
            // Only DB records carry the FaSta equipment number — the key the
            // local catalog (and its seed) also knows. Other feeds' ids live
            // in their own namespaces and could collide numerically.
            let inventoryId = lift.source == "fasta" ? lift.sourceId : nil
            return AccessibilityCloudClient.Equipment(
                id: lift.id,
                inventoryId: inventoryId,
                stationId: lift.stationNumber.map(String.init) ?? "",
                stationName: stationName,
                description: lift.description ?? "",
                isWorking: isWorking,
                lastUpdate: lastSeen,
                sourceName: sourceLabel(for: lift.source),
                organizationName: lift.operator ?? "",
                // "available" on a working lift says nothing; a broken or
                // unknown one explains itself ("not available", "under
                // construction", "monitoring not available").
                stateExplanation: isWorking == true ? nil : lift.stateExplanation?.nonEmpty,
                latitude: lift.latitude,
                longitude: lift.longitude,
                fastaEquipmentNumber: inventoryId.flatMap { Int($0) },
                region: .national
            )
        }
    }

    // ACTIVE holds only while the feed is fresh; INACTIVE is believed
    // regardless (a stale "defekt" is the safe reading); anything else —
    // UNKNOWN, a new word, no last_seen at all — is unknown, never working.
    static func isWorking(state: String?, lastSeen: Date?, now: Date = Date()) -> Bool? {
        switch state?.uppercased() {
        case "INACTIVE":
            return false
        case "ACTIVE":
            guard let lastSeen, now.timeIntervalSince(lastSeen) <= freshnessWindow else { return nil }
            return true
        default:
            return nil
        }
    }

    // What the detail's "Quelle" row says. DB FaSta keeps the spelling the
    // seed uses (TransitNetwork.classify keys on it); the city feeds are
    // their operator's acronym.
    static func sourceLabel(for source: String) -> String {
        switch source {
        case "fasta": "DB FaSta"
        case "vagn": "VAG Nürnberg"
        default: source.uppercased()
        }
    }

    // FaSta equipment numbers the local catalog answers for *and* can show:
    // records without a station name are invisible in the search and in
    // the nearby list, so they must not shadow their national counterpart.
    static func knownInventoryNumbers(in catalog: [AccessibilityCloudClient.Equipment]) -> Set<String> {
        Set(catalog.compactMap { record -> String? in
            guard !record.stationName.isEmpty else { return nil }
            return record.inventoryId ?? record.fastaEquipmentNumber.map(String.init)
        })
    }

    // Drops the national records the local catalog already shows (matched
    // on the FaSta equipment number). Pure, unit-tested.
    static func excludingKnown(
        _ equipment: [AccessibilityCloudClient.Equipment],
        knownInventoryNumbers known: Set<String>
    ) -> [AccessibilityCloudClient.Equipment] {
        guard !known.isEmpty else { return equipment }
        return equipment.filter { record in
            guard let inventoryId = record.inventoryId else { return true }
            return !known.contains(inventoryId)
        }
    }

    // Two decimals: the cell the server learns is about a kilometre wide —
    // enough to find the stations in walking distance, not enough to tell
    // which door someone stands at.
    static func coarsened(_ coordinate: Double) -> Double {
        (coordinate * 100).rounded() / 100
    }

    // The placeholder the API uses where a station has no name — the
    // nearby endpoint lists it next to the real station of the same number.
    static func isPlaceholderName(_ name: String) -> Bool {
        name.range(of: #"^Bahnhof \d+$"#, options: .regularExpression) != nil
    }

    // Lifts answered for a nearby station, with the station's own coordinate
    // standing in for lifts that carry none (HVV, MVG), so the station is
    // placed and every lift counts. Pure, unit-tested.
    static func placed(_ lifts: [Lift], at station: NearbyStation) -> [Lift] {
        lifts.compactMap { lift in
            // A name query is a substring match: keep the station asked for.
            guard lift.stationName?.caseInsensitiveCompare(station.name) == .orderedSame else { return nil }
            guard lift.latitude == nil || lift.longitude == nil else { return lift }
            return Lift(
                id: lift.id, source: lift.source, sourceId: lift.sourceId,
                stationNumber: lift.stationNumber, stationName: lift.stationName,
                description: lift.description,
                latitude: station.latitude, longitude: station.longitude,
                operator: lift.operator, state: lift.state,
                stateExplanation: lift.stateExplanation, lastSeen: lift.lastSeen
            )
        }
    }

    // MARK: - Requests

    // Fails fast enough for a BGAppRefreshTask's budget; live status must
    // never come from a URL cache.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        return URLSession(configuration: configuration)
    }()

    // Fair use asks for a descriptive User-Agent: app, version, contact.
    static let userAgent: String = {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        return "Hissi/\(version) (hissi.app)"
    }()

    private static func fetch(_ path: String, query: [URLQueryItem] = []) async -> Data? {
        guard var components = URLComponents(string: "\(API.host)/\(path)") else { return nil }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return data
    }

    // Station search: the lifts whose station name contains the query, as
    // catalog records. nil = request failed; [] = too short to ask, or no
    // match. Callers drop what the local catalog already shows
    // (`excludingKnown`). Demo mode answers nothing — screenshots must not
    // depend on the network.
    static func searchLifts(matching query: String) async -> [AccessibilityCloudClient.Equipment]? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= API.minimumQueryLength else { return [] }
        #if DEBUG
        if DemoMode.isActive { return [] }
        #endif
        guard let data = await fetch(API.lifts, query: [
            URLQueryItem(name: "q", value: trimmed),
            URLQueryItem(name: "limit", value: "\(API.searchLimit)"),
        ]), let lifts = parseLifts(data) else { return nil }
        return equipment(from: lifts)
    }

    // The favorites refresh for national ids: one GET per id, in parallel.
    // Ids the API doesn't answer for (failure, 404) are absent from the
    // result — the caller keeps their previous values.
    static func fetchLifts(ids: Set<String>) async -> [String: AccessibilityCloudClient.Equipment] {
        guard !ids.isEmpty else { return [:] }
        #if DEBUG
        if DemoMode.isActive { return [:] }
        #endif
        return await withTaskGroup(of: AccessibilityCloudClient.Equipment?.self) { group in
            for id in ids {
                group.addTask {
                    guard let data = await fetch("\(API.lifts)/\(id)"),
                          let lift = try? JSONDecoder().decode(Lift.self, from: data)
                    else { return nil }
                    // Favorites keep their namespaced id; a nameless station
                    // record (none expected — favorites come from named
                    // search results) would be dropped by the mapping.
                    return equipment(from: [lift]).first
                }
            }
            var result: [String: AccessibilityCloudClient.Equipment] = [:]
            for await record in group {
                if let record { result[record.id] = record }
            }
            return result
        }
    }

    // Stations within walking distance according to the national API, as
    // the nearby list's rows — live statuses included, so no second phase
    // is needed. nil = the lookup failed; [] = nothing within reach. See
    // nearbyEquipment for what leaves the device and when.
    static func nearbyStations(
        latitude: Double,
        longitude: Double,
        limit: Int = 5,
        withinMeters radius: Double = NearbyStations.walkingRadiusMeters
    ) async -> [NearbyStations.Station]? {
        guard let equipment = await nearbyEquipment(latitude: latitude, longitude: longitude) else { return nil }
        return NearbyStations.nearest(
            toLatitude: latitude, longitude: longitude,
            in: equipment, limit: limit, withinMeters: radius
        )
    }

    // The lifts of the stations around a position according to the
    // national API, as catalog records with live statuses — the same input
    // NearbyStations.nearest takes from the local catalog, so the rows
    // come out of the same sort and the watch can show a station's lifts
    // from them. Only the coarsened coordinate leaves the device; the
    // walking-distance cut happens in the caller's sort, over the true one.
    // nil = the lookup failed; [] = no station around. Callers ask only
    // when the local catalog found nothing in reach (NearbyStationsSection,
    // NearbyWidget, WatchNearbyView), so a Berlin position never reaches
    // this server at all.
    static func nearbyEquipment(latitude: Double, longitude: Double) async -> [AccessibilityCloudClient.Equipment]? {
        #if DEBUG
        if DemoMode.isActive { return [] }
        #endif
        guard let data = await fetch(API.near, query: [
            URLQueryItem(name: "lat", value: String(coarsened(latitude))),
            URLQueryItem(name: "lon", value: String(coarsened(longitude))),
            URLQueryItem(name: "radius_km", value: String(nearbyRequestRadiusKm)),
            URLQueryItem(name: "limit", value: "\(nearbyRequestLimit)"),
        ]), let stations = parseNearbyStations(data) else { return nil }
        let named = stations.filter { !isPlaceholderName($0.name) }
        guard !named.isEmpty else { return [] }

        // The lifts of every candidate, in parallel — a handful of stations
        // within two kilometres. By station number where there is one (DB),
        // by name otherwise (city operators).
        let lifts = await withTaskGroup(of: [Lift].self) { group in
            for station in named {
                group.addTask {
                    let query: [URLQueryItem] = if let number = station.stationNumber {
                        [URLQueryItem(name: "station_number", value: "\(number)")]
                    } else {
                        [URLQueryItem(name: "q", value: station.name)]
                    }
                    guard let data = await fetch(API.lifts, query: query + [
                        URLQueryItem(name: "limit", value: "200"),
                    ]), let lifts = parseLifts(data) else { return [] }
                    return placed(lifts, at: station)
                }
            }
            var all: [Lift] = []
            for await batch in group { all += batch }
            return all
        }
        // Deduplicated: a station listed under two names (name + placeholder)
        // or two candidates sharing a lift must not count it twice.
        var seen = Set<String>()
        let unique = lifts.filter { seen.insert($0.id).inserted }
        return equipment(from: unique)
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
