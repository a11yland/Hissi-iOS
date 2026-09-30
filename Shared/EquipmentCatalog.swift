import Foundation

// In-memory cache of the full equipment catalog, backing the station search
// and the favorites refresh: transit.accessibility.cloud serves flat lists
// (Elevators, StatusSpans, StopPlaces) that are fetched once, joined by id
// and cached here, exactly as upstream recommends. An actor keeps the shared
// cache concurrency-safe; concurrent callers (a refresh racing a search)
// share one in-flight build instead of fetching twice.
//
// The live fetch is overlaid with the bundled seed catalog (SeedCatalog),
// which backfills what the API doesn't serve — source/operator names (only
// feed ids at depth=0), coordinates (none at all), region; station names
// only where a matched record has none, which today is never (every seed
// match is stop-place linked) — keeps gap stations
// searchable (e.g. S Fredersdorf, missing upstream) and carries the search
// when there is no network. Favorites from before the migration are NOT
// mapped: they are deleted once with a notice
// (FavoritesStore.removeLegacyFavoritesIfNeeded).
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
        buildLive: @escaping @Sendable () async -> [AccessibilityCloudClient.Equipment]? = {
            await AccessibilityCloudClient.fetchCatalog()
        }
    ) {
        self.ttl = ttl
        self.cacheFileURL = cacheFileURL
        self.seed = seed
        self.buildLive = buildLive
    }

    // Instant snapshot for stale-while-revalidate UIs (the search): memory or
    // persisted catalog of any age, nil when neither exists (first launch,
    // spinner as before). When the snapshot is stale — server latency makes a
    // build take 30–60 s — the shared rebuild is kicked off in the background;
    // callers show the stale names/statuses now and re-render off all() when
    // the build lands. Deliberately never falls back to the seed: seed records
    // carry pre-migration ids, and a favorite created from one would never
    // resolve live (offline search via all() stays the only path to that).
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
        let seedOnly = Self.overlaid(live: [], seed: seed)
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
        cached = Self.overlaid(live: live, seed: seed)
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
        cached = Self.overlaid(live: persisted.live, seed: seed)
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
    // search-only. Non-numeric ids are seed-record favorites (created from a
    // seed preview, the offline seed fallback, or a gap station): when any
    // cached catalog knows their live counterpart they bridge to it via the
    // operator inventory number — the caller sees the live record, adopts
    // its id (StatusMerge) and the favorite refreshes directly from then on.
    // Unbridged seed ids resolve from the bundled seed with unknown status,
    // as the catalog overlay would. Ids missing from the result keep their
    // previous values upstream.
    func equipment(for ids: Set<String>) async -> [String: AccessibilityCloudClient.Equipment] {
        guard !ids.isEmpty else { return [:] }
        loadDiskIfNeeded()
        // The id mapping is stable, so any cached catalog answers it — only
        // the status has to be fresh, and that is fetched below.
        let bridged = Self.bridgedLiveIds(for: ids, seed: seed, in: cached)
        let resolved: [AccessibilityCloudClient.Equipment]
        if !cached.isEmpty, let fetchedAt, Date().timeIntervalSince(fetchedAt) < ttl {
            resolved = cached
        } else {
            let numeric = Set(ids.filter { Int($0) != nil } + bridged.values).sorted()
            let live = numeric.isEmpty ? [] : await AccessibilityCloudClient.fetchEquipment(ids: numeric)
            // A failed fetch degrades to the seed overlay: numeric favorites
            // stay unresolved (previous values survive), seed-id favorites
            // still answer — status unknown, never a false "working".
            resolved = Self.overlaid(live: live ?? [], seed: seed)
        }
        let byId = Dictionary(resolved.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [String: AccessibilityCloudClient.Equipment] = [:]
        for id in ids {
            if let hit = bridged[id].flatMap({ byId[$0] }) ?? byId[id] { result[id] = hit }
        }
        // Last resort for seed ids the overlay didn't answer (e.g. an
        // accessibilityCloud-source seed record next to live data, unbridged
        // because no catalog build ever landed): resolve from the bundled
        // seed directly — status unknown, never a false "working", and no
        // spurious failure report.
        let missingSeedIds = ids.filter { result[$0] == nil && Int($0) == nil }
        if !missingSeedIds.isEmpty {
            for record in Self.overlaid(live: [], seed: seed.filter { missingSeedIds.contains($0.id) }) {
                result[record.id] = record
            }
        }
        return result
    }

    // Maps seed-record favorite ids (non-numeric) to the id of their live
    // record, matched via the operator inventory number (= the seed's FaSta
    // equipment number, stable across both APIs). Pure, unit-tested. Only
    // numeric candidates count as live — an appended seed record (which also
    // carries the number) must not bridge to itself.
    nonisolated static func bridgedLiveIds(
        for ids: Set<String>,
        seed: [SeedCatalog.Record],
        in catalog: [AccessibilityCloudClient.Equipment]
    ) -> [String: String] {
        let seedIds = ids.filter { Int($0) == nil }
        guard !seedIds.isEmpty, !catalog.isEmpty else { return [:] }
        let seedById = Dictionary(seed.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let liveByNumber = Dictionary(
            catalog.compactMap { record -> (Int, String)? in
                guard Int(record.id) != nil,
                      let number = record.fastaEquipmentNumber ?? record.inventoryId.flatMap({ Int($0) })
                else { return nil }
                return (number, record.id)
            },
            uniquingKeysWith: { first, _ in first }
        )
        return Dictionary(uniqueKeysWithValues: seedIds.compactMap { id in
            guard let number = seedById[id]?.fastaEquipmentNumber,
                  let liveId = liveByNumber[number] else { return nil }
            return (id, liveId)
        })
    }

    // Pure merge, unit-tested. `live` wins; matching runs over the operator
    // inventory number (= the seed's FaSta equipment number, stable across
    // both APIs). Matched records gain the seed's station/source/operator
    // names, coordinates and region; whatever the match leaves empty — and
    // everything on a record the number matches nothing for — falls back to
    // the station (see stationBackfilled). Seed records the live catalog does not
    // answer for are appended with unknown status — never a false "working":
    // "fasta" records whose elevator is missing upstream, "brokenlifts"
    // records while their whole station is absent (at a live station a stale
    // record would just sit next to the real elevators), and the entire seed
    // when offline. Unmatched accessibilityCloud records stay out either way
    // — their stations are live, appending them would duplicate elevators.
    nonisolated static func overlaid(
        live: [AccessibilityCloudClient.Equipment],
        seed: [SeedCatalog.Record]
    ) -> [AccessibilityCloudClient.Equipment] {
        let seedByInventory = Dictionary(
            seed.compactMap { record in
                record.fastaEquipmentNumber.map { (String($0), record) }
            },
            uniquingKeysWith: { first, _ in first }
        )

        // Seed records by station, for the fallback below. Built from the
        // whole seed, matched or not: at a station where two of three lifts
        // matched, the third is exactly the record that needs the other two.
        let seedByStation = Dictionary(
            grouping: seed.filter { !stationKey($0.stationName).isEmpty },
            by: { stationKey($0.stationName) }
        )

        var matchedSeedIds = Set<String>()
        let merged = live.map { equipment -> AccessibilityCloudClient.Equipment in
            guard let record = equipment.inventoryId.flatMap({ seedByInventory[$0] }) else {
                return stationBackfilled(equipment, from: seedByStation)
            }
            matchedSeedIds.insert(record.id)
            // Backfilled again on the way out: a matched seed record can
            // itself carry no coordinates (Waßmannsdorf), which its siblings
            // at the same station do.
            return stationBackfilled(AccessibilityCloudClient.Equipment(
                id: equipment.id,
                inventoryId: equipment.inventoryId,
                stationId: equipment.stationId,
                stationName: equipment.stationName.isEmpty ? record.stationName : equipment.stationName,
                stationNetworks: equipment.stationNetworks,
                description: equipment.description,
                isWorking: equipment.isWorking,
                lastUpdate: equipment.lastUpdate,
                sourceName: equipment.sourceName.isEmpty ? record.sourceName : equipment.sourceName,
                organizationName: equipment.organizationName.isEmpty
                    ? record.organizationName : equipment.organizationName,
                stateExplanation: equipment.stateExplanation,
                latitude: equipment.latitude ?? record.latitude,
                longitude: equipment.longitude ?? record.longitude,
                fastaEquipmentNumber: record.fastaEquipmentNumber,
                region: equipment.region ?? record.region.flatMap(TransitRegion.init(rawValue:))
            ), from: seedByStation)
        }

        let liveStationIds = Set(merged.map(\.stationId))
        var appended = merged
        for record in seed where !matchedSeedIds.contains(record.id) {
            switch record.source {
            case _ where live.isEmpty:
                break
            case "fasta":
                break
            case "brokenlifts" where !liveStationIds.contains(record.brokenliftsStationId ?? ""):
                break
            default:
                continue
            }
            appended.append(AccessibilityCloudClient.Equipment(
                id: record.id,
                stationId: record.brokenliftsStationId
                    ?? record.stationNumber.map(String.init) ?? "",
                stationName: record.stationName,
                description: record.description,
                isWorking: nil,
                lastUpdate: nil,
                sourceName: record.sourceName,
                organizationName: record.organizationName,
                latitude: record.latitude,
                longitude: record.longitude,
                fastaEquipmentNumber: record.fastaEquipmentNumber,
                brokenliftsIndex: record.brokenliftsIndex,
                region: record.region.flatMap(TransitRegion.init(rawValue:))
            ))
        }
        return appended
    }

    // What a live record the inventory number answered incompletely (or not
    // at all) still gets from the seed: the metadata that holds for a whole
    // station. The API serves neither coordinates nor source/operator names,
    // so without this an unmatched record loses its map, its Look Around view
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
    // fresh catalog).
    static func matchStations(_ query: String, in catalog: [Equipment]) -> [Equipment] {
        let needle = normalize(query)
        guard !needle.isEmpty else { return [] }
        return catalog.filter { normalize($0.stationName).contains(needle) }
    }

    // The station name with the query match emphasized (bold) — the "why is
    // this a result" cue in the list. Matching mirrors matchStations'
    // normalization (case- and diacritic-insensitive: "schonhauser" bolds
    // "Schönhauser"); when no contiguous match exists the name renders plain.
    static func highlightedStationName(_ name: String, matching query: String) -> AttributedString {
        var attributed = AttributedString(name)
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              let range = attributed.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive])
        else { return attributed }
        attributed[range].inlinePresentationIntent = .stronglyEmphasized
        return attributed
    }

    private static func normalize(_ string: String) -> String {
        string.folding(options: .diacriticInsensitive, locale: .current).lowercased()
    }
}
