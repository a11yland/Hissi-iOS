import Foundation

// The favorites as a file the user can hand on — to a backup, another person,
// or a successor app that shares neither the App Group nor the iCloud store
// (another developer team). A documented, versioned contract: readers check
// `format` and `version`, and fields are only ever added, never repurposed.
// Statuses are left out like in the iCloud copy (MonitoredElevator
// .withoutStatus); dates are ISO 8601 so the file is readable as it stands.
//
// Export-only in this app (FR4b): Hissi itself never imports a file — the
// favorites stay managed in the app (FR4).
nonisolated struct FavoritesExport: Codable, Equatable {
    static let formatIdentifier = "com.a11yland.liftboy.favorites"
    static let currentVersion = 1

    var format: String
    var version: Int
    var exportedAt: Date
    // FavoritesOrder raw value; unknown values fall back to the default.
    var order: String
    // In displayed order — the stored array is the displayed order.
    var favorites: [MonitoredElevator]

    init(favorites: [MonitoredElevator], order: FavoritesOrder, exportedAt: Date) {
        format = Self.formatIdentifier
        version = Self.currentVersion
        self.exportedAt = exportedAt
        self.order = order.rawValue
        self.favorites = favorites.map(\.withoutStatus)
    }

    var favoritesOrder: FavoritesOrder {
        FavoritesOrder(rawValue: order) ?? .default
    }

    func encoded() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(self)
    }

    // Nil for anything that isn't a Hissi favorites file, or one written by
    // a newer format version this reader can't vouch for.
    static func decoded(from data: Data) -> FavoritesExport? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard
            let export = try? decoder.decode(FavoritesExport.self, from: data),
            export.format == formatIdentifier,
            export.version <= currentVersion
        else { return nil }
        return export
    }

    // "Hissi-Favoriten-2026-09-27.json" — dated, so repeated exports don't
    // overwrite each other in Files.
    static func fileName(for date: Date, calendar: Calendar = .current) -> String {
        let day = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "Hissi-Favoriten-%04d-%02d-%02d.json", day.year ?? 0, day.month ?? 0, day.day ?? 0)
    }
}
