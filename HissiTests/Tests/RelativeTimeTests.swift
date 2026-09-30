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
