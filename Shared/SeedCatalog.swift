import Foundation

// Bundled snapshot of the transit.accessibility.cloud elevator catalog
// (format 2), generated per release by scripts/generate-seed-catalog.py.
// Every record is a live elevator under its live numeric id, so a favorite
// created from the seed (first launch, offline search) is a live favorite
// from the start. The seed backfills what the live depth=0 fetch doesn't
// carry — the station of elevators upstream hasn't linked to a stop place
// (all DB elevators outside Berlin/Brandenburg; the generator places them at
// the nearest rail station), source and operator names, region and station
// transport modes — and carries the search when there is no network. The
// `stations` list holds a coordinate for every station the seed uses, the
// fallback for elevators without a centroid. `legacyIds` maps the ids of
// the format-1 seed onto live ids (favorites created from an old preview).
// The iOS app, its widget extension and the watch app bundle the resource
// (Shared/Resources, kept out of the watch widget extension by a membership
// exception) — there `records` is empty.
nonisolated enum SeedCatalog {
    struct Record: Decodable, Equatable {
        let id: String                // live transit.accessibility.cloud id
        let inventoryId: String?      // linked_data.operator_inventory_id
        // National station number ("900100015") for platform stop places,
        // "name:<station>" for stations the generator assigned.
        let stationId: String
        let stationName: String
        // Stop-place transport modes (1 = S-Bahn, 2 = U-Bahn, 3 = Regional-
        // und Fernbahn); empty for assigned stations.
        let stationModes: [Int]
        // TransitRegion raw value (federal state).
        let region: String?
        let description: String
        let latitude: Double?
        let longitude: Double?
        let sourceName: String
        let organizationName: String

        init(
            id: String,
            inventoryId: String? = nil,
            stationId: String = "",
            stationName: String,
            stationModes: [Int] = [],
            region: String? = nil,
            description: String,
            latitude: Double? = nil,
            longitude: Double? = nil,
            sourceName: String = "",
            organizationName: String = ""
        ) {
            self.id = id
            self.inventoryId = inventoryId
            self.stationId = stationId
            self.stationName = stationName
            self.stationModes = stationModes
            self.region = region
            self.description = description
            self.latitude = latitude
            self.longitude = longitude
            self.sourceName = sourceName
            self.organizationName = organizationName
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            inventoryId = try c.decodeIfPresent(String.self, forKey: .inventoryId)
            stationId = try c.decodeIfPresent(String.self, forKey: .stationId) ?? ""
            stationName = try c.decodeIfPresent(String.self, forKey: .stationName) ?? ""
            stationModes = try c.decodeIfPresent([Int].self, forKey: .stationModes) ?? []
            region = try c.decodeIfPresent(String.self, forKey: .region)
            description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
            latitude = try c.decodeIfPresent(Double.self, forKey: .latitude)
            longitude = try c.decodeIfPresent(Double.self, forKey: .longitude)
            sourceName = try c.decodeIfPresent(String.self, forKey: .sourceName) ?? ""
            organizationName = try c.decodeIfPresent(String.self, forKey: .organizationName) ?? ""
        }

        private enum CodingKeys: String, CodingKey {
            case id, inventoryId, stationId, stationName, stationModes, region, description
            case latitude, longitude, sourceName, organizationName
        }

        var transitRegion: TransitRegion? { region.flatMap(TransitRegion.init(rawValue:)) }
        var networks: Set<TransitNetwork> { Set(stationModes.compactMap(TransitNetwork.init(transportModeId:))) }
    }

    struct Station: Decodable, Equatable {
        // Equipment.stationId.
        let stationId: String
        let dhid: String?
        let name: String
        let region: String?
        let latitude: Double
        let longitude: Double

        init(stationId: String, dhid: String? = nil, name: String, region: String? = nil, latitude: Double, longitude: Double) {
            self.stationId = stationId
            self.dhid = dhid
            self.name = name
            self.region = region
            self.latitude = latitude
            self.longitude = longitude
        }
    }

    // Sources behind a feature toggle that is off stay out — here, once,
    // for search, nearby, widgets and the watch alike.
    static let records: [Record] = (file?.elevators ?? []).filter { FeatureToggle.includes($0.id) }
    static let stations: [Station] = file?.stations ?? []
    static let legacyIds: [String: String] = file?.legacyIds ?? [:]

    private struct File: Decodable {
        let elevators: [Record]
        let stations: [Station]?
        let legacyIds: [String: String]?
    }

    // Pure parsing, unit-tested; `load()` only adds the bundle lookup.
    static func parse(_ data: Data) -> [Record] {
        decode(data)?.elevators ?? []
    }

    static func parseStations(_ data: Data) -> [Station] {
        decode(data)?.stations ?? []
    }

    static func parseLegacyIds(_ data: Data) -> [String: String] {
        decode(data)?.legacyIds ?? [:]
    }

    private static func decode(_ data: Data) -> File? {
        try? JSONDecoder().decode(File.self, from: data)
    }

    private static let file: File? = load()

    private static func load() -> File? {
        guard let url = Bundle.main.url(forResource: "seed-catalog", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return decode(data)
    }
}
