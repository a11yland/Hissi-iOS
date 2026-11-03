import Foundation

// Bundled snapshot of the merged elevator catalog (accessibility.cloud +
// DB FaSta + brokenlifts.org), generated per release by
// scripts/generate-seed-catalog.py. Since the transit.accessibility.cloud
// migration the seed's main job is bridging pre-migration favorite ids to the
// new numeric ids (via EquipmentCatalog.overlaid): matched records carry the
// FaSta equipment number (= the operator inventory number), "fasta"- and
// "brokenlifts"-source records' ids double as the favorite ids to migrate.
// Records the platform still lacks stay searchable through the seed (status
// unknown), and its coordinates place stations for "In der Nähe" where the
// live records carry no centroid. The `stations` list is the last resort
// for that: coordinates (from the VBB GTFS, keyed by the station number)
// for the stations whose live elevators have no centroid and that no seed
// record places either — see scripts/generate-seed-catalog.py.
// The iOS app and the watch app bundle the resource (Shared/Resources, kept
// out of the two widget extensions by membership exceptions) — there
// `records` is empty.
nonisolated enum SeedCatalog {
    struct Record: Decodable, Equatable {
        let id: String
        let source: String            // "accessibilityCloud" | "fasta" | "brokenlifts"
        let acId: String?
        let fastaEquipmentNumber: Int?
        // DB station number, only on FaSta-only records.
        let stationNumber: Int?
        // VBB station number of the brokenlifts.org page and the elevator's
        // position on it, only on brokenlifts records.
        let brokenliftsStationId: String?
        let brokenliftsIndex: Int?
        let stationName: String
        let description: String
        let latitude: Double?
        let longitude: Double?
        let sourceName: String
        let organizationName: String
        // "berlin" | "brandenburg"; nil in seeds generated before the field
        // existed (the catalog then falls back to the name heuristic).
        let region: String?
    }

    struct Station: Decodable, Equatable {
        // National station number ("900100015") — Equipment.stationId.
        let stationId: String
        let dhid: String?
        let name: String
        let latitude: Double
        let longitude: Double
    }

    static let records: [Record] = file?.elevators ?? []
    static let stations: [Station] = file?.stations ?? []

    private struct File: Decodable {
        let elevators: [Record]
        // Absent in seeds generated before the list existed.
        let stations: [Station]?
    }

    // Pure parsing, unit-tested; `load()` only adds the bundle lookup.
    static func parse(_ data: Data) -> [Record] {
        (try? JSONDecoder().decode(File.self, from: data))?.elevators ?? []
    }

    static func parseStations(_ data: Data) -> [Station] {
        (try? JSONDecoder().decode(File.self, from: data))?.stations ?? []
    }

    private static let file: File? = load()

    private static func load() -> File? {
        guard let url = Bundle.main.url(forResource: "seed-catalog", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(File.self, from: data)
    }
}
