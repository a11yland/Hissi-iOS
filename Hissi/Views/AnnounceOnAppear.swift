import SwiftUI

// Speaks a transient status line to VoiceOver when it shows up. The
// "Status wird aktualisiert …" banners are silent otherwise — a VoiceOver
// user reading the rows would never learn that they are the stale phase.
extension View {
    func announceOnAppear(_ message: LocalizedStringResource) -> some View {
        onAppear { AccessibilityNotification.Announcement(String(localized: message)).post() }
    }
}
