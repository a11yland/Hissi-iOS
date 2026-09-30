import Foundation

// Client for the transit.accessibility.cloud API — the successor to the old
// www.accessibility.cloud equipment-infos API (which lacked stations and is
// being retired upstream). The API is a Payload CMS: three flat collections —
// Elevators, StatusSpans, StopPlaces — with numeric ids and id references
// between them. Per upstream guidance the lists are fetched with minimal
// nesting (depth=0, no populate), cached by id and joined locally; the join
// produces the same Equipment domain model as before, so everything
// downstream of this client is unchanged.
//
// Endpoint and field details follow the published documentation
// (https://transit.accessibility.cloud/docs): the live status is the elevator's own
// `operational_status.operational_status`; StatusSpans are the disruption
// history and contribute the human-readable reason and the status-change
// timestamp via `current_status_span`. Decoding stays lenient (Int-or-String
// ids, localized-map-or-plain strings) as a hedge against schema drift.
//
// nonisolated because the targets default actor isolation to MainActor, which
// would otherwise serialise the parallel list fetches.
nonisolated enum AccessibilityCloudClient {
    // Held in Shared/Secrets.swift (gitignored) — see Secrets.example.swift.
    // Transit tokens are Bearer tokens of the form "trtok_…".
    static let appToken = Secrets.accessibilityCloudAppToken

    enum TransitAPI {
        static let host = "https://transit.accessibility.cloud"
        static let root = "/api"
        static let elevators = "elevators"
        static let statusSpans = "status-spans"
        static let stopPlaces = "stop-places"
        // 1000 halves the request count vs 500 (elevators: 4 pages instead
        // of 7) at ~23 s / ~330 KB per selected page — the server time is
        // mostly fixed cost, so fewer, bigger pages win (measured live
        // 2026-08-04). Payload accepts larger limits, but latency grows with
        // the doc count and search waits on the slowest page.
        static let pageSize = 1000
    }

    // Dedicated sessions: live status must never come from cache. The
    // default session fails fast enough to fit a BGAppRefreshTask's ~30 s
    // budget — since the targeted favorites fetch (<1 s measured) that is
    // the only request background refresh makes. Catalog list pages are
    // search-only (foreground) and legitimately take ~20–25 s at
    // limit=1000, so they get their own headroom; without it every page
    // times out and the app silently falls back to the seed.
    private static let session = makeSession(timeout: 20)
    private static let catalogSession = makeSession(timeout: 45)

    private static func makeSession(timeout: TimeInterval) -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = timeout
        return URLSession(configuration: configuration)
    }

    // MARK: - Domain model

    // Codable so EquipmentCatalog can persist the joined live catalog across
    // launches (stale-while-revalidate for the search).
    struct Equipment: Equatable, Codable {
        let id: String            // numeric transit.accessibility.cloud id, as string
        // linked_data.operator_inventory_id — the operator's inventory number
        // (BVG "Fabriknummer", DB FaSta equipment number). Matches records to
        // the bundled seed, which backfills what the API doesn't serve
        // (station/source names, coordinates, region).
        let inventoryId: String?
        let stationId: String     // national station number, e.g. "900193002"
        let stationName: String
        // Networks the whole station serves (stop-place transport modes);
        // refines TransitNetwork.classify. Empty on seed-only records.
        let stationNetworks: Set<TransitNetwork>
        let description: String
        let isWorking: Bool?
        let lastUpdate: Date?
        let sourceName: String
        let organizationName: String
        let stateExplanation: String?
        let latitude: Double?
        let longitude: Double?
        // DB FaSta equipment number from the bundled seed catalog; present on
        // records matched (or added) by scripts/generate-seed-catalog.py.
        let fastaEquipmentNumber: Int?
        // Position on the brokenlifts.org station page; only on
        // "brokenlifts-…" seed records. Becomes the favorite's elevatorIndex.
        let brokenliftsIndex: Int?
        // Berlin/Brandenburg, from the stop place's DHID or the seed; nil when
        // neither knows (search then falls back to the name heuristic).
        let region: TransitRegion?

        init(
            id: String,
            inventoryId: String? = nil,
            stationId: String,
            stationName: String,
            stationNetworks: Set<TransitNetwork> = [],
            description: String,
            isWorking: Bool?,
            lastUpdate: Date?,
            sourceName: String = "",
            organizationName: String = "",
            stateExplanation: String? = nil,
            latitude: Double? = nil,
            longitude: Double? = nil,
            fastaEquipmentNumber: Int? = nil,
            brokenliftsIndex: Int? = nil,
            region: TransitRegion? = nil
        ) {
            self.id = id
            self.inventoryId = inventoryId
            self.stationId = stationId
            self.stationName = stationName
            self.stationNetworks = stationNetworks
            self.description = description
            self.isWorking = isWorking
            self.lastUpdate = lastUpdate
            self.sourceName = sourceName
            self.organizationName = organizationName
            self.stateExplanation = stateExplanation
            self.latitude = latitude
            self.longitude = longitude
            self.fastaEquipmentNumber = fastaEquipmentNumber
            self.brokenliftsIndex = brokenliftsIndex
            self.region = region
        }
    }

    // MARK: - Catalog fetch (three flat lists, joined locally)

    // Fetch the full catalog: Elevators, StatusSpans and StopPlaces in
    // parallel, then join by id. Elevators and StopPlaces are required — a
    // partial fetch would silently degrade every favorite, so either failing
    // fails the whole catalog and callers keep previous values. StatusSpans
    // only enrich (disruption text, status-change date): the live status is
    // the elevator's own operational_status, so a failed span fetch degrades
    // gracefully instead of failing the build. Only spans still active are
    // requested — the full collection is the outage history.
    //
    // Every request trims the response via select[] (the docs' "golden
    // rule"): an unselected elevators page blows past 30 s and ~1.1 MB;
    // selected, a limit=1000 page is ~23 s and ~330 KB (2026-08-04) — still
    // slow enough that the pages need the catalog session's long timeout.
    static func fetchCatalog() async -> [Equipment]? {
        let nowISO = ISO8601DateFormatter().string(from: Date())
        async let elevators = fetchAllPages(
            TransitAPI.elevators,
            extraQuery: select(
                ["function", "short_visual"], ["location", "site"],
                ["operational_status", "operational_status"],
                ["operational_status", "current_status_span"],
                ["linked_data", "operator_inventory_id"],
                ["elevator_type"], ["stop_place_name"],
                ["internal_description"], ["updatedAt"]
            ),
            // Closure literals instead of function references — only literals
            // get @Sendable inferred at the @Sendable parameter.
            parse: { parseElevators($0) }
        )
        async let spans = fetchAllPages(
            TransitAPI.statusSpans,
            extraQuery: select(
                ["elevator"], ["operational_status"],
                ["start_date"], ["end_date"], ["description"]
            ) + [
                URLQueryItem(name: "where[or][0][end_date][exists]", value: "false"),
                URLQueryItem(name: "where[or][1][end_date][greater_than]", value: nowISO),
            ],
            // An empty page of active spans is legitimate (nothing broken).
            emptyFirstPageIsFailure: false,
            parse: { parseStatusSpans($0) }
        )
        async let stops = fetchAllPages(
            TransitAPI.stopPlaces,
            extraQuery: select(
                ["normalized_name"], ["main_identifier"],
                ["modes", "servicedTransportModes"]
            ),
            parse: { parseStopPlaces($0) }
        )
        guard let elevators = await elevators,
              let stops = await stops
        else { return nil }
        return join(elevators: elevators, statusSpans: await spans ?? [], stopPlaces: stops)
    }

    // Maps the app's resolved localization onto the API's locales (de/en,
    // the same pair the app ships). preferredLocalizations only yields
    // bundled localizations, so everything non-English — including nil in
    // contexts without a catalog, like the SwiftPM tests — is German, the
    // development and canonical source language. Pure, unit-tested.
    static func requestLocale(appLocalization: String?) -> String {
        appLocalization?.hasPrefix("en") == true ? "en" : "de"
    }

    // select[a][b]=true query items — only request the fields the DTOs read.
    private static func select(_ paths: [String]...) -> [URLQueryItem] {
        paths.map { path in
            URLQueryItem(name: "select" + path.map { "[\($0)]" }.joined(), value: "true")
        }
    }

    // MARK: - Targeted fetch (favorites refresh)

    // Resolve specific elevators in one request instead of building the full
    // catalog (10+ list requests): where[id][in] narrows to the requested
    // ids, depth=1 resolves current_status_span inline (the docs' example
    // pattern for status + disruption text in a single request), populate[]
    // trims the span to the fields the DTO reads. StopPlaces are not needed —
    // the cached stop_place_name covers the station name. Verified live
    // 2026-08-04. nil = request failed; ids the response doesn't answer for
    // are simply absent from the result.
    static func fetchEquipment(ids: [String]) async -> [Equipment]? {
        guard !ids.isEmpty else { return [] }
        let query = select(
            ["function", "short_visual"],
            ["operational_status", "operational_status"],
            ["operational_status", "current_status_span"],
            ["linked_data", "operator_inventory_id"],
            ["elevator_type"], ["stop_place_name"],
            ["internal_description"], ["updatedAt"]
        ) + spanPopulate + [
            URLQueryItem(name: "where[id][in]", value: ids.joined(separator: ",")),
        ]
        guard let data = await fetchPage(TransitAPI.elevators, extraQuery: query, page: 1, depth: 1) else {
            return nil
        }
        return joinTargeted(parseElevators(data).items)
    }

    // The populated span carries every span field by default — trim it to
    // what StatusSpan decodes.
    private static let spanPopulate = [
        "elevator", "operational_status", "start_date", "end_date", "description", "updatedAt",
    ].map { URLQueryItem(name: "populate[status-spans][\($0)]", value: "true") }

    // Join for a targeted (depth=1) response: the spans come inline on the
    // elevators instead of from a separate list. Pure, unit-tested.
    static func joinTargeted(_ elevators: [Elevator], now: Date = Date()) -> [Equipment] {
        join(
            elevators: elevators,
            statusSpans: elevators.compactMap(\.inlineStatusSpan),
            stopPlaces: [],
            now: now
        )
    }

    // Page 1 tells the page count (Payload envelope), the remaining pages
    // load in parallel. Server time is fixed cost per request (~20–30 s), so
    // waiting for page 1 before fetching the rest doubles the build — the
    // remembered page count of the previous build lets all expected pages go
    // out at once (speculation: a stale count self-corrects below, at the
    // price of a wasted or late request).
    private static func fetchAllPages<T: Sendable>(
        _ resource: String,
        extraQuery: [URLQueryItem] = [],
        emptyFirstPageIsFailure: Bool = true,
        parse: @escaping @Sendable (Data) -> (items: [T], hasNextPage: Bool?, totalPages: Int?)
    ) async -> [T]? {
        let speculative = speculated(pageCountHint: PageCountStore.hint(for: resource))
        var fetched = await fetchPages([1] + speculative, resource, extraQuery)
        guard let firstData = fetched[1] ?? nil else { return nil }
        let first = parse(firstData)
        // A 200 that parses to nothing on the first page is indistinguishable
        // from a schema mismatch — treat it as failure rather than caching an
        // empty catalog.
        if first.items.isEmpty { return emptyFirstPageIsFailure ? nil : [] }
        var all = first.items
        if let totalPages = first.totalPages {
            PageCountStore.remember(totalPages, for: resource)
            if totalPages > 1 {
                // Second wave: pages the speculation missed, plus one retry
                // for speculative fetches that failed. Overshot pages (count
                // shrank) simply go unused.
                let missing = (2...totalPages).filter { (fetched[$0] ?? nil) == nil }
                fetched.merge(await fetchPages(missing, resource, extraQuery)) { _, second in second }
                for page in 2...totalPages {
                    // All-or-nothing: a lost page would silently drop elevators.
                    guard let data = fetched[page] ?? nil else { return nil }
                    all.append(contentsOf: parse(data).items)
                }
            }
        } else if first.hasNextPage ?? (first.items.count == TransitAPI.pageSize) {
            // No page count in the envelope — sequential fallback (ignores
            // speculative results; this path shouldn't occur with Payload).
            var page = 2
            while let data = await fetchPage(resource, extraQuery: extraQuery, page: page, via: catalogSession) {
                let parsed = parse(data)
                all.append(contentsOf: parsed.items)
                let more = parsed.hasNextPage ?? (parsed.items.count == TransitAPI.pageSize)
                if !more || parsed.items.isEmpty { break }
                page += 1
            }
        }
        return all
    }

    private static func fetchPages(
        _ pages: [Int],
        _ resource: String,
        _ extraQuery: [URLQueryItem]
    ) async -> [Int: Data?] {
        await withTaskGroup(of: (Int, Data?).self) { group in
            for page in pages {
                group.addTask {
                    (page, await fetchPage(resource, extraQuery: extraQuery, page: page, via: catalogSession))
                }
            }
            var collected: [Int: Data?] = [:]
            for await (page, data) in group { collected[page] = data }
            return collected
        }
    }

    // The extra pages worth requesting alongside page 1, from the remembered
    // count. Pure, unit-tested. Capped: a corrupt hint must not fan out into
    // dozens of wasted requests.
    static func speculated(pageCountHint: Int?) -> [Int] {
        guard let hint = pageCountHint, hint > 1 else { return [] }
        return Array(2...min(hint, 20))
    }

    // Last seen totalPages per collection, so the next build can speculate.
    // A guess is never trusted for correctness — page 1's envelope stays the
    // source of truth.
    private enum PageCountStore {
        static func hint(for resource: String) -> Int? {
            let count = UserDefaults.standard.integer(forKey: "catalogPageCount.\(resource)")
            return count > 1 ? count : nil
        }

        static func remember(_ count: Int, for resource: String) {
            UserDefaults.standard.set(count, forKey: "catalogPageCount.\(resource)")
        }
    }

    private static func fetchPage(
        _ resource: String,
        extraQuery: [URLQueryItem],
        page: Int,
        depth: Int = 0,
        via session: URLSession = session
    ) async -> Data? {
        guard var components = URLComponents(string: "\(TransitAPI.host)\(TransitAPI.root)/\(resource)") else { return nil }
        components.queryItems = [
            // Lists stay flat (relations = numeric ids, upstream guidance);
            // only the targeted fetch resolves the current span inline.
            URLQueryItem(name: "depth", value: "\(depth)"),
            // Published records only (recommended defaults). Only the app's
            // language instead of locale=all (halves every localized field);
            // missing translations fall back to German server-side, per
            // field (verified live 2026-08-04). Lenient.localizedText still
            // accepts full maps as a hedge.
            URLQueryItem(name: "draft", value: "false"),
            URLQueryItem(name: "trash", value: "false"),
            URLQueryItem(name: "locale", value: requestLocale(appLocalization: Bundle.main.preferredLocalizations.first)),
            URLQueryItem(name: "fallback-locale", value: "de"),
            URLQueryItem(name: "limit", value: "\(TransitAPI.pageSize)"),
            URLQueryItem(name: "page", value: "\(page)"),
        ] + extraQuery
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(appToken)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return data
    }

    // MARK: - Pure parsing (unit-tested)

    static func parseElevators(_ data: Data) -> (items: [Elevator], hasNextPage: Bool?, totalPages: Int?) {
        parseList(data)
    }

    static func parseStatusSpans(_ data: Data) -> (items: [StatusSpan], hasNextPage: Bool?, totalPages: Int?) {
        parseList(data)
    }

    static func parseStopPlaces(_ data: Data) -> (items: [StopPlace], hasNextPage: Bool?, totalPages: Int?) {
        parseList(data)
    }

    // Accepts the Payload CMS envelope ({"docs": […], "hasNextPage": …,
    // "totalPages": …}) or a bare array.
    private static func parseList<T: Decodable>(_ data: Data) -> (items: [T], hasNextPage: Bool?, totalPages: Int?) {
        if let bare = try? JSONDecoder().decode([T].self, from: data) {
            return (bare, nil, nil)
        }
        guard let envelope = try? JSONDecoder().decode(ListEnvelope<T>.self, from: data) else {
            return ([], nil, nil)
        }
        return (envelope.items, envelope.hasNextPage, envelope.totalPages)
    }

    // MARK: - Join (pure, unit-tested)

    // Resolve the numeric id references between the three lists into the flat
    // Equipment model the app runs on. The elevator's own operational_status
    // is the live status (upstream polls the operator feeds every ~2 min);
    // the current status span supplies the disruption text and the
    // status-change date. `unknown` (or an unrecognized word) stays unknown —
    // never a false "working"; a span covering `now` may still settle it.
    static func join(
        elevators: [Elevator],
        statusSpans: [StatusSpan],
        stopPlaces: [StopPlace],
        now: Date = Date()
    ) -> [Equipment] {
        let stopsById = Dictionary(stopPlaces.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let spansById = Dictionary(
            statusSpans.compactMap { span in span.id.map { ($0, span) } },
            uniquingKeysWith: { first, _ in first }
        )
        let spansByElevator = Dictionary(
            grouping: statusSpans.flatMap { span in span.elevatorIds.map { ($0, span) } },
            by: { $0.0 }
        ).mapValues { $0.map(\.1) }

        return elevators.compactMap { elevator in
            // Only elevators are tracked — the collection also carries
            // escalators and moving walkways.
            guard elevator.elevatorType == nil || elevator.elevatorType == "elevator" else { return nil }
            let stop = elevator.stopPlaceId.flatMap { stopsById[$0] }
            let span = elevator.currentStatusSpanId.flatMap { spansById[$0] }
                ?? currentSpan(in: spansByElevator[elevator.id] ?? [], now: now)
            let isWorking = elevator.isWorking ?? span?.isWorking
            return Equipment(
                id: elevator.id,
                inventoryId: elevator.inventoryId,
                stationId: stationNumber(from: stop?.originalId),
                stationName: stop?.name ?? elevator.stopPlaceName ?? "",
                stationNetworks: Set((stop?.modeIds ?? []).compactMap(TransitNetwork.init(transportModeId:))),
                description: elevator.description,
                isWorking: isWorking,
                // "Stand": when the status last changed (span start), not
                // when the record was last touched.
                lastUpdate: span?.start ?? span?.lastUpdate ?? elevator.lastUpdate,
                stateExplanation: isWorking == false ? span?.reason : nil,
                latitude: elevator.latitude ?? stop?.latitude,
                longitude: elevator.longitude ?? stop?.longitude,
                region: TransitRegion.from(originalPlaceInfoId: stop?.originalId)
            )
        }
    }

    // The span that covers `now`: already started (or no start) and not yet
    // ended (or no end). Several matches ⇒ the latest start wins.
    static func currentSpan(in spans: [StatusSpan], now: Date = Date()) -> StatusSpan? {
        spans
            .filter { span in
                (span.start.map { $0 <= now } ?? true) && (span.end.map { $0 > now } ?? true)
            }
            .max { ($0.start ?? .distantPast) < ($1.start ?? .distantPast) }
    }

    // "de:11000:900193002" → "900193002"; falls back to the raw id.
    static func stationNumber(from mainIdentifier: String?) -> String {
        guard let mainIdentifier else { return "" }
        return mainIdentifier.split(separator: ":").last.map(String.init) ?? mainIdentifier
    }

    static func date(from string: String?) -> Date? {
        guard let string else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }

    // Maps an operational_status word onto isWorking. Elevators use
    // in_service / out_of_service / partially_operational / unknown, status
    // spans use operational / out_of_service / unknown. A partially
    // operational elevator is not reliably usable ⇒ broken. Unknown words ⇒
    // nil, not false: an unrecognized status must read "unbekannt", not
    // "defekt".
    static func statusMeansWorking(_ raw: String) -> Bool? {
        switch raw.lowercased().replacingOccurrences(of: "_", with: "-") {
        case "in-service", "operational", "working", "ok", "active", "in-operation", "functional":
            return true
        case "out-of-service", "partially-operational", "broken", "out-of-order",
             "outoforder", "defect", "defective", "disruption", "closed",
             "inaccessible", "not-working", "notworking", "maintenance",
             "under-maintenance":
            return false
        default:
            return nil
        }
    }

    // MARK: - DTOs (lenient: Int-or-String ids, localized-map-or-plain
    // strings — a hedge against schema drift)

    struct Elevator: Decodable, Equatable {
        let id: String
        let stopPlaceId: String?          // location.site
        let description: String           // function.short_visual
        let elevatorType: String?         // elevator | escalator | moving_walkway
        let isWorking: Bool?              // operational_status.operational_status
        let currentStatusSpanId: String?  // operational_status.current_status_span
        // The current span as a populated object — only in targeted (depth=1)
        // responses; nil when the relation is a bare id.
        let inlineStatusSpan: StatusSpan?
        let inventoryId: String?          // linked_data.operator_inventory_id
        let stopPlaceName: String?        // cached stop name, fallback only
        let lastUpdate: Date?
        let latitude: Double?
        let longitude: Double?

        init(
            id: String,
            stopPlaceId: String? = nil,
            description: String = "",
            elevatorType: String? = nil,
            isWorking: Bool? = nil,
            currentStatusSpanId: String? = nil,
            inlineStatusSpan: StatusSpan? = nil,
            inventoryId: String? = nil,
            stopPlaceName: String? = nil,
            lastUpdate: Date? = nil,
            latitude: Double? = nil,
            longitude: Double? = nil
        ) {
            self.id = id
            self.stopPlaceId = stopPlaceId
            self.description = description
            self.elevatorType = elevatorType
            self.isWorking = isWorking
            self.currentStatusSpanId = currentStatusSpanId
            self.inlineStatusSpan = inlineStatusSpan
            self.inventoryId = inventoryId
            self.stopPlaceName = stopPlaceName
            self.lastUpdate = lastUpdate
            self.latitude = latitude
            self.longitude = longitude
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            guard let id = Lenient.id(c, ["id"]) else {
                throw DecodingError.keyNotFound(
                    AnyKey("id"),
                    .init(codingPath: decoder.codingPath, debugDescription: "elevator without id")
                )
            }
            self.id = id
            // Groups are nested objects even at depth=0; only relations
            // collapse to ids.
            let location = try? c.nestedContainer(keyedBy: AnyKey.self, forKey: AnyKey("location"))
            let function = try? c.nestedContainer(keyedBy: AnyKey.self, forKey: AnyKey("function"))
            let status = try? c.nestedContainer(keyedBy: AnyKey.self, forKey: AnyKey("operational_status"))
            let linked = try? c.nestedContainer(keyedBy: AnyKey.self, forKey: AnyKey("linked_data"))
            stopPlaceId = location.flatMap { Lenient.id($0, ["site"]) }
            // DB-feed elevators without a stop-place link carry their only
            // text in internal_description ("zu Gleis 1/1a").
            description = function.flatMap { Lenient.localizedText($0, ["short_visual", "short_tts"]) }
                ?? Lenient.localizedText(c, ["internal_description", "description", "name"]) ?? ""
            elevatorType = Lenient.string(c, ["elevator_type"])
            isWorking = status
                .flatMap { Lenient.string($0, ["operational_status"]) }
                .flatMap(AccessibilityCloudClient.statusMeansWorking)
            currentStatusSpanId = status.flatMap { Lenient.id($0, ["current_status_span"]) }
            // Decoding an object succeeds only for populated (depth=1)
            // relations — a bare id has no keyed container.
            inlineStatusSpan = status.flatMap {
                try? $0.decode(StatusSpan.self, forKey: AnyKey("current_status_span"))
            }
            inventoryId = linked.flatMap { Lenient.string($0, ["operator_inventory_id"]) }
            stopPlaceName = Lenient.localizedText(c, ["stop_place_name"])
            lastUpdate = AccessibilityCloudClient.date(from: Lenient.string(c, ["updatedAt"]))
            let point = Lenient.point(c)
            latitude = point?.latitude
            longitude = point?.longitude
        }
    }

    struct StatusSpan: Decodable, Equatable {
        let id: String?
        // `elevator` is a hasMany relation — one span can affect several
        // elevators.
        let elevatorIds: [String]
        let isWorking: Bool?
        let start: Date?
        let end: Date?
        let lastUpdate: Date?
        // Human-readable disruption reason, e.g. "Wird repariert".
        let reason: String?

        init(
            id: String? = nil,
            elevatorIds: [String],
            isWorking: Bool?,
            start: Date? = nil,
            end: Date? = nil,
            lastUpdate: Date? = nil,
            reason: String? = nil
        ) {
            self.id = id
            self.elevatorIds = elevatorIds
            self.isWorking = isWorking
            self.start = start
            self.end = end
            self.lastUpdate = lastUpdate
            self.reason = reason
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            id = Lenient.id(c, ["id"])
            elevatorIds = Lenient.idArray(c, ["elevator"])
            isWorking = Lenient.string(c, ["operational_status"])
                .flatMap(AccessibilityCloudClient.statusMeansWorking)
            start = AccessibilityCloudClient.date(from: Lenient.string(c, ["start_date"]))
            end = AccessibilityCloudClient.date(from: Lenient.string(c, ["end_date"]))
            lastUpdate = AccessibilityCloudClient.date(from: Lenient.string(c, ["updatedAt"]))
            reason = Lenient.localizedText(c, ["description", "title"])
        }
    }

    struct StopPlace: Decodable, Equatable {
        let id: String
        let name: String
        // DHID/IFOPT id (main_identifier), e.g. "de:11000:900193002" — source
        // of the national station number and the Berlin/Brandenburg region.
        let originalId: String?
        // modes.servicedTransportModes ids (1 = S-Bahn, 2 = U-Bahn,
        // 3 = Regional- und Fernbahn) — the networks the station serves.
        let modeIds: [Int]
        let latitude: Double?
        let longitude: Double?

        init(id: String, name: String, originalId: String? = nil, modeIds: [Int] = [], latitude: Double? = nil, longitude: Double? = nil) {
            self.id = id
            self.name = name
            self.originalId = originalId
            self.modeIds = modeIds
            self.latitude = latitude
            self.longitude = longitude
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            guard let id = Lenient.id(c, ["id"]) else {
                throw DecodingError.keyNotFound(
                    AnyKey("id"),
                    .init(codingPath: decoder.codingPath, debugDescription: "stop place without id")
                )
            }
            self.id = id
            // Stop places carry no display "name" field — normalized_name is
            // the human-readable one ("Seestraße (Berlin)").
            name = Lenient.localizedText(c, ["normalized_name", "name"]) ?? ""
            originalId = Lenient.string(c, ["main_identifier"])
            let modes = try? c.nestedContainer(keyedBy: AnyKey.self, forKey: AnyKey("modes"))
            modeIds = (modes.map { Lenient.idArray($0, ["servicedTransportModes"]) } ?? [])
                .compactMap(Int.init)
            let point = Lenient.point(c)
            latitude = point?.latitude
            longitude = point?.longitude
        }
    }

    private struct ListEnvelope<T: Decodable>: Decodable {
        let items: [T]
        let hasNextPage: Bool?
        let totalPages: Int?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            guard let items = try? c.decode([T].self, forKey: AnyKey("docs")) else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath, debugDescription: "no docs list")
                )
            }
            self.items = items
            hasNextPage = Lenient.bool(c, ["hasNextPage"])
            totalPages = Lenient.int(c, ["totalPages"])
        }
    }

    // MARK: - Lenient decoding helpers

    struct AnyKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ string: String) { stringValue = string }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    private enum Lenient {
        static func string(_ c: KeyedDecodingContainer<AnyKey>, _ keys: [String]) -> String? {
            for key in keys {
                if let value = try? c.decodeIfPresent(String.self, forKey: AnyKey(key)) { return value }
            }
            return nil
        }

        // A relation id: Int or String at depth=0, an object with an id at
        // depth>0. Normalized to String.
        static func id(_ c: KeyedDecodingContainer<AnyKey>, _ keys: [String]) -> String? {
            for key in keys {
                if let value = try? c.decodeIfPresent(Int.self, forKey: AnyKey(key)) { return String(value) }
                if let value = try? c.decodeIfPresent(String.self, forKey: AnyKey(key)) { return value }
                if let nested = try? c.nestedContainer(keyedBy: AnyKey.self, forKey: AnyKey(key)),
                   let value = id(nested, ["id"]) {
                    return value
                }
            }
            return nil
        }

        // A hasMany relation: an array of ids (or populated objects), or a
        // single one.
        static func idArray(_ c: KeyedDecodingContainer<AnyKey>, _ keys: [String]) -> [String] {
            struct Ref: Decodable {
                let id: String?
                init(from decoder: Decoder) throws {
                    if let int = try? decoder.singleValueContainer().decode(Int.self) {
                        id = String(int)
                    } else if let string = try? decoder.singleValueContainer().decode(String.self) {
                        id = string
                    } else if let c = try? decoder.container(keyedBy: AnyKey.self) {
                        id = Lenient.id(c, ["id"])
                    } else {
                        id = nil
                    }
                }
            }
            for key in keys {
                if let refs = try? c.decodeIfPresent([Ref].self, forKey: AnyKey(key)) {
                    return refs.compactMap(\.id)
                }
                if let single = id(c, [key]) { return [single] }
            }
            return []
        }

        static func int(_ c: KeyedDecodingContainer<AnyKey>, _ keys: [String]) -> Int? {
            for key in keys {
                if let value = try? c.decodeIfPresent(Int.self, forKey: AnyKey(key)) { return value }
            }
            return nil
        }

        static func bool(_ c: KeyedDecodingContainer<AnyKey>, _ keys: [String]) -> Bool? {
            for key in keys {
                if let value = try? c.decodeIfPresent(Bool.self, forKey: AnyKey(key)) { return value }
            }
            return nil
        }

        // A value that is either a localized map like { "de": "…" } or a plain
        // string (depends on the request's locale parameter). Individual
        // languages may be null ({ "de": "…", "en": null }). Prefers the
        // user's language; German is the canonical source language, and any
        // value beats none.
        static func localizedText(_ c: KeyedDecodingContainer<AnyKey>, _ keys: [String]) -> String? {
            for key in keys {
                if let map = try? c.decodeIfPresent([String: String?].self, forKey: AnyKey(key)) {
                    let values = map.compactMapValues { $0 }
                    let preferred = Locale.preferredLanguages.first
                        .map { Locale(identifier: $0) }?.language.languageCode?.identifier
                    if let preferred, let value = values[preferred] { return value }
                    if let value = values["de"] ?? values.values.first { return value }
                }
                if let value = try? c.decodeIfPresent(String.self, forKey: AnyKey(key)) { return value }
            }
            return nil
        }

        // Coordinates as GeoJSON geometry ([longitude, latitude]) or flat
        // latitude/longitude fields.
        static func point(_ c: KeyedDecodingContainer<AnyKey>) -> (latitude: Double, longitude: Double)? {
            struct Geometry: Decodable {
                let coordinates: [Double]
            }
            if let geometry = try? c.decodeIfPresent(Geometry.self, forKey: AnyKey("geometry")),
               geometry.coordinates.count == 2 {
                return (geometry.coordinates[1], geometry.coordinates[0])
            }
            if let latitude = try? c.decodeIfPresent(Double.self, forKey: AnyKey("latitude")),
               let longitude = try? c.decodeIfPresent(Double.self, forKey: AnyKey("longitude")) {
                return (latitude, longitude)
            }
            return nil
        }
    }
}
