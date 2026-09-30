import CoreTransferable
import UniformTypeIdentifiers

// The share-sheet side of FavoritesExport: a JSON file named after the export
// date, so "In Dateien sichern", AirDrop and Mail all receive a proper file.
nonisolated struct FavoritesExportFile: Transferable {
    let export: FavoritesExport

    init(favorites: [MonitoredElevator], order: FavoritesOrder, now: Date = Date()) {
        export = FavoritesExport(favorites: favorites, order: order, exportedAt: now)
    }

    nonisolated static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .json) { (file: FavoritesExportFile) in
            guard let data = file.export.encoded() else { throw FavoritesExportError.encodingFailed }
            return data
        }
        .suggestedFileName { (file: FavoritesExportFile) in FavoritesExport.fileName(for: file.export.exportedAt) }
    }
}

private nonisolated enum FavoritesExportError: Error {
    case encodingFailed
}
