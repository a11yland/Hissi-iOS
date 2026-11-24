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

// "In Betrieb seit": the end of the span before, read off the span history.
@Suite struct StatusHistoryTests {
    private func spans() throws -> [Client.StatusSpan] {
        Client.parseStatusSpans(try fixtureData("status_history")).items
    }

    private func spans(of id: String) throws -> [Client.StatusSpan] {
        try spans().filter { $0.elevatorIds.contains(id) }
    }

    // out_of_service → unknown → in service: the latest span's end is the
    // moment the elevator came back.
    @Test func closedLatestSpanOfAnotherStatusGivesItsEnd() throws {
        #expect(
            StatusHistory.since(isWorking: true, spans: try spans(of: "7349"), now: fixtureNow)
                == date("2026-06-24T12:44:23.502Z")
        )
    }

    // An open outage span while the elevator reports working: unclear, so
    // no date — never the end of an older span.
    @Test func openLatestSpanGivesNothing() throws {
        #expect(StatusHistory.since(isWorking: true, spans: try spans(of: "7400"), now: fixtureNow) == nil)
    }

    @Test func closedLatestSpanOfTheSameStatusGivesNothing() throws {
        #expect(StatusHistory.since(isWorking: true, spans: try spans(of: "7401"), now: fixtureNow) == nil)
    }

    @Test func spansThatHaveNotStartedAreIgnored() {
        let past = Client.StatusSpan(
            elevatorIds: ["1"], isWorking: false,
            start: date("2026-06-01T00:00:00Z"), end: date("2026-06-02T00:00:00Z")
        )
        let planned = Client.StatusSpan(
            elevatorIds: ["1"], isWorking: false, start: fixtureNow.addingTimeInterval(86_400)
        )
        #expect(StatusHistory.since(isWorking: true, spans: [planned, past], now: fixtureNow) == past.end)
    }

    @Test func noHistoryGivesNothing() {
        #expect(StatusHistory.since(isWorking: true, spans: [], now: fixtureNow) == nil)
    }

    @Test func appliedFillsOnlyWhatIsUndated() throws {
        func favorite(_ id: String, since: Date? = nil) -> MonitoredElevator {
            MonitoredElevator(
                id: id, stationId: "1", elevatorId: id, stationName: "S", elevatorDescription: "",
                isWorking: true, lastChecked: nil, statusSince: since
            )
        }
        let known = date("2026-01-01T00:00:00Z")
        let result = StatusHistory.applied(
            to: [favorite("7349"), favorite("7349", since: known), favorite("7402")],
            spans: try spans(), now: fixtureNow
        )
        #expect(result.map(\.statusSince) == [date("2026-06-24T12:44:23.502Z"), known, nil])
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

    // The catalog cache carries no history — an undated record must not
    // erase what a targeted refresh found out.
    @Test func undatedRecordKeepsTheDateWhileTheStatusHolds() {
        let merged = StatusMerge.apply(
            equipment(isWorking: true, since: nil), to: favorite(isWorking: true, since: since)
        )
        #expect(merged.statusSince == since)
    }

    @Test func changedStatusDropsTheOldDate() {
        let merged = StatusMerge.apply(
            equipment(isWorking: true, since: nil), to: favorite(isWorking: false, since: since)
        )
        #expect(merged.statusSince == nil)
    }

    @Test func dateSurvivesTheIdMigration() {
        var seedFavorite = favorite(isWorking: true, since: since)
        seedFavorite = MonitoredElevator(
            id: "fasta-1", stationId: "1", elevatorId: "fasta-1", stationName: "S", elevatorDescription: "",
            isWorking: true, lastChecked: nil, statusSince: seedFavorite.statusSince
        )
        let merged = StatusMerge.apply(equipment(id: "101", isWorking: true, since: nil), to: seedFavorite)
        #expect(merged.id == "101")
        #expect(merged.statusSince == since)
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

private actor SpanLog {
    var requests: [Set<String>] = []
    func record(_ ids: Set<String>) { requests.append(ids) }
}

// The history costs at most one extra request, and none in the steady state.
@Suite struct StatusSinceRefreshTests {
    private let log = SpanLog()
    private let cameBack = date("2026-06-24T12:44:23.502Z")

    private func favorite(_ id: String, since: Date? = nil) -> MonitoredElevator {
        MonitoredElevator(
            id: id, stationId: "1", elevatorId: id, stationName: "S", elevatorDescription: "",
            isWorking: true, lastChecked: nil, statusSince: since
        )
    }

    private func equipment(_ id: String, since: Date? = nil) -> Client.Equipment {
        Client.Equipment(
            id: id, stationId: "1", stationName: "S", description: "", isWorking: true,
            lastUpdate: nil, statusSince: since
        )
    }

    private func sources(
        _ equipment: [Client.Equipment],
        spans: [Client.StatusSpan]? = nil,
        asksHistory: Bool = true
    ) -> StatusSources {
        let log = log
        let byId = Dictionary(uniqueKeysWithValues: equipment.map { ($0.id, $0) })
        var sources = StatusSources(equipment: { _ in byId })
        if asksHistory {
            sources.latestSpans = { ids in
                await log.record(ids)
                return spans
            }
        }
        return sources
    }

    private var history: [Client.StatusSpan] {
        [Client.StatusSpan(
            elevatorIds: ["7349"], isWorking: false,
            start: date("2026-06-23T08:34:36Z"), end: cameBack
        )]
    }

    @Test func oneRequestForExactlyTheUndatedFavorites() async {
        let known = date("2026-06-01T00:00:00Z")
        let (updated, _) = await ElevatorRefresher.refreshAll(
            [favorite("7349"), favorite("102", since: known), favorite("103")],
            sources: sources([equipment("7349"), equipment("102"), equipment("103")], spans: history)
        )
        #expect(await log.requests == [["7349", "103"]])
        #expect(updated.map(\.statusSince) == [cameBack, known, nil])
    }

    @Test func noRequestWhenEveryStatusIsDated() async {
        let known = date("2026-06-01T00:00:00Z")
        _ = await ElevatorRefresher.refreshAll(
            [favorite("101", since: known), favorite("102")],
            sources: sources([equipment("101"), equipment("102", since: known)], spans: history)
        )
        #expect(await log.requests.isEmpty)
    }

    @Test func failedHistoryRequestChangesNothing() async {
        let (updated, failed) = await ElevatorRefresher.refreshAll(
            [favorite("7349")], sources: sources([equipment("7349")], spans: nil)
        )
        #expect(updated.first?.statusSince == nil)
        #expect(updated.first?.lastChecked != nil)
        #expect(failed.isEmpty)
    }

    // A favorite the status request didn't answer for is not asked about.
    @Test func unansweredFavoritesAreNotAskedAbout() async {
        _ = await ElevatorRefresher.refreshAll(
            [favorite("7349"), favorite("999")], sources: sources([equipment("7349")], spans: history)
        )
        #expect(await log.requests == [["7349"]])
    }

    @Test func statusOnlySourcesNeverAsk() async {
        let (updated, _) = await ElevatorRefresher.refreshAll(
            [favorite("7349")], sources: sources([equipment("7349")], spans: history, asksHistory: false)
        )
        #expect(await log.requests.isEmpty)
        #expect(updated.first?.statusSince == nil)
        #expect(StatusSources.statusOnly.latestSpans == nil)
    }
}
