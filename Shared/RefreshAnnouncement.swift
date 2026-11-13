import Foundation

// What a finished favorites refresh says to VoiceOver users, or nil when it
// stays silent. A refresh the user asked for (pull, toolbar button) always
// answers — the gesture needs feedback; a routine poll speaks only on a real
// status change, by the live status's alert rules, so the app speaks exactly
// when an alert would and in its words. A failure has its own announcement
// (the error banner), and "no change" on top of it would contradict it.
// Same rules as Hissi-Android's MonitorViewModel.refreshAnnouncement.
nonisolated enum RefreshAnnouncement {
    static func message(
        previous: [MonitoredElevator],
        current: [MonitoredElevator],
        requestedByUser: Bool,
        failed: Bool
    ) -> String? {
        if let alert = LiveStatusAlert.transition(from: previous, to: current) {
            return "\(alert.title): \(alert.body)"
        }
        guard requestedByUser, !failed else { return nil }
        return String(localized: "Aktualisiert, keine Änderung")
    }
}
