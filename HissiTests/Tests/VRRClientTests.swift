import Testing
import Foundation
@testable import HissiCore

private func fixtureData(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

// After every timestamp in the fixture but one (a lift "broken since"
// August, i.e. the future from here).
private let fixtureNow = ISO8601DateFormatter().date(from: "2026-07-01T12:00:00Z")!

// The VRR infrastructure feed, parsed into the catalog's records. The
// fixture is a trimmed copy of the live answer with invented names.
@Suite struct VRRClientTests {
    private func parsed() throws -> [AccessibilityCloudClient.Equipment] {
        try #require(VRRClient.parse(try fixtureData("vrr_infrastructure"), now: fixtureNow))
    }

    private func lift(_ resourceId: String) throws -> AccessibilityCloudClient.Equipment {
        try #require(try parsed().first { $0.id == "vrr:\(resourceId)" })
    }

    // Escalators and ramps are left out; a stop without a lift yields none.
    @Test func keepsElevatorsOnly() throws {
        #expect(try parsed().map(\.id) == [
            "vrr:de:05112:16580:31",
            "vrr:de:05111:18250:31", "vrr:de:05111:18250:32", "vrr:de:05111:18250:33", "vrr:de:05111:18250:34",
            "vrr:de:05911:5554:31", "vrr:de:05911:5554:32",
        ])
        #expect(try parsed().allSatisfy { ElevatorSource(id: $0.id) == .vrr })
    }

    @Test func identityStationAndRegion() throws {
        let working = try lift("de:05112:16580:31")
        // The stop's full DHID — its last segment alone is not unique.
        #expect(working.stationId == "de:05112:16580")
        #expect(working.stationName == "Duisburg Duissern U-Bf")
        #expect(working.description == "Straßenebene (nahe Eingang Duissernplatz) zum Bahnsteig")
        #expect(working.region == .nordrheinWestfalen)
        #expect(working.sourceName == "VRR")
        #expect(working.organizationName.isEmpty)
        // Whitespace in the feed's names is collapsed.
        #expect(try lift("de:05911:5554:32").stationName == "Bochum Gesundheitscampus")
    }

    @Test func statusWords() throws {
        #expect(try lift("de:05112:16580:31").isWorking == true)
        #expect(try lift("de:05111:18250:31").isWorking == false)
        // No state at all, or a word this version doesn't know: unknown —
        // never a false "working".
        #expect(try lift("de:05111:18250:33").isWorking == nil)
        #expect(try lift("de:05111:18250:34").isWorking == nil)
        #expect(VRRClient.statusMeansWorking(" In Ordnung ") == true)
        #expect(VRRClient.statusMeansWorking(nil) == nil)
    }

    // "Seit" is the state's timestamp — with a known status only, and never
    // a moment still ahead.
    @Test func statusSinceIsTheStateChange() throws {
        #expect(try lift("de:05112:16580:31").statusSince == AccessibilityCloudClient.date(from: "2026-05-28T14:19:06.000Z"))
        #expect(try lift("de:05111:18250:31").statusSince == AccessibilityCloudClient.date(from: "2026-06-19T22:13:55.000Z"))
        #expect(try lift("de:05111:18250:34").statusSince == nil)
        #expect(try lift("de:05911:5554:32").isWorking == false)
        #expect(try lift("de:05911:5554:32").statusSince == nil)
    }

    // "Datenstand" is the moment of the answer, so a lift that has simply
    // worked for weeks is not flagged as stale.
    @Test func dataAgeIsTheFetchTime() throws {
        #expect(try parsed().allSatisfy { $0.lastUpdate == fixtureNow })
    }

    // Known status codes are shown in the app's words; operator free text —
    // here a ticket note with a name — never is.
    @Test func explanationComesFromAnAllowlist() throws {
        #expect(try lift("de:05111:18250:31").stateExplanation == "Kein Betrieb")
        #expect(try lift("de:05911:5554:32").stateExplanation == "Störung (Personenbefreiung)")
        #expect(try lift("de:05111:18250:32").isWorking == false)
        #expect(try lift("de:05111:18250:32").stateExplanation == nil)
        // A working lift carries no reason, whatever the feed says.
        #expect(try lift("de:05112:16580:31").stateExplanation == nil)
        #expect(VRRClient.explanation("Fernabschaltung") == "Ferngesteuert abgeschaltet")
        #expect(VRRClient.explanation("nicht betriebsbereit") == "Nicht betriebsbereit")
        #expect(VRRClient.explanation("Stoerung") == nil)
        #expect(VRRClient.explanation("") == nil)
    }

    @Test func coordinateIsTheLiftsOwnWhenPlausible() throws {
        let own = try lift("de:05112:16580:31")
        #expect(own.latitude == 51.43889)
        #expect(own.longitude == 6.78278)
        // None of its own: the stop's.
        let missing = try lift("de:05111:18250:32")
        #expect(missing.latitude == 51.213707)
        #expect(missing.longitude == 6.774519)
        // Far from its stop (the feed has lifts in the Norwegian Sea): the
        // stop's.
        let misplaced = try lift("de:05111:18250:33")
        #expect(misplaced.latitude == 51.213707)
        #expect(misplaced.longitude == 6.774519)
    }

    // The feed lists a lift twice now and then; the fuller description wins.
    @Test func duplicateResourceIdsCollapse() throws {
        let records = try parsed().filter { $0.id == "vrr:de:05911:5554:31" }
        #expect(records.count == 1)
        #expect(records.first?.description == "Run11 - Zugang Uni-Center zum Bahnsteig")
    }

    @Test func unexpectedDataIsAFailureNotAnEmptyList() {
        #expect(VRRClient.parse(Data("nonsense".utf8)) == nil)
        #expect(VRRClient.parse(Data(#"{"error":"Authorization required"}"#.utf8)) == nil)
        #expect(VRRClient.parse(Data("[]".utf8)) == [])
    }
}
