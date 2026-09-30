import Testing
import Foundation
@testable import HissiCore

@Suite struct FavoritesExportTests {
    // Whole seconds: the file stores ISO 8601 dates without fractions.
    private let reference = Date(timeIntervalSince1970: 1_790_000_000)

    private func favorite(_ id: String, isWorking: Bool? = false) -> MonitoredElevator {
        MonitoredElevator(
            id: id, stationId: "1", elevatorId: id,
            stationName: "S+U Pankow", elevatorDescription: "Gleis 1/2",
            isWorking: isWorking, lastChecked: reference,
            stateExplanation: isWorking == false ? "Außer Betrieb" : nil,
            addedAt: reference
        )
    }

    @Test func roundTripsInDisplayedOrder() throws {
        let export = FavoritesExport(favorites: [favorite("2"), favorite("1")], order: .manual, exportedAt: reference)
        let data = try #require(export.encoded())
        let read = try #require(FavoritesExport.decoded(from: data))
        #expect(read == export)
        #expect(read.favorites.map(\.id) == ["2", "1"])
        #expect(read.favoritesOrder == .manual)
    }

    // A status in a file is stale the moment it is written.
    @Test func leavesStatusesOut() {
        let export = FavoritesExport(favorites: [favorite("1")], order: .manual, exportedAt: reference)
        #expect(export.favorites[0].isWorking == nil)
        #expect(export.favorites[0].lastChecked == nil)
        #expect(export.favorites[0].stateExplanation == nil)
        #expect(export.favorites[0].addedAt == reference)
    }

    @Test func declaresFormatAndVersion() throws {
        let export = FavoritesExport(favorites: [], order: .recentlyAdded, exportedAt: reference)
        let data = try #require(export.encoded())
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["format"] as? String == "com.a11yland.liftboy.favorites")
        #expect(json["version"] as? Int == 1)
        #expect(json["order"] as? String == "recentlyAdded")
        // Readable as it stands: ISO 8601, not a reference-date double.
        #expect((json["exportedAt"] as? String)?.hasPrefix("2026-") == true)
    }

    @Test func rejectsForeignJSON() {
        #expect(FavoritesExport.decoded(from: Data(#"{"favorites":[]}"#.utf8)) == nil)
        #expect(FavoritesExport.decoded(from: Data("kein json".utf8)) == nil)
    }

    @Test func rejectsANewerFormatVersion() throws {
        var export = FavoritesExport(favorites: [], order: .manual, exportedAt: reference)
        export.version = FavoritesExport.currentVersion + 1
        let data = try #require(export.encoded())
        #expect(FavoritesExport.decoded(from: data) == nil)
    }

    @Test func fileNameCarriesTheDate() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        #expect(FavoritesExport.fileName(for: reference, calendar: calendar) == "Hissi-Favoriten-2026-09-21.json")
    }
}
