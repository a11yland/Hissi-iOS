import Foundation
import Testing
@testable import HissiCore

// What VoiceOver hears after a favorites refresh. The package has no string
// catalog, so the German keys come back verbatim.
@Suite struct RefreshAnnouncementTests {
    private func elevator(_ id: String, _ isWorking: Bool?, station: String? = nil) -> MonitoredElevator {
        MonitoredElevator(
            id: id,
            stationId: id,
            elevatorId: "1",
            stationName: station ?? id,
            elevatorDescription: "",
            isWorking: isWorking,
            lastChecked: nil
        )
    }

    // The pull or the tap needs an answer even when nothing changed.
    @Test func userRefreshWithoutChangeSaysSo() {
        let same = [elevator("a", true)]
        #expect(RefreshAnnouncement.message(previous: same, current: same, requestedByUser: true, failed: false)
            == "Aktualisiert, keine Änderung")
    }

    // A routine poll nobody asked for stays silent unless something happened.
    @Test func routinePollWithoutChangeIsSilent() {
        let same = [elevator("a", true)]
        #expect(RefreshAnnouncement.message(previous: same, current: same, requestedByUser: false, failed: false) == nil)
    }

    // A real transition speaks on any refresh, in the alert's words.
    @Test func transitionSpeaksOnRoutinePoll() {
        let before = [elevator("a", true, station: "S+U Pankow")]
        let after = [elevator("a", false, station: "S+U Pankow")]
        #expect(RefreshAnnouncement.message(previous: before, current: after, requestedByUser: false, failed: false)
            == "Aufzug außer Betrieb: S+U Pankow")
    }

    @Test func repairSpeaks() {
        let before = [elevator("a", false, station: "U Vinetastr.")]
        let after = [elevator("a", true, station: "U Vinetastr.")]
        #expect(RefreshAnnouncement.message(previous: before, current: after, requestedByUser: true, failed: false)
            == "Aufzug wieder in Betrieb: U Vinetastr.")
    }

    // The error banner is announced on its own; "no change" would contradict it.
    @Test func failedUserRefreshDoesNotClaimNoChange() {
        let same = [elevator("a", true)]
        #expect(RefreshAnnouncement.message(previous: same, current: same, requestedByUser: true, failed: true) == nil)
    }

    // A fall back to unknown is a source failure, not news.
    @Test func fallBackToUnknownIsNoTransition() {
        let before = [elevator("a", true)]
        let after = [elevator("a", nil)]
        #expect(RefreshAnnouncement.message(previous: before, current: after, requestedByUser: false, failed: false) == nil)
    }
}
