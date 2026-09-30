import Foundation

// Bundled snapshot of the merged elevator catalog (accessibility.cloud +
// DB FaSta + brokenlifts.org), generated per release by
// scripts/generate-seed-catalog.py. Since the transit.accessibility.cloud
// migration the seed's main job is bridging pre-migration favorite ids to the
// new numeric ids (via EquipmentCatalog.overlaid): matched records carry the
// FaSta equipment number (= the operator inventory number), "fasta"- and
// "brokenlifts"-source records' ids double as the favorite ids to migrate.
// Records the platform still lacks stay searchable through the seed (status
// unknown), and its coordinates are what places stations for "In der Nähe".
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

    static let records: [Record] = load()

    // Pure parsing, unit-tested; `load()` only adds the bundle lookup.
    static func parse(_ data: Data) -> [Record] {
        struct File: Decodable { let elevators: [Record] }
        return (try? JSONDecoder().decode(File.self, from: data))?.elevators ?? []
    }

    private static func load() -> [Record] {
        guard let url = Bundle.main.url(forResource: "seed-catalog", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return [] }
        return parse(data)
    }
}
