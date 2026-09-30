import Foundation
import Testing
@testable import HissiCore

// The rules behind the Live Activity ("Live-Status"). They are pure on purpose
// — the ActivityKit side is a thin shell (LiveStatusAttributes) — so everything
// that decides *what the user sees* and *when they get interrupted* is checked
// here rather than by hand on a Lock Screen.
@Suite struct LiveStatusTests {
    private func elevator(
        _ id: String,
        _ isWorking: Bool?,
        station: String? = nil,
        description: String = "",
        lastChecked: Date? = nil
    ) -> MonitoredElevator {
        MonitoredElevator(
            id: id,
            stationId: id,
            elevatorId: "1",
            stationName: station ?? id,
            elevatorDescription: description,
            isWorking: isWorking,
            lastChecked: lastChecked
        )
    }

    // MARK: - State

    // The activity carries counts, not records — and still has to say exactly
    // what the widget and the complications say (FR13).
    @Test func stateSpeaksTheSharedVerdictVocabulary() {
        let state = LiveStatusState([
            elevator("a", true),
            elevator("b", false, station: "S+U Pankow"),
            elevator("c", nil),
        ])
        #expect(state.verdict == .broken)
        #expect(state.brokenCount == 1)
        #expect(state.unknownCount == 1)
        #expect(state.total == 3)
        #expect(state.summary.label == "1 außer Betrieb")
        #expect(state.summary.detailLine == "S+U Pankow")
    }

    // The payload is capped (4 KB), so the rows are — but a broken elevator must
    // never be the one that falls off the end.
    @Test func rowsAreCappedWithBrokenSurviving() {
        let elevators = (1...6).map { elevator("e\($0)", true) } + [elevator("broken", false)]
        let state = LiveStatusState(elevators)
        #expect(state.rows.count == LiveStatusState.maxRows)
        #expect(state.rows.first?.id == "broken")
        #expect(state.total == 7)
        #expect(state.hiddenRowCount == 3)
    }

    // "Geprüft vor …" on the activity must mean the poll, not the moment the
    // state happened to be built (a favorite toggle builds one too).
    @Test func checkedAtComesFromTheElevatorsNotFromNow() {
        let polled = Date(timeIntervalSince1970: 1_700_000_000)
        let state = LiveStatusState([
            elevator("a", true, lastChecked: polled.addingTimeInterval(-600)),
            elevator("b", true, lastChecked: polled),
        ])
        #expect(state.checkedAt == polled)
    }

    // Codable is not decoration here: the state crosses into the widget
    // extension as the ContentState.
    @Test func stateSurvivesTheProcessBoundary() throws {
        let state = LiveStatusState([elevator("a", false), elevator("b", nil)])
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(LiveStatusState.self, from: data)
        #expect(decoded == state)
    }

    // MARK: - Ending

    @Test func tripEndsWhenItsTimeIsUp() {
        let endsAt = Date(timeIntervalSince1970: 1_700_000_000)
        let state = LiveStatusState([elevator("a", true)])
        #expect(!LiveStatusRules.shouldEnd(
            mode: .trip(endsAt: endsAt), state: state, now: endsAt.addingTimeInterval(-1)
        ))
        #expect(LiveStatusRules.shouldEnd(
            mode: .trip(endsAt: endsAt), state: state, now: endsAt
        ))
    }

    // A trip is a trip: it does not end early just because everything works —
    // that is precisely the news it is there to keep confirming.
    @Test func tripIgnoresTheVerdict() {
        let endsAt = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(!LiveStatusRules.shouldEnd(
            mode: .trip(endsAt: endsAt),
            state: LiveStatusState([elevator("a", true)]),
            now: endsAt.addingTimeInterval(-3600)
        ))
    }

    @Test func untilRepairedEndsOnlyOnGoodNews() {
        func ends(_ elevators: [MonitoredElevator]) -> Bool {
            LiveStatusRules.shouldEnd(
                mode: .untilRepaired,
                state: LiveStatusState(elevators),
                now: Date()
            )
        }
        #expect(!ends([elevator("a", false)]))
        // Unknown is not repaired — "unknown" must never read as an all-clear.
        #expect(!ends([elevator("a", nil)]))
        #expect(ends([elevator("a", true), elevator("b", true)]))
    }

    // Nothing left to report on: an activity over an empty favorites list would
    // sit on the Lock Screen saying nothing.
    @Test func anyModeEndsWhenTheLastFavoriteIsRemoved() {
        let empty = LiveStatusState([])
        #expect(LiveStatusRules.shouldEnd(mode: .untilRepaired, state: empty, now: Date()))
        #expect(LiveStatusRules.shouldEnd(
            mode: .trip(endsAt: Date().addingTimeInterval(3600)), state: empty, now: Date()
        ))
    }

    // MARK: - Alerts

    // The app has no notification permission and no server, so this alert is its
    // only way to interrupt — it has to be right.
    @Test func breakingAlerts() {
        let before = [elevator("a", true, station: "S+U Pankow"), elevator("b", true)]
        let after = [elevator("a", false, station: "S+U Pankow"), elevator("b", true)]
        #expect(LiveStatusAlert.transition(from: before, to: after)
            == LiveStatusAlert.broke(station: "S+U Pankow", count: 1))
    }

    @Test func repairingAlerts() {
        let before = [elevator("a", false, station: "U Vinetastr.")]
        let after = [elevator("a", true, station: "U Vinetastr.")]
        #expect(LiveStatusAlert.transition(from: before, to: after)
            == LiveStatusAlert.repaired(station: "U Vinetastr."))
    }

    // A standing disruption is not an event: re-announcing it on every refresh
    // would burn the alert's credibility within one trip.
    @Test func standingDisruptionDoesNotReAlert() {
        let same = [elevator("a", false), elevator("b", true)]
        #expect(LiveStatusAlert.transition(from: same, to: same) == nil)
    }

    // Counts alone would miss this: one breaks, one is repaired, totals
    // unchanged — and the bad news still has to win.
    @Test func comparesPerElevatorAndPrefersBadNews() {
        let before = [elevator("a", false, station: "A"), elevator("b", true, station: "B")]
        let after = [elevator("a", true, station: "A"), elevator("b", false, station: "B")]
        #expect(LiveStatusAlert.transition(from: before, to: after)
            == LiveStatusAlert.broke(station: "B", count: 1))
    }

    @Test func severalBreakingAtOnceAlertOnce() {
        let before = [elevator("a", true, station: "A"), elevator("b", true, station: "B")]
        let after = [elevator("a", false, station: "A"), elevator("b", false, station: "B")]
        #expect(LiveStatusAlert.transition(from: before, to: after)
            == LiveStatusAlert.broke(station: "A", count: 2))
    }

    // Nothing to compare against yet (a fresh start, or the app was killed and
    // adopted a running activity) — silence beats a made-up event.
    @Test func withoutAPreviousStateNothingAlerts() {
        #expect(LiveStatusAlert.transition(from: nil, to: [elevator("a", false)]) == nil)
        #expect(LiveStatusAlert.transition(from: [], to: [elevator("a", false)]) == nil)
    }

    // An elevator favorited mid-trip that arrives broken is a fact the user
    // just chose to look at, not something the live status witnessed happening.
    @Test func newlyAddedFavoritesDoNotAlert() {
        let before = [elevator("a", true)]
        let after = [elevator("a", true), elevator("new", false)]
        #expect(LiveStatusAlert.transition(from: before, to: after) == nil)
    }

    // A failed refresh keeps the previous values (FR10) — the elevator turning
    // "unknown" would be a source problem, never an alert-worthy defect.
    @Test func fallingBackToUnknownDoesNotAlert() {
        let before = [elevator("a", true)]
        let after = [elevator("a", nil)]
        #expect(LiveStatusAlert.transition(from: before, to: after) == nil)
    }

    @Test func alertTextsNameTheStation() {
        #expect(LiveStatusAlert.broke(station: "S+U Pankow", count: 1).title == "Aufzug außer Betrieb")
        #expect(LiveStatusAlert.broke(station: "S+U Pankow", count: 1).body == "S+U Pankow")
        #expect(LiveStatusAlert.broke(station: "S+U Pankow", count: 3).body == "S+U Pankow und 2 weitere")
        #expect(LiveStatusAlert.repaired(station: "U Stadtmitte").title == "Aufzug wieder in Betrieb")
    }

    // MARK: - Cadence

    // The tighter cadence is what makes a Live Activity worth having; it must
    // stay bounded to the live status (Q4, bounded request volume).
    @Test func cadenceTightensOnlyWithALiveStatus() {
        #expect(RefreshInterval.interval(liveStatusRunning: false) == RefreshInterval.seconds)
        #expect(RefreshInterval.interval(liveStatusRunning: true) == RefreshInterval.liveStatusSeconds)
        #expect(RefreshInterval.liveStatusSeconds < RefreshInterval.seconds)
    }
}
