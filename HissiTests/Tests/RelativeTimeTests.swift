import Testing
import Foundation
@testable import HissiCore

private func elevator(checked: Date? = nil, updated: Date? = nil) -> MonitoredElevator {
    MonitoredElevator(
        id: "e1",
        stationId: "900193002",
        elevatorId: "e1",
        stationName: "S Adlershof (Berlin)",
        elevatorDescription: "",
        isWorking: true,
        lastChecked: checked,
        lastUpdated: updated
    )
}

// A few seconds of slack keeps the minute buckets stable regardless of test
// execution time.
private func ago(minutes: Int) -> Date {
    Date(timeIntervalSinceNow: -(Double(minutes) * 60 + 5))
}

@Suite struct RelativeTimeTests {
    @Test func underOneMinuteIsGeradeEben() {
        #expect(MonitoredElevator.relativeTime(since: Date(timeIntervalSinceNow: -10)) == "gerade eben")
    }

    @Test func minutesBucket() {
        #expect(MonitoredElevator.relativeTime(since: ago(minutes: 5)) == "vor 5 Min.")
    }

    @Test func lastMinuteBeforeHours() {
        #expect(MonitoredElevator.relativeTime(since: ago(minutes: 59)) == "vor 59 Min.")
    }

    @Test func sixtyMinutesRollsOverToHours() {
        #expect(MonitoredElevator.relativeTime(since: ago(minutes: 60)) == "vor 1 Std.")
    }

    @Test func hoursBucket() {
        #expect(MonitoredElevator.relativeTime(since: ago(minutes: 150)) == "vor 2 Std.")
    }

    @Test func lastHourBeforeDays() {
        #expect(MonitoredElevator.relativeTime(since: ago(minutes: 23 * 60)) == "vor 23 Std.")
    }

    @Test func twentyFourHoursRollsOverToSingularDay() {
        #expect(MonitoredElevator.relativeTime(since: ago(minutes: 24 * 60)) == "vor 1 Tag")
    }

    @Test func daysBucketIsPlural() {
        #expect(MonitoredElevator.relativeTime(since: ago(minutes: 3 * 24 * 60)) == "vor 3 Tagen")
    }

    // The date now follows the user's locale; the package has no string
    // catalog, so the "am %@" key falls back to its German source form.
    @Test func beyondAWeekIsAbsoluteLocalizedDate() {
        let date = Date(timeIntervalSinceNow: -400 * 24 * 60 * 60)
        let expected = "am " + date.formatted(Date.FormatStyle(date: .numeric))
        #expect(MonitoredElevator.relativeTime(since: date) == expected)
    }
}

@Suite struct ElevatorLabelTests {
    @Test func checkedLabelFallsBackWhenNil() {
        #expect(elevator(checked: nil).lastCheckedLabel == "Noch nie geprüft")
    }

    @Test func checkedLabelPrefixesRelativeTime() {
        #expect(elevator(checked: ago(minutes: 3)).lastCheckedLabel == "Geprüft vor 3 Min.")
    }

    @Test func updatedLabelFallsBackWhenNil() {
        #expect(elevator(updated: nil).lastUpdatedLabel == "Stand unbekannt")
    }

    @Test func updatedLabelPrefixesRelativeTime() {
        #expect(elevator(updated: ago(minutes: 3)).lastUpdatedLabel == "Stand vor 3 Min.")
    }
}

@Suite struct StaleDataTests {
    @Test func freshDataIsNotStale() {
        #expect(!elevator(updated: ago(minutes: 60)).isDataStale)
    }

    @Test func justUnderThresholdIsNotStale() {
        #expect(!elevator(updated: ago(minutes: (MonitoredElevator.staleAfterDays * 1440) - 10)).isDataStale)
    }

    @Test func beyondThresholdIsStale() {
        #expect(elevator(updated: ago(minutes: (MonitoredElevator.staleAfterDays + 1) * 1440)).isDataStale)
    }

    @Test func missingUpdateDateIsNotStale() {
        #expect(!elevator(updated: nil).isDataStale)
    }
}

// "Seit": how long a status has held. Fixed `now`, calendar and locale — the
// buckets must not depend on when or where the tests run.
@Suite struct SinceLabelTests {
    private let now = ISO8601DateFormatter().date(from: "2026-11-24T12:00:00Z")!
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }

    private func label(minutes: Double, spoken: Bool = false) -> String {
        MonitoredElevator.sinceLabel(
            now.addingTimeInterval(-minutes * 60), now: now, spoken: spoken,
            calendar: calendar, locale: Locale(identifier: "de_DE")
        )
    }

    @Test func minutes() {
        #expect(label(minutes: 5) == "seit 5 Min.")
        #expect(label(minutes: 59.9) == "seit 59 Min.")
    }

    // Under a minute, or a start ahead of this device's clock, is one minute.
    @Test func neverLessThanOneMinute() {
        #expect(label(minutes: 0.2) == "seit 1 Min.")
        #expect(label(minutes: -3) == "seit 1 Min.")
    }

    @Test func hours() {
        #expect(label(minutes: 60) == "seit 1 Std.")
        #expect(label(minutes: 23 * 60 + 59) == "seit 23 Std.")
    }

    @Test func days() {
        #expect(label(minutes: 24 * 60) == "seit 1 Tag")
        #expect(label(minutes: 3 * 1440) == "seit 3 Tagen")
        #expect(label(minutes: 14 * 1440 - 1) == "seit 13 Tagen")
    }

    // From the stale threshold on, a date says more than a day count.
    @Test func twoWeeksAndMoreNameTheDate() {
        #expect(label(minutes: 14 * 1440) == "seit dem 10. November")
        #expect(label(minutes: 40 * 1440) == "seit dem 15. Oktober")
    }

    @Test func anotherYearIsNamed() {
        #expect(label(minutes: 400 * 1440) == "seit dem 20. Oktober 2025")
    }

    @Test func spokenFormWritesTheUnitsOut() {
        #expect(label(minutes: 1, spoken: true) == "seit 1 Minute")
        #expect(label(minutes: 5, spoken: true) == "seit 5 Minuten")
        #expect(label(minutes: 60, spoken: true) == "seit 1 Stunde")
        #expect(label(minutes: 180, spoken: true) == "seit 3 Stunden")
        #expect(label(minutes: 3 * 1440, spoken: true) == "seit 3 Tagen")
    }

    @Test func statusSentenceCarriesTheDuration() {
        let since = now.addingTimeInterval(-3 * 86_400)
        #expect(ElevatorStatus.broken.sentence(since: since, now: now) == "Außer Betrieb seit 3 Tagen")
        #expect(ElevatorStatus.working.sentence(since: now.addingTimeInterval(-7200), now: now) == "In Betrieb seit 2 Stunden")
        #expect(ElevatorStatus.unknown.sentence(since: nil, now: now) == "Status unbekannt")
    }

    @Test func rowLabelIsLeftOutWithoutAStart() {
        #expect(elevator().statusSinceLabel(now: now) == nil)
        var dated = elevator()
        dated.statusSince = now.addingTimeInterval(-86_400)
        #expect(dated.statusSinceLabel(now: now) == "seit 1 Tag")
    }
}
