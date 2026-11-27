import Testing
import Foundation
@testable import HissiCore

private typealias Client = AccessibilityCloudClient

private func fixtureData(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

private func date(_ iso: String) -> Date { Client.date(from: iso)! }

// After every span of the fixtures, like the other suites' fixed "now".
private let fixtureNow = date("2026-07-01T12:00:00Z")

// "Seit": the join dates a status from its current span — and from nothing
// else.
@Suite struct StatusSinceJoinTests {
    private func joined() throws -> [Client.Equipment] {
        Client.join(
            elevators: Client.parseElevators(try fixtureData("elevators")).items,
            statusSpans: Client.parseStatusSpans(try fixtureData("status_spans")).items,
            stopPlaces: Client.parseStopPlaces(try fixtureData("stop_places")).items,
            now: fixtureNow
        )
    }

    @Test func brokenElevatorIsDatedFromItsSpanStart() throws {
        let broken = try #require(try joined().first { $0.id == "101" })
        #expect(broken.statusSince == date("2026-06-01T06:00:00Z"))
    }

    // Upstream does keep a few open "operational" spans — they date a working
    // elevator just the same.
    @Test func openOperationalSpanDatesAWorkingElevator() throws {
        let equipment = try joined()
        #expect(equipment.first { $0.id == "102" }?.statusSince == date("2026-05-01T00:00:00Z"))
        #expect(equipment.first { $0.id == "103" }?.statusSince == date("2026-06-10T00:00:00Z"))
    }

    // The targeted fetch resolves the span by id — its start counts even
    // though its planned end has passed while the elevator is still broken.
    @Test func targetedJoinDatesFromTheInlineSpan() throws {
        let equipment = Client.joinTargeted(
            Client.parseElevators(try fixtureData("elevators_targeted")).items, now: fixtureNow
        )
        #expect(equipment.first { $0.id == "7187" }?.statusSince == date("2026-06-06T22:03:29.874Z"))
        // No span: the record's updatedAt is when it was touched, not when
        // the status began.
        let working = try #require(equipment.first { $0.id == "5373" })
        #expect(working.lastUpdate != nil)
        #expect(working.statusSince == nil)
    }

    @Test func spanThatDisagreesWithTheStatusDatesNothing() {
        // Back in service, the outage span not closed upstream yet.
        let span = Client.StatusSpan(id: "9", elevatorIds: ["1"], isWorking: false, start: date("2026-06-01T00:00:00Z"))
        let equipment = Client.join(
            elevators: [.init(id: "1", isWorking: true, currentStatusSpanId: "9")],
            statusSpans: [span], stopPlaces: [], now: fixtureNow
        )
        #expect(equipment.first?.isWorking == true)
        #expect(equipment.first?.statusSince == nil)
    }

    @Test func spanWithoutStartOrNotYetStartedDatesNothing() {
        let noStart = Client.StatusSpan(elevatorIds: ["1"], isWorking: false, lastUpdate: fixtureNow)
        let future = Client.StatusSpan(elevatorIds: ["1"], isWorking: false, start: fixtureNow.addingTimeInterval(60))
        #expect(Client.statusSince(isWorking: false, span: noStart, now: fixtureNow) == nil)
        #expect(Client.statusSince(isWorking: false, span: future, now: fixtureNow) == nil)
        #expect(Client.statusSince(isWorking: true, span: nil, now: fixtureNow) == nil)
    }

    // An unknown elevator takes its status from the span, so they agree.
    @Test func unknownStatusIsDatedFromAnUnknownSpan() {
        let start = date("2026-06-20T00:00:00Z")
        let span = Client.StatusSpan(elevatorIds: ["1"], isWorking: nil, start: start)
        let equipment = Client.join(
            elevators: [.init(id: "1")], statusSpans: [span], stopPlaces: [], now: fixtureNow
        )
        #expect(equipment.first?.isWorking == nil)
        #expect(equipment.first?.statusSince == start)
    }

    // The seed overlay rebuilds the record field by field — for a record the
    // seed knows and for one it doesn't.
    @Test func seedOverlayKeepsTheDate() {
        let since = date("2026-06-01T06:00:00Z")
        let seed = [SeedCatalog.Record(id: "456", stationId: "900000001", stationName: "S Teststadt", description: "Aufzug")]
        let live = ["456", "99999999"].map { id in
            Client.Equipment(
                id: id, stationId: "", stationName: "", description: "", isWorking: false,
                lastUpdate: since, statusSince: since
            )
        }
        let overlaid = EquipmentCatalog.overlaid(live: live, seed: seed, stations: [])
        #expect(overlaid.map(\.statusSince) == [since, since])
    }

    @Test func persistedCatalogWithoutTheFieldStillDecodes() throws {
        let old = #"{"id":"1","stationId":"","stationName":"S","stationNetworks":[],"description":"","sourceName":"","organizationName":""}"#
        let decoded = try JSONDecoder().decode(Client.Equipment.self, from: Data(old.utf8))
        #expect(decoded.statusSince == nil)
    }
}

// The targeted favorites request as upstream really answers it: no
// `current_status_span`, but the elevator's newest spans inline. The span
// running now gives a disruption its text and its start — in the one
// request, on every refresh.
@Suite struct TargetedSpansTests {
    private func equipment(_ id: String) throws -> Client.Equipment {
        let elevators = Client.parseElevators(try fixtureData("elevators_targeted_spans")).items
        return try #require(Client.joinTargeted(elevators, now: fixtureNow).first { $0.id == id })
    }

    // Upstream gives a running span a planned end a month ahead; it runs now.
    @Test func brokenElevatorGetsReasonAndStartFromItsRunningSpan() throws {
        let broken = try equipment("5564")
        #expect(broken.isWorking == false)
        #expect(broken.statusSince == date("2026-06-27T12:00:00.000Z"))
        #expect(broken.stateExplanation == "Aufzug außer Betrieb – Technik ist informiert.")
        #expect(broken.stationName == "Oranienburger Straße (Berlin)")
    }

    @Test func unknownStatusIsDatedFromAnUnknownSpan() throws {
        let unknown = try equipment("7377")
        #expect(unknown.isWorking == nil)
        #expect(unknown.statusSince == date("2026-06-27T02:19:09.401Z"))
        // A reason is a disruption's; "unknown" carries none.
        #expect(unknown.stateExplanation == nil)
    }

    // Only ended spans: nothing runs now, so nothing is dated and no old
    // outage text is shown.
    @Test func workingElevatorTakesNothingFromEndedSpans() throws {
        let working = try equipment("7349")
        #expect(working.isWorking == true)
        #expect(working.statusSince == nil)
        #expect(working.stateExplanation == nil)
    }

    @Test func brokenElevatorWithoutSpansStaysUndated() throws {
        let bare = try equipment("6622")
        #expect(bare.isWorking == false)
        #expect(bare.statusSince == nil)
        #expect(bare.stateExplanation == nil)
    }

    // The running span disagrees with the elevator (out of service vs.
    // unknown): its start says nothing about when the outage began.
    @Test func disagreeingRunningSpanDatesNothing() throws {
        #expect(try equipment("7400").statusSince == nil)
    }

    // Bare ids in the join (a depth=0 answer) are not spans.
    @Test func bareSpanIdsAreIgnored() throws {
        let elevators = Client.parseElevators(try fixtureData("elevators_targeted_spans")).items
        #expect(elevators.first { $0.id == "7401" }?.inlineSpans.isEmpty == true)
        #expect(elevators.first { $0.id == "5564" }?.inlineSpans.count == 3)
        #expect(try equipment("7401").statusSince == nil)
    }
}

@Suite struct StatusSinceMergeTests {
    private let since = date("2026-06-01T06:00:00Z")

    private func favorite(isWorking: Bool?, since: Date?) -> MonitoredElevator {
        MonitoredElevator(
            id: "101", stationId: "1", elevatorId: "101", stationName: "S", elevatorDescription: "",
            isWorking: isWorking, lastChecked: nil, statusSince: since
        )
    }

    private func equipment(id: String = "101", isWorking: Bool?, since: Date?) -> Client.Equipment {
        Client.Equipment(
            id: id, stationId: "1", stationName: "S", description: "", isWorking: isWorking,
            lastUpdate: nil, statusSince: since
        )
    }

    @Test func aDatedRecordWins() {
        let newer = since.addingTimeInterval(3600)
        let merged = StatusMerge.apply(
            equipment(isWorking: false, since: newer), to: favorite(isWorking: false, since: since)
        )
        #expect(merged.statusSince == newer)
    }

    // Every path dates a disruption from the span running now, so a record
    // without a date means there is none: an old date is not kept alive.
    @Test func undatedRecordClearsTheDate() {
        let merged = StatusMerge.apply(
            equipment(isWorking: false, since: nil), to: favorite(isWorking: false, since: since)
        )
        #expect(merged.statusSince == nil)
    }

    @Test func dateComesWithTheRecordThroughTheIdMigration() {
        let seedFavorite = MonitoredElevator(
            id: "fasta-1", stationId: "1", elevatorId: "fasta-1", stationName: "S", elevatorDescription: "",
            isWorking: false, lastChecked: nil
        )
        let merged = StatusMerge.apply(equipment(id: "101", isWorking: false, since: since), to: seedFavorite)
        #expect(merged.id == "101")
        #expect(merged.statusSince == since)
    }

    // Source and operator: with the seed overlaid the record is complete,
    // an empty name replaces one the favorite carries from an older seed.
    // Without the seed (watch widget extension) the favorite keeps it.
    @Test func seedBackedRecordReplacesAStaleSourceName() {
        var stale = favorite(isWorking: false, since: nil)
        stale.sourceName = "VBB Anlagen (S-Bahn)"
        stale.organizationName = "Alter Betreiber"
        let record = Client.Equipment(
            id: "101", stationId: "1", stationName: "S", description: "", isWorking: false,
            lastUpdate: nil, sourceName: "", organizationName: "DB InfraGO"
        )
        let replaced = StatusMerge.apply(record, to: stale, replacingMetadata: true)
        #expect(replaced.sourceName.isEmpty)
        #expect(replaced.organizationName == "DB InfraGO")
        let kept = StatusMerge.apply(record, to: stale, replacingMetadata: false)
        #expect(kept.sourceName == "VBB Anlagen (S-Bahn)")
        #expect(kept.organizationName == "DB InfraGO")
    }

    // The date is status: it stays out of the iCloud copy and the export,
    // and adopting a cloud list keeps the local one.
    @Test func cloudCopyCarriesNoDateAndMergeKeepsTheLocalOne() {
        let local = favorite(isWorking: false, since: since)
        #expect(local.withoutStatus.statusSince == nil)
        let cloud = FavoritesCloudSnapshot(favorites: [local], order: .recentlyAdded)
        let merged = FavoritesCloudMerge.merged(
            local: [local], localOrder: .recentlyAdded, cloud: cloud, mode: .adopt
        )
        #expect(merged.favorites.first?.statusSince == since)
    }

    @Test func cacheWithoutTheFieldStillDecodes() throws {
        let old = #"{"id":"1","stationId":"1","elevatorId":"1","stationName":"S","elevatorDescription":""}"#
        let decoded = try JSONDecoder().decode(MonitoredElevator.self, from: Data(old.utf8))
        #expect(decoded.statusSince == nil)
    }
}
