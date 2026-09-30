// Mac Catalyst has no ActivityKit either (the SDK marks it unavailable).
#if os(iOS) && !targetEnvironment(macCatalyst) && canImport(ActivityKit)
import ActivityKit
import Foundation

// The ActivityKit shell around the pure live-status model
// (Shared/LiveStatus.swift). Deliberately thin: everything that can be decided
// without ActivityKit is decided there, so it stays unit-testable on macOS.
//
// Lives in Shared/ because both sides need the type — the app requests and
// updates the activity, the widget extension renders it. Guarded by os(iOS):
// Shared/ is compiled into the watch targets and into the SwiftPM test package
// as well, and ActivityKit exists in neither.
nonisolated struct LiveStatusAttributes: ActivityAttributes {
    typealias ContentState = LiveStatusState

    // Static for the activity's lifetime: when the user started it and
    // how it is meant to end. The changing part is the ContentState.
    let startedAt: Date
    let mode: LiveStatusMode
}
#endif
