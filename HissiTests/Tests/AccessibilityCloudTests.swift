import Testing
import Foundation
@testable import HissiCore

private func fixtureData(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

// A fixed "now" between the fixtures' span starts (June 2026) and their far
// future — keeps the span selection deterministic regardless of test date.
private let fixtureNow = ISO8601DateFormatter().date(from: "2026-07-01T12:00:00Z")!

private func joinedFixtures() throws -> [AccessibilityCloudClient.Equipment] {
    AccessibilityCloudClient.join(
        elevators: AccessibilityCloudClient.parseElevators(try fixtureData("elevators")).items,
        statusSpans: AccessibilityCloudClient.parseStatusSpans(try fixtureData("status_spans")).items,
        stopPlaces: AccessibilityCloudClient.parseStopPlaces(try fixtureData("stop_places")).items,
        now: fixtureNow
    )
}

@Suite struct ParseElevatorsTests {
    @Test func parsesPayloadEnvelope() throws {
        let (elevators, hasNextPage, totalPages) = AccessibilityCloudClient.parseElevators(try fixtureData("elevators"))
        #expect(elevators.count == 5)
        #expect(hasNextPage == false)
        #expect(totalPages == 1)
    }

    @Test func normalizesNumericIdsToStrings() throws {
        let (elevators, _, _) = AccessibilityCloudClient.parseElevators(try fixtureData("elevators"))
        #expect(elevators.map(\.id) == ["101", "102", "900", "903", "103"])
        #expect(elevators.first?.stopPlaceId == "11")
    }

    @Test func carriesInventoryAndStatusSpanReferences() throws {
        let (elevators, _, _) = AccessibilityCloudClient.parseElevators(try fixtureData("elevators"))
        let first = try #require(elevators.first { $0.id == "101" })
        #expect(first.inventoryId == "10315619")
        #expect(first.currentStatusSpanId == "501")
        let second = try #require(elevators.first { $0.id == "102" })
        #expect(second.inventoryId == nil)
        #expect(second.currentStatusSpanId == nil)
    }

    @Test func decodesLocalizedAndPlainDescriptions() throws {
        let (elevators, _, _) = AccessibilityCloudClient.parseElevators(try fixtureData("elevators"))
        #expect(elevators.first { $0.id == "101" }?.description == "S-Bahnsteig Gl. 3/4 ⟷ Zugang Adlergestell")
        #expect(elevators.first { $0.id == "102" }?.description == "nur einfache Beschreibung")
    }

    @Test func decodesTheOperationalStatusEnum() throws {
        let (elevators, _, _) = AccessibilityCloudClient.parseElevators(try fixtureData("elevators"))
        #expect(elevators.first { $0.id == "101" }?.isWorking == false)
        #expect(elevators.first { $0.id == "102" }?.isWorking == true)
        // "unknown" must stay unknown, not become broken.
        #expect(elevators.first { $0.id == "103" }?.isWorking == nil)
    }

    @Test func decodesCoordinatesFromGeometryAndFlatFields() throws {
        let (elevators, _, _) = AccessibilityCloudClient.parseElevators(try fixtureData("elevators"))
        // GeoJSON order is [longitude, latitude].
        let geo = try #require(elevators.first { $0.id == "101" })
        #expect(geo.latitude == 52.43)
        #expect(geo.longitude == 13.54)
        let flat = try #require(elevators.first { $0.id == "102" })
        #expect(flat.latitude == 52.44)
    }

    // DB-feed elevators without a stop-place link have empty function maps
    // and only an internal_description.
    @Test func fallsBackToInternalDescription() {
        let json = """
        { "docs": [ { "id": 7149,
            "function": { "short_visual": { "de": null, "en": null } },
            "internal_description": "zu Gleis 1/1a" } ] }
        """
        let (elevators, _, _) = AccessibilityCloudClient.parseElevators(Data(json.utf8))
        #expect(elevators.first?.description == "zu Gleis 1/1a")
    }

    @Test func acceptsBareArrays() {
        let json = """
        [ { "id": 7, "elevator_type": "elevator" } ]
        """
        let (elevators, hasNextPage, totalPages) = AccessibilityCloudClient.parseElevators(Data(json.utf8))
        #expect(elevators.map(\.id) == ["7"])
        #expect(hasNextPage == nil)
        #expect(totalPages == nil)
    }

    @Test func unparseableDataYieldsEmpty() {
        let (elevators, _, _) = AccessibilityCloudClient.parseElevators(Data("nonsense".utf8))
        #expect(elevators.isEmpty)
    }
}

@Suite struct ParseStatusSpansTests {
    @Test func mapsOperationalStatusOntoIsWorking() throws {
        let (spans, _, _) = AccessibilityCloudClient.parseStatusSpans(try fixtureData("status_spans"))
        #expect(spans.count == 4)
        #expect(spans.first { $0.id == "501" }?.isWorking == false)
        #expect(spans.first { $0.id == "502" }?.isWorking == true)
    }

    @Test func decodesTheHasManyElevatorRelation() throws {
        let (spans, _, _) = AccessibilityCloudClient.parseStatusSpans(try fixtureData("status_spans"))
        #expect(spans.first { $0.id == "501" }?.elevatorIds == ["101"])
        let json = """
        { "docs": [ { "id": 9, "elevator": [1, 2], "operational_status": "operational" } ] }
        """
        let (multi, _, _) = AccessibilityCloudClient.parseStatusSpans(Data(json.utf8))
        #expect(multi.first?.elevatorIds == ["1", "2"])
    }

    @Test func unknownStatusWordStaysUnknownNotBroken() {
        #expect(AccessibilityCloudClient.statusMeansWorking("in_service") == true)
        #expect(AccessibilityCloudClient.statusMeansWorking("operational") == true)
        #expect(AccessibilityCloudClient.statusMeansWorking("OUT_OF_SERVICE") == false)
        // Partially operational is not reliably usable — never a false all-clear.
        #expect(AccessibilityCloudClient.statusMeansWorking("partially_operational") == false)
        #expect(AccessibilityCloudClient.statusMeansWorking("unknown") == nil)
        #expect(AccessibilityCloudClient.statusMeansWorking("mystery-state") == nil)
    }

    @Test func decodesLocalizedReason() throws {
        let (spans, _, _) = AccessibilityCloudClient.parseStatusSpans(try fixtureData("status_spans"))
        let broken = try #require(spans.first { $0.id == "501" })
        #expect(broken.reason == "Wird repariert")
    }

    @Test func parsesFractionalAndPlainTimestamps() throws {
        let (spans, _, _) = AccessibilityCloudClient.parseStatusSpans(try fixtureData("status_spans"))
        let broken = try #require(spans.first { $0.id == "501" })
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        #expect(broken.lastUpdate == fractional.date(from: "2026-06-02T08:40:01.962Z"))
        #expect(broken.start == ISO8601DateFormatter().date(from: "2026-06-01T06:00:00Z"))
    }

    @Test func unparseableTimestampBecomesNil() {
        let json = """
        { "docs": [ { "id": 1, "elevator": [5], "operational_status": "operational", "updatedAt": "not-a-date" } ] }
        """
        let (spans, _, _) = AccessibilityCloudClient.parseStatusSpans(Data(json.utf8))
        let span = spans.first
        #expect(span?.isWorking == true)    // the span still parses
        #expect(span?.lastUpdate == nil)    // only the bad timestamp drops out
    }
}

@Suite struct CurrentSpanTests {
    private func span(start: String?, end: String?, isWorking: Bool) -> AccessibilityCloudClient.StatusSpan {
        AccessibilityCloudClient.StatusSpan(
            elevatorIds: ["1"],
            isWorking: isWorking,
            start: start.flatMap { ISO8601DateFormatter().date(from: $0) },
            end: end.flatMap { ISO8601DateFormatter().date(from: $0) }
        )
    }

    @Test func openSpanCoveringNowWins() {
        let current = AccessibilityCloudClient.currentSpan(
            in: [
                span(start: "2026-01-01T00:00:00Z", end: "2026-06-01T00:00:00Z", isWorking: true),
                span(start: "2026-06-01T00:00:00Z", end: nil, isWorking: false),
            ],
            now: fixtureNow
        )
        #expect(current?.isWorking == false)
    }

    @Test func endedAndFutureSpansAreIgnored() {
        let current = AccessibilityCloudClient.currentSpan(
            in: [
                span(start: "2026-01-01T00:00:00Z", end: "2026-02-01T00:00:00Z", isWorking: false),
                span(start: "2026-12-01T00:00:00Z", end: nil, isWorking: false),
            ],
            now: fixtureNow
        )
        #expect(current == nil)
    }

    @Test func latestStartWinsAmongOverlappingSpans() {
        let current = AccessibilityCloudClient.currentSpan(
            in: [
                span(start: nil, end: nil, isWorking: true),
                span(start: "2026-06-15T00:00:00Z", end: nil, isWorking: false),
            ],
            now: fixtureNow
        )
        #expect(current?.isWorking == false)
    }
}

@Suite struct JoinTests {
    @Test func dropsEscalatorsAndMovingWalkways() throws {
        let equipment = try joinedFixtures()
        #expect(equipment.count == 3)
        #expect(equipment.allSatisfy { $0.id != "900" && $0.id != "903" })
    }

    @Test func resolvesStopPlaceIntoStationFields() throws {
        let first = try #require(try joinedFixtures().first { $0.id == "101" })
        #expect(first.stationId == "900193002")
        #expect(first.stationName == "Adlershof (Berlin)")
        #expect(first.region == .berlin)
        // The stop place's transport modes become the station's networks.
        #expect(first.stationNetworks == [.sBahn])
    }

    // The elevator's own operational_status is the live status; the current
    // status span contributes the human-readable reason.
    @Test func elevatorStatusDecidesAndSpanExplains() throws {
        let broken = try #require(try joinedFixtures().first { $0.id == "101" })
        #expect(broken.isWorking == false)
        #expect(broken.stateExplanation == "Wird repariert")
        let working = try #require(try joinedFixtures().first { $0.id == "102" })
        #expect(working.isWorking == true)
        // The reason must only surface while broken.
        #expect(working.stateExplanation == nil)
    }

    // "Stand": when the status last changed — the span's start_date, not the
    // record's updatedAt.
    @Test func spanStartBecomesLastUpdate() throws {
        let broken = try #require(try joinedFixtures().first { $0.id == "101" })
        #expect(broken.lastUpdate == ISO8601DateFormatter().date(from: "2026-06-01T06:00:00Z"))
    }

    // An elevator whose own status is "unknown" may still be settled by a
    // span covering now; its cached stop_place_name fills in for a missing
    // stop place reference.
    @Test func unknownElevatorStatusFallsBackToActiveSpan() throws {
        let standalone = try #require(try joinedFixtures().first { $0.id == "103" })
        #expect(standalone.isWorking == true)
        #expect(standalone.stationName == "U Museumsinsel (Berlin)")
    }

    @Test func noSpanAndNoElevatorStatusIsUnknown() {
        let equipment = AccessibilityCloudClient.join(
            elevators: [.init(id: "1", description: "Aufzug")],
            statusSpans: [],
            stopPlaces: [],
            now: fixtureNow
        )
        #expect(equipment.first?.isWorking == nil)
    }

    // The operator inventory number is the bridge to the seed catalog (and
    // through it to pre-migration favorites) — it must survive the join.
    @Test func inventoryIdSurvivesTheJoin() throws {
        let first = try #require(try joinedFixtures().first { $0.id == "101" })
        #expect(first.inventoryId == "10315619")
    }
}

// The targeted favorites fetch resolves the current status span inline
// (depth=1) instead of joining a separately fetched span list.
@Suite struct TargetedFetchTests {
    private func parsedFixture() throws -> [AccessibilityCloudClient.Elevator] {
        AccessibilityCloudClient.parseElevators(try fixtureData("elevators_targeted")).items
    }

    @Test func decodesThePopulatedSpanInline() throws {
        let broken = try #require(try parsedFixture().first { $0.id == "7187" })
        let span = try #require(broken.inlineStatusSpan)
        #expect(span.id == "2459")
        #expect(span.isWorking == false)
        #expect(span.reason == "Achtung! Aufzug außer Betrieb – Technik ist informiert.")
        #expect(span.start == AccessibilityCloudClient.date(from: "2026-06-06T22:03:29.874Z"))
    }

    // A bare id (depth=0 shape) or null must not masquerade as a span.
    @Test func bareIdAndNullSpanReferencesStayNil() throws {
        let elevators = try parsedFixture()
        #expect(elevators.first { $0.id == "888" }?.inlineStatusSpan == nil)
        #expect(elevators.first { $0.id == "888" }?.currentStatusSpanId == "999")
        #expect(elevators.first { $0.id == "5373" }?.inlineStatusSpan == nil)
    }

    @Test func joinResolvesInlineSpanIntoStatusAndExplanation() throws {
        let equipment = AccessibilityCloudClient.joinTargeted(try parsedFixture(), now: fixtureNow)
        let broken = try #require(equipment.first { $0.id == "7187" })
        #expect(broken.isWorking == false)
        #expect(broken.stateExplanation == "Achtung! Aufzug außer Betrieb – Technik ist informiert.")
        // "Stand" = when the status changed (span start), as in the list join.
        #expect(broken.lastUpdate == AccessibilityCloudClient.date(from: "2026-06-06T22:03:29.874Z"))
        #expect(broken.description == "Gleis 2/3")
        let working = try #require(equipment.first { $0.id == "5373" })
        #expect(working.isWorking == true)
        #expect(working.stateExplanation == nil)
    }

    // Without stop places in the response, the cached stop_place_name must
    // carry the station name.
    @Test func stationNameFallsBackToCachedStopPlaceName() throws {
        let equipment = AccessibilityCloudClient.joinTargeted(try parsedFixture(), now: fixtureNow)
        #expect(equipment.first { $0.id == "5373" }?.stationName == "S Ostkreuz (Berlin)")
    }

    @Test func dropsNonElevatorsAndSurvivesUnresolvableSpanRefs() throws {
        let equipment = AccessibilityCloudClient.joinTargeted(try parsedFixture(), now: fixtureNow)
        #expect(equipment.map(\.id) == ["7187", "5373", "888"])
        let unresolved = try #require(equipment.first { $0.id == "888" })
        // The elevator's own status decides even when its span reference
        // cannot be resolved; there is just no disruption text.
        #expect(unresolved.isWorking == false)
        #expect(unresolved.stateExplanation == nil)
    }
}

// Speculative pagination: the remembered page count of the last build lets
// all expected pages go out alongside page 1 (server time is fixed cost per
// request — waiting for page 1's count would double the build).
@Suite struct SpeculatedPagesTests {
    @Test func remembersPagesTwoThroughHint() {
        #expect(AccessibilityCloudClient.speculated(pageCountHint: 4) == [2, 3, 4])
        #expect(AccessibilityCloudClient.speculated(pageCountHint: 2) == [2])
    }

    @Test func noHintOrSinglePageMeansNoSpeculation() {
        #expect(AccessibilityCloudClient.speculated(pageCountHint: nil).isEmpty)
        #expect(AccessibilityCloudClient.speculated(pageCountHint: 1).isEmpty)
        #expect(AccessibilityCloudClient.speculated(pageCountHint: 0).isEmpty)
    }

    // A corrupt hint must not fan out into dozens of wasted requests.
    @Test func runawayHintsAreCapped() {
        #expect(AccessibilityCloudClient.speculated(pageCountHint: 999) == Array(2...20))
    }
}

// Requests carry only the app's language (plus server-side German
// fallback) instead of locale=all — the app ships de and en, so the
// resolved bundle localization is one of the two.
@Suite struct RequestLocaleTests {
    @Test func englishLocalizationsRequestEnglish() {
        #expect(AccessibilityCloudClient.requestLocale(appLocalization: "en") == "en")
        #expect(AccessibilityCloudClient.requestLocale(appLocalization: "en-GB") == "en")
    }

    // German is the development and canonical source language — it also
    // covers contexts without a resolved localization (SwiftPM tests) and,
    // defensively, anything unexpected.
    @Test func everythingElseFallsBackToGerman() {
        #expect(AccessibilityCloudClient.requestLocale(appLocalization: "de") == "de")
        #expect(AccessibilityCloudClient.requestLocale(appLocalization: nil) == "de")
        #expect(AccessibilityCloudClient.requestLocale(appLocalization: "fr") == "de")
    }
}

@Suite struct StationNumberTests {
    @Test func extractsNumberFromDhidId() {
        #expect(AccessibilityCloudClient.stationNumber(from: "de:11000:900193002") == "900193002")
    }

    @Test func fallsBackToRawIdWithoutColon() {
        #expect(AccessibilityCloudClient.stationNumber(from: "U Museumsinsel (Berlin)") == "U Museumsinsel (Berlin)")
    }

    @Test func emptyForNil() {
        #expect(AccessibilityCloudClient.stationNumber(from: nil) == "")
    }
}

@Suite struct ApplyTests {
    private func equipment(id: String = "101", lastUpdate: Date? = nil) -> AccessibilityCloudClient.Equipment {
        AccessibilityCloudClient.Equipment(
            id: id,
            stationId: "900193002",
            stationName: "S Adlershof (Berlin)",
            description: "Bahnsteig",
            isWorking: false,
            lastUpdate: lastUpdate
        )
    }

    private var placeholder: MonitoredElevator {
        MonitoredElevator(
            id: "101",
            stationId: "900193002",
            elevatorId: "101",
            stationName: "S Adlershof (Berlin)",
            elevatorDescription: "",
            isWorking: nil,
            lastChecked: nil
        )
    }

    // lastChecked reflects the poll (≈ now); lastUpdated carries the source's
    // own timestamp. A fresh poll of stale source data must keep them apart.
    @Test func separatesPollTimeFromSourceFreshness() {
        let sourceDate = Date(timeIntervalSinceNow: -3600) // an hour old
        let result = StatusMerge.apply(equipment(lastUpdate: sourceDate), to: placeholder)

        #expect(result.lastUpdated == sourceDate)
        let checked = try! #require(result.lastChecked)
        #expect(abs(checked.timeIntervalSinceNow) < 5)
    }

    @Test func nilSourceTimestampLeavesUpdatedNil() {
        let result = StatusMerge.apply(equipment(lastUpdate: nil), to: placeholder)
        #expect(result.lastUpdated == nil)
        #expect(result.lastChecked != nil)
    }

    // A seed-id favorite resolved through the inventory-number bridge comes
    // back as its live record — the favorite adopts the live identity.
    @Test func bridgedLiveRecordReplacesTheSeedIdentity() {
        let seedFavorite = MonitoredElevator(
            id: "fasta-42", stationId: "0", elevatorId: "fasta-42",
            stationName: "Alt", elevatorDescription: "", isWorking: nil, lastChecked: nil
        )
        let result = StatusMerge.apply(equipment(), to: seedFavorite)
        #expect(result.id == "101")
        #expect(result.elevatorId == "101")
        #expect(result.stationId == "900193002")
        #expect(result.isWorking == false)
        #expect(result.stationName == "S Adlershof (Berlin)")
    }

    // Source, operator and coordinates come from the seed overlay, not from
    // the API: a refresh whose record carries none of them says nothing about
    // them and must leave what the favorite already knows alone — otherwise
    // the detail view loses its map and both name rows on the next poll.
    @Test func metadatalessRefreshKeepsTheFavoritesSourceAndCoordinates() {
        let favorite = MonitoredElevator(
            id: "101", stationId: "900193002", elevatorId: "101",
            stationName: "S Adlershof (Berlin)", elevatorDescription: "Bahnsteig",
            isWorking: true, lastChecked: nil,
            sourceName: "VBB Anlagen (S-Bahn)", organizationName: "VBB",
            latitude: 52.435102, longitude: 13.540553
        )
        let result = StatusMerge.apply(equipment(), to: favorite)
        #expect(result.sourceName == "VBB Anlagen (S-Bahn)")
        #expect(result.organizationName == "VBB")
        #expect(result.latitude == 52.435102)
        #expect(result.longitude == 13.540553)
        // The status fields are the opposite case — they always win.
        #expect(result.isWorking == false)
    }

    // A non-numeric equipment id is a seed record, not a live identity — the
    // favorite keeps its own id.
    @Test func seedRecordDoesNotOverwriteTheFavoriteIdentity() {
        let favorite = MonitoredElevator(
            id: "fasta-42", stationId: "1", elevatorId: "fasta-42",
            stationName: "S Teststadt", elevatorDescription: "", isWorking: nil, lastChecked: nil
        )
        let result = StatusMerge.apply(equipment(id: "brokenlifts-900009103-0"), to: favorite)
        #expect(result.id == "fasta-42")
        #expect(result.elevatorId == "fasta-42")
    }
}
