import Foundation

// In-memory cache of the full equipment catalog, backing the station search
// and the favorites refresh: transit.accessibility.cloud serves flat lists
// (Elevators, StatusSpans, StopPlaces) that are fetched once, joined by id
// and cached here, exactly as upstream recommends. An actor keeps the shared
// cache concurrency-safe; concurrent callers (a refresh racing a search)
// share one in-flight build instead of fetching twice.
//
// The live fetch is overlaid with the bundled seed catalog (SeedCatalog),
// keyed by the same live ids: it supplies what the depth=0 lists don't carry
// — the station of elevators upstream hasn't linked to a stop place (every
// DB elevator outside Berlin/Brandenburg, placed at the nearest rail station
// by the generator), source/operator names (only feed/org ids live), region,
// station transport modes, and the station's coordinate where an elevator
// has no centroid — and carries the search when there is no network.
// Favorites from before the migration are NOT mapped: they are deleted once
// with a notice (FavoritesStore.removeLegacyFavoritesIfNeeded); favorites
// created from a format-1 seed preview bridge via SeedCatalog.legacyIds.
actor EquipmentCatalog {
    static let shared = EquipmentCatalog()

    private var cached: [AccessibilityCloudClient.Equipment] = []
    private var fetchedAt: Date?
    private var inFlight: Task<[AccessibilityCloudClient.Equipment]?, Never>?
    private var diskLoaded = false

    // The API docs recommend caching status-bearing data for 10 minutes.
    private let ttl: TimeInterval
    private let cacheFileURL: URL?
    // The bundled seed, injectable for tests (the test package bundles no
    // resource, so the default is empty there).
    private let seed: [SeedCatalog.Record]
    private let stations: [SeedCatalog.Station]
    private let legacyIds: [String: String]
    // The live fetch, injectable for tests. Returns the joined live catalog
    // WITHOUT the seed overlay — the overlay is applied on every load so a
    // release with a newer bundled seed reworks persisted data.
    private let buildLive: @Sendable () async -> [AccessibilityCloudClient.Equipment]?

    // Persisted into the App Group container so the widget extension reads
    // the catalog the app built (the nearby widget needs the coordinates and
    // ids, and must never build one itself). Falls back to the process's own
    // Caches directory where there is no container (tests, macOS).
    nonisolated static let defaultCacheFileURL: URL? = (
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: ElevatorCache.appGroupID)?
            .appendingPathComponent("Library/Caches", isDirectory: true)
        ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
    )?.appendingPathComponent("equipment-catalog.json")

    init(
        ttl: TimeInterval = 600,
        cacheFileURL: URL? = defaultCacheFileURL,
        seed: [SeedCatalog.Record] = SeedCatalog.records,
        stations: [SeedCatalog.Station] = SeedCatalog.stations,
        legacyIds: [String: String] = SeedCatalog.legacyIds,
        buildLive: @escaping @Sendable () async -> [AccessibilityCloudClient.Equipment]? = {
            await AccessibilityCloudClient.fetchCatalog()
        }
    ) {
        self.ttl = ttl
        self.cacheFileURL = cacheFileURL
        self.seed = seed
        self.stations = stations
        self.legacyIds = legacyIds
        self.buildLive = buildLive
    }

    // Instant snapshot for stale-while-revalidate UIs (the search): memory or
    // persisted catalog of any age, nil when neither exists (first launch,
    // spinner as before). When the snapshot is stale — server latency makes a
    // build take 30–60 s — the shared rebuild is kicked off in the background;
    // callers show the stale names/statuses now and re-render off all() when
    // the build lands. Never falls back to the seed itself — the callers
    // that want a preview (search, nearby) overlay the seed on their own.
    // `rebuildingIfStale: false` is the read-only form for processes that
    // must not build (the widget extension): whatever exists, no revalidation.
    func snapshot(rebuildingIfStale: Bool = true) -> [AccessibilityCloudClient.Equipment]? {
        loadDiskIfNeeded()
        let fresh = fetchedAt.map { Date().timeIntervalSince($0) < ttl } ?? false
        if rebuildingIfStale, cached.isEmpty || !fresh { _ = startBuild() }
        return cached.isEmpty ? nil : cached
    }

    // Returns the catalog, refetching when the cache is stale or empty. Returns
    // nil only when there is nothing cached, the fetch fails and no seed is
    // bundled.
    func all(forceRefresh: Bool = false) async -> [AccessibilityCloudClient.Equipment]? {
        loadDiskIfNeeded()
        if !forceRefresh, !cached.isEmpty, let fetchedAt, Date().timeIntervalSince(fetchedAt) < ttl {
            return cached
        }
        if let built = await startBuild().value { return built }
        if !cached.isEmpty { return cached }
        let seedOnly = Self.overlaid(live: [], seed: seed, stations: stations)
        return seedOnly.isEmpty ? nil : seedOnly
    }

    // Unstructured on purpose: a cancelled caller (every search keystroke
    // cancels its predecessor) must not abort the shared build, and a
    // completed build is always safe to cache.
    private func startBuild() -> Task<[AccessibilityCloudClient.Equipment]?, Never> {
        if let inFlight { return inFlight }
        let build = Task { await finishBuild(live: buildLive()) }
        inFlight = build
        return build
    }

    private func finishBuild(live: [AccessibilityCloudClient.Equipment]?) -> [AccessibilityCloudClient.Equipment]? {
        inFlight = nil
        guard let live else { return nil }
        cached = Self.overlaid(live: live, seed: seed, stations: stations)
        fetchedAt = Date()
        persist(live: live)
        return cached
    }

    // MARK: - Disk persistence (stale-while-revalidate across launches)

    // What survives launches: the joined live catalog plus its fetch time —
    // the age decides fresh (serve as-is, even saving the targeted favorites
    // request) vs stale (serve for search, revalidate in background). Only
    // the iOS app ever builds catalogs, so only its container gets the file;
    // in the extensions the load is a cheap miss.
    private struct PersistedCatalog: Codable {
        let fetchedAt: Date
        let live: [AccessibilityCloudClient.Equipment]
    }

    private func loadDiskIfNeeded() {
        guard !diskLoaded else { return }
        diskLoaded = true
        guard cached.isEmpty, let cacheFileURL,
              let data = try? Data(contentsOf: cacheFileURL),
              let persisted = try? JSONDecoder().decode(PersistedCatalog.self, from: data),
              !persisted.live.isEmpty
        else { return }
        cached = Self.overlaid(live: persisted.live, seed: seed, stations: stations)
        fetchedAt = persisted.fetchedAt
    }

    private func persist(live: [AccessibilityCloudClient.Equipment]) {
        guard let cacheFileURL,
              let data = try? JSONEncoder().encode(PersistedCatalog(fetchedAt: Date(), live: live))
        else { return }
        // The App Group container starts without a Caches directory.
        try? FileManager.default.createDirectory(
            at: cacheFileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: cacheFileURL, options: .atomic)
    }

    // Resolves favorites in one batch, keyed by the requested id. A
    // still-fresh catalog cache answers for free; otherwise one targeted
    // request (where[id][in], current span inline) covers all numeric ids —
    // the full catalog build (10+ list requests, in every process) stays
    // search-only. Non-numeric ids are favorites created from a format-1
    // seed preview: they bridge to their live id via SeedCatalog.legacyIds —
    // the caller sees the live record, adopts its id (StatusMerge) and the
    // favorite refreshes directly from then on. Ids missing from the result
    // keep their previous values upstream.
    func equipment(for ids: Set<String>) async -> [String: AccessibilityCloudClient.Equipment] {
        guard !ids.isEmpty else { return [:] }
        loadDiskIfNeeded()
        let bridged = Self.bridgedLiveIds(for: ids, legacyIds: legacyIds)
        let resolved: [AccessibilityCloudClient.Equipment]
        if !cached.isEmpty, let fetchedAt, Date().timeIntervalSince(fetchedAt) < ttl {
            resolved = cached
        } else {
            let numeric = Set(ids.filter { Int($0) != nil } + bridged.values).sorted()
            let live = numeric.isEmpty ? [] : await AccessibilityCloudClient.fetchEquipment(ids: numeric)
            // A failed fetch degrades to the seed: every favorite the seed
            // knows still answers — status unknown, never a false "working".
            resolved = Self.overlaid(live: live ?? [], seed: seed, stations: stations)
        }
        let byId = Dictionary(resolved.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [String: AccessibilityCloudClient.Equipment] = [:]
        for id in ids {
            if let hit = bridged[id].flatMap({ byId[$0] }) ?? byId[id] { result[id] = hit }
        }
        return result
    }

    // Maps format-1 seed ids (non-numeric) to live ids. Pure, unit-tested.
    nonisolated static func bridgedLiveIds(
        for ids: Set<String>,
        legacyIds: [String: String]
    ) -> [String: String] {
        Dictionary(uniqueKeysWithValues: ids.compactMap { id in
            guard Int(id) == nil, let live = legacyIds[id] else { return nil }
            return (id, live)
        })
    }

    // Pure merge, unit-tested. Seed and live share their ids, so a live
    // record takes from its seed record whatever it lacks — live always
    // wins. Typically that is the station (stationId, name, modes, region)
    // of an elevator upstream hasn't linked to a stop place, plus source and
    // operator names. A live record the seed doesn't know (added upstream
    // since the generation) falls back to the station: seed records at the
    // same station name supply coordinates, region and — when they all name
    // the same one — source/operator (see stationBackfilled). Seed records
    // only stand in for live ones when there is no live data at all
    // (offline, or a failed targeted fetch): then the whole seed is
    // returned, status unknown — never a false "working". With live data an
    // elevator missing from it is gone upstream and stays out. Whatever still
    // has no coordinate takes its station's from the `stations` list.
    nonisolated static func overlaid(
        live: [AccessibilityCloudClient.Equipment],
        seed: [SeedCatalog.Record],
        stations: [SeedCatalog.Station] = SeedCatalog.stations
    ) -> [AccessibilityCloudClient.Equipment] {
        let stationsById = Dictionary(
            stations.map { ($0.stationId, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        guard !live.isEmpty else {
            return seed.map { stationCoordinated(equipment(from: $0), from: stationsById) }
        }
        let seedById = Dictionary(seed.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let seedByStation = Dictionary(
            grouping: seed.filter { !stationKey($0.stationName).isEmpty },
            by: { stationKey($0.stationName) }
        )
        return live.map { equipment in
            guard let record = seedById[equipment.id] else {
                return stationCoordinated(stationBackfilled(equipment, from: seedByStation), from: stationsById)
            }
            // The seed's station replaces the live one only when live has
            // none — id, name and modes travel together.
            let hasStation = !equipment.stationName.isEmpty
            return stationCoordinated(AccessibilityCloudClient.Equipment(
                id: equipment.id,
                inventoryId: equipment.inventoryId ?? record.inventoryId,
                stationId: hasStation && !equipment.stationId.isEmpty ? equipment.stationId : record.stationId,
                stationName: hasStation ? equipment.stationName : record.stationName,
                stationNetworks: hasStation && !equipment.stationNetworks.isEmpty
                    ? equipment.stationNetworks : record.networks,
                description: equipment.description.isEmpty ? record.description : equipment.description,
                isWorking: equipment.isWorking,
                lastUpdate: equipment.lastUpdate,
                sourceName: equipment.sourceName.isEmpty ? record.sourceName : equipment.sourceName,
                organizationName: equipment.organizationName.isEmpty
                    ? record.organizationName : equipment.organizationName,
                stateExplanation: equipment.stateExplanation,
                latitude: equipment.latitude ?? record.latitude,
                longitude: equipment.longitude ?? record.longitude,
                fastaEquipmentNumber: equipment.fastaEquipmentNumber,
                brokenliftsIndex: equipment.brokenliftsIndex,
                region: equipment.region ?? record.transitRegion
            ), from: stationsById)
        }
    }

    // A seed record as a status-unknown catalog record.
    nonisolated static func equipment(from record: SeedCatalog.Record) -> AccessibilityCloudClient.Equipment {
        AccessibilityCloudClient.Equipment(
            id: record.id,
            inventoryId: record.inventoryId,
            stationId: record.stationId,
            stationName: record.stationName,
            stationNetworks: record.networks,
            description: record.description,
            isWorking: nil,
            lastUpdate: nil,
            sourceName: record.sourceName,
            organizationName: record.organizationName,
            latitude: record.latitude,
            longitude: record.longitude,
            region: record.transitRegion
        )
    }

    // The station's own coordinate for a record that has none — after the
    // live centroid and the seed's siblings, never instead of them. Pure,
    // unit-tested.
    nonisolated static func stationCoordinated(
        _ equipment: AccessibilityCloudClient.Equipment,
        from stationsById: [String: SeedCatalog.Station]
    ) -> AccessibilityCloudClient.Equipment {
        guard equipment.latitude == nil || equipment.longitude == nil || equipment.region == nil,
              let station = stationsById[equipment.stationId]
        else { return equipment }
        let needsCoordinate = equipment.latitude == nil || equipment.longitude == nil
        return AccessibilityCloudClient.Equipment(
            id: equipment.id,
            inventoryId: equipment.inventoryId,
            stationId: equipment.stationId,
            stationName: equipment.stationName,
            stationNetworks: equipment.stationNetworks,
            description: equipment.description,
            isWorking: equipment.isWorking,
            lastUpdate: equipment.lastUpdate,
            sourceName: equipment.sourceName,
            organizationName: equipment.organizationName,
            stateExplanation: equipment.stateExplanation,
            latitude: needsCoordinate ? station.latitude : equipment.latitude,
            longitude: needsCoordinate ? station.longitude : equipment.longitude,
            fastaEquipmentNumber: equipment.fastaEquipmentNumber,
            brokenliftsIndex: equipment.brokenliftsIndex,
            region: equipment.region ?? station.region.flatMap(TransitRegion.init(rawValue:))
        )
    }

    // What a live record the inventory number answered incompletely (or not
    // at all) still gets from the seed: the metadata that holds for a whole
    // station. The API serves no source/operator names and no coordinates for
    // some records, so without this an unmatched record loses its map, its Look Around view
    // and both name rows in the detail view — even though the bundle knows
    // the station. Two guards keep the fallback honest: it only fills what is
    // still missing (live always wins), and source/operator are adopted only
    // when every seed record at the station names the same one, so a station
    // served by two operators keeps those rows empty rather than claiming the
    // wrong one. The coordinates are a sibling lift's, not this one's — the
    // detail map frames the station at ~600 m, where that is the same place.
    // The inventory number is never taken from a sibling: it identifies the
    // elevator, not the station, and favorites bridge on it. Pure,
    // unit-tested.
    nonisolated static func stationBackfilled(
        _ equipment: AccessibilityCloudClient.Equipment,
        from seedByStation: [String: [SeedCatalog.Record]]
    ) -> AccessibilityCloudClient.Equipment {
        let needsCoordinate = equipment.latitude == nil || equipment.longitude == nil
        guard needsCoordinate || equipment.sourceName.isEmpty
                || equipment.organizationName.isEmpty || equipment.region == nil,
              let records = seedByStation[stationKey(equipment.stationName)]
        else { return equipment }

        let coordinate = needsCoordinate
            ? records.first { $0.latitude != nil && $0.longitude != nil }
            : nil
        return AccessibilityCloudClient.Equipment(
            id: equipment.id,
            inventoryId: equipment.inventoryId,
            stationId: equipment.stationId,
            stationName: equipment.stationName,
            stationNetworks: equipment.stationNetworks,
            description: equipment.description,
            isWorking: equipment.isWorking,
            lastUpdate: equipment.lastUpdate,
            sourceName: equipment.sourceName.isEmpty
                ? (unanimous(records.map(\.sourceName)) ?? "") : equipment.sourceName,
            organizationName: equipment.organizationName.isEmpty
                ? (unanimous(records.map(\.organizationName)) ?? "") : equipment.organizationName,
            stateExplanation: equipment.stateExplanation,
            latitude: equipment.latitude ?? coordinate?.latitude,
            longitude: equipment.longitude ?? coordinate?.longitude,
            fastaEquipmentNumber: equipment.fastaEquipmentNumber,
            brokenliftsIndex: equipment.brokenliftsIndex,
            region: equipment.region
                ?? records.compactMap { $0.region.flatMap(TransitRegion.init(rawValue:)) }.first
        )
    }

    // Station names across the two datasets differ by their network prefix:
    // the seed carries the VBB/BVG spelling ("U Spittelmarkt (Berlin)"), the
    // live catalog the stop place's ("Spittelmarkt (Berlin)"). Folding that
    // prefix away (plus case and diacritics) is deliberately all this does —
    // merging "S Pankow" with "U Pankow" is right, they are one station,
    // while a looser key (dropping "(Berlin)", tolerating suffixes) would
    // start merging stations that only share a name. Pure, unit-tested.
    nonisolated static func stationKey(_ stationName: String) -> String {
        let name = stationName
            .folding(options: .diacriticInsensitive, locale: .current)
            .lowercased()
            .trimmingCharacters(in: .whitespaces)
        for prefix in ["s+u ", "u ", "s "] where name.hasPrefix(prefix) {
            return String(name.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        return name
    }

    // The one value they all name, or nil when they disagree (or say nothing).
    private nonisolated static func unanimous(_ values: [String]) -> String? {
        let distinct = Set(values.filter { !$0.isEmpty })
        return distinct.count == 1 ? distinct.first : nil
    }
}

extension AccessibilityCloudClient {
    // nil = catalog unavailable (network failure); empty = no name matches.
    static func searchStations(_ query: String) async -> [Equipment]? {
        guard let all = await EquipmentCatalog.shared.all() else { return nil }
        return matchStations(query, in: all)
    }

    // The pure name filter, shared by both search phases (instant snapshot,
    // fresh catalog). A name matches when it contains the query as typed or
    // once station abbreviations are spelled out on both sides
    // (`StationAliases`: "Hauptbahnhof" finds "München Hbf", "Hbf" finds
    // "Berlin Hauptbahnhof") — the first keeps every partial match while
    // typing ("hb…"), the second bridges the spellings.
    static func matchStations(_ query: String, in catalog: [Equipment]) -> [Equipment] {
        let needle = normalize(query)
        guard !needle.isEmpty else { return [] }
        let expandedNeedle = StationAliases.expanded(needle)
        return catalog.filter {
            let name = normalize($0.stationName)
            return name.contains(needle) || StationAliases.expanded(name).contains(expandedNeedle)
        }
    }

    // The station name with the query match emphasized (bold) — the "why is
    // this a result" cue in the list. Matching mirrors matchStations'
    // normalization (case- and diacritic-insensitive: "schonhauser" bolds
    // "Schönhauser"), aliases included ("Hauptbahnhof" bolds the "Hbf");
    // when no contiguous match exists the name renders plain.
    static func highlightedStationName(_ name: String, matching query: String) -> AttributedString {
        var attributed = AttributedString(name)
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return attributed }
        for candidate in [trimmed] + StationAliases.variants(of: trimmed) {
            if let range = attributed.range(of: candidate, options: [.caseInsensitive, .diacriticInsensitive]) {
                attributed[range].inlinePresentationIntent = .stronglyEmphasized
                break
            }
        }
        return attributed
    }

    private static func normalize(_ string: String) -> String {
        string.folding(options: .diacriticInsensitive, locale: .current).lowercased()
    }
}

// Abbreviations station names use interchangeably with the full word — DB's
// "München Hbf" next to the stop places' "Berlin Hauptbahnhof". Applied to
// already folded (lowercased) text, whole words only, so "Hbf" expands but
// "Abfahrt" stays. Pure, unit-tested; Hissi-Android mirrors it.
nonisolated enum StationAliases {
    static let pairs: [(short: String, full: String)] = [
        ("hbf", "hauptbahnhof"),
        ("bhf", "bahnhof"),
        ("bf", "bahnhof"),
    ]

    // Every abbreviation spelled out ("münchen hbf" → "münchen hauptbahnhof").
    static func expanded(_ folded: String) -> String {
        pairs.reduce(folded) { text, pair in
            text.replacingOccurrences(
                of: "\\b\(pair.short)\\b\\.?", with: pair.full, options: .regularExpression
            )
        }
    }

    // The query's other spellings, for the highlight: each full word as its
    // abbreviations and each abbreviation spelled out ("Hauptbahnhof" →
    // "hbf"). Case is folded; the highlight matches case-insensitively.
    static func variants(of query: String) -> [String] {
        let folded = query.lowercased()
        var variants: [String] = []
        for pair in pairs {
            if folded.range(of: "\\b\(pair.full)\\b", options: .regularExpression) != nil {
                variants.append(folded.replacingOccurrences(
                    of: "\\b\(pair.full)\\b", with: pair.short, options: .regularExpression
                ))
            }
            if folded.range(of: "\\b\(pair.short)\\b", options: .regularExpression) != nil {
                variants.append(folded.replacingOccurrences(
                    of: "\\b\(pair.short)\\b\\.?", with: pair.full, options: .regularExpression
                ))
            }
        }
        return variants
    }
}
