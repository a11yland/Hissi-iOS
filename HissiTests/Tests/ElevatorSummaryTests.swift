import Testing
@testable import HissiCore

@Suite struct ElevatorSummaryTests {
    private func elevator(_ name: String, _ isWorking: Bool?) -> MonitoredElevator {
        MonitoredElevator(
            id: name,
            stationId: name,
            elevatorId: "1",
            stationName: name,
            elevatorDescription: "",
            isWorking: isWorking,
            lastChecked: nil
        )
    }

    // No favorites must never read as an all-clear.
    @Test func emptyIsItsOwnVerdict() {
        let summary = ElevatorSummary([])
        #expect(summary.verdict == .noFavorites)
        #expect(summary.label == "Keine Favoriten")
        #expect(summary.total == 0)
    }

    @Test func brokenOutranksUnknownOutranksWorking() {
        #expect(ElevatorSummary([elevator("A", false), elevator("B", nil), elevator("C", true)]).verdict == .broken)
        #expect(ElevatorSummary([elevator("A", nil), elevator("B", true)]).verdict == .unknown)
        #expect(ElevatorSummary([elevator("A", true), elevator("B", true)]).verdict == .allWorking)
    }

    @Test func countsEachState() {
        let summary = ElevatorSummary([
            elevator("A", false), elevator("B", false), elevator("C", nil), elevator("D", true),
        ])
        #expect(summary.brokenCount == 2)
        #expect(summary.unknownCount == 1)
        #expect(summary.total == 4)
        #expect(summary.label == "2 außer Betrieb")
        #expect(summary.shortLabel == "2 defekt")
    }

    // The width-limited landscape Dynamic Island gets the bare count — the
    // compact-leading symbol carries the verdict's shape.
    @Test func minimalLabelShrinksToCountOrTwoCharacters() {
        #expect(ElevatorSummary([elevator("A", false), elevator("B", false)]).minimalLabel == "2")
        #expect(ElevatorSummary([elevator("A", nil)]).minimalLabel == "?")
        #expect(ElevatorSummary([elevator("A", true)]).minimalLabel == "OK")
        #expect(ElevatorSummary([]).minimalLabel == "–")
    }

    // The corner complication's arc: full on an all-clear, otherwise the
    // affected share — a single broken favorite fills it, not empties it.
    @Test func affectedShareIsFullOnAllClearElseTheAffectedFraction() {
        #expect(ElevatorSummary([elevator("A", true), elevator("B", true)]).affectedShare == 1)
        #expect(ElevatorSummary([elevator("A", false), elevator("B", true), elevator("C", true)]).affectedShare == 1.0 / 3.0)
        #expect(ElevatorSummary([elevator("A", false), elevator("B", nil), elevator("C", true)]).affectedShare == 2.0 / 3.0)
        #expect(ElevatorSummary([elevator("A", false)]).affectedShare == 1)
        #expect(ElevatorSummary([elevator("A", nil), elevator("B", true)]).affectedShare == 0.5)
        #expect(ElevatorSummary([]).affectedShare == 0)
    }

    // The rectangular families show one station name — the broken one, even
    // when unknown records come first in the list.
    @Test func affectedStationsPutBrokenFirstAndDeduplicate() {
        let summary = ElevatorSummary([
            elevator("U Alt-Tegel", nil),
            elevator("S+U Pankow", false),
            elevator("S+U Pankow", false),
            elevator("U Stadtmitte", true),
        ])
        #expect(summary.affectedStations == ["S+U Pankow", "U Alt-Tegel"])
        #expect(summary.detailLine == "S+U Pankow")
    }

    @Test func allWorkingHasNoDetailLine() {
        #expect(ElevatorSummary([elevator("A", true)]).detailLine == nil)
        #expect(ElevatorSummary([]).detailLine == nil)
    }

    // Lock Screen and tinted watch faces flatten colour, so shape has to
    // distinguish the states on its own.
    @Test func symbolsAreDistinctPerVerdict() {
        let symbols = Set([
            ElevatorSummary([]),
            ElevatorSummary([elevator("A", false)]),
            ElevatorSummary([elevator("A", nil)]),
            ElevatorSummary([elevator("A", true)]),
        ].map(\.symbolName))
        #expect(symbols.count == 4)
    }

    // The anonymous families (inline, circular) carry the app name themselves.
    @Test func identifiedLabelsNameTheApp() {
        let summary = ElevatorSummary([elevator("A", false)])
        #expect(summary.identifiedLabel == "Hissi: 1 außer Betrieb")
        #expect(summary.identifiedShortLabel == "Hissi: 1 defekt")
    }

    // The watch face speaks the subject, not the brand, and inflects it.
    @Test func spokenLabelsNameTheLiftsNotTheApp() {
        #expect(ElevatorSummary([elevator("A", false)]).spokenLabel == "1 Lift außer Betrieb")
        #expect(ElevatorSummary([elevator("A", false), elevator("B", false)]).spokenLabel == "2 Lifte außer Betrieb")
        #expect(ElevatorSummary([elevator("A", nil)]).spokenLabel == "1 Lift unbekannt")
        #expect(ElevatorSummary([elevator("A", nil), elevator("B", nil), elevator("C", true)]).spokenLabel == "2 Lifte unbekannt")
        #expect(ElevatorSummary([elevator("A", true)]).spokenLabel == "Alle Lifte in Betrieb")
        #expect(ElevatorSummary([]).spokenLabel == "Keine Lift-Favoriten")
    }

    // The watch before its first sync ever landed: an empty mirror is not an
    // empty favorites list — it must not read as "Keine Favoriten".
    @Test func awaitingSyncSpeaksUnknownNotNoFavorites() {
        let summary = ElevatorSummary(
            verdict: .awaitingSync, brokenCount: 0, unknownCount: 0, total: 0, affectedStations: []
        )
        #expect(summary.label == "Status unbekannt")
        #expect(summary.shortLabel == "?")
        #expect(summary.detailLine == nil)
        #expect(summary.relevanceScore == 0)
    }

    // Smart Stack ranking: a broken elevator surfaces, an all-clear does not
    // crowd the stack.
    @Test func relevanceRanksBrokenHighest() {
        let broken = ElevatorSummary([elevator("A", false)]).relevanceScore
        let unknown = ElevatorSummary([elevator("A", nil)]).relevanceScore
        let working = ElevatorSummary([elevator("A", true)]).relevanceScore
        #expect(broken > unknown)
        #expect(unknown > working)
        #expect(working == 0)
        #expect(ElevatorSummary([]).relevanceScore == 0)
    }
}
