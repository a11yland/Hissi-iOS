// Live Activities are iOS-only — no ActivityKit on Mac Catalyst.
#if !targetEnvironment(macCatalyst)
import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

// The "Live-Status" as a Live Activity: Lock Screen and Dynamic Island for the
// duration of a trip. It shows the same aggregate verdict as every other
// glanceable surface (ElevatorSummary, FR13) and adds what only it can do —
// it is present while the phone is locked and it alerts on a status change.
//
// Unlike the accessory (Lock Screen widget) families this renders in full
// colour, so it may use the palette — the app's ground as the activity's tint,
// the mark as its identity, the status pairs — but the status is still carried
// by the symbol's shape and by words, so nothing depends on colour alone (Q2).

// The activity's ground: the palette's dark background, fixed. The system
// renders Live Activities on the Lock Screen in the dark scheme whatever the
// wallpaper, and a light tint there comes out as a saturated, unreadable
// wash under white text — so the ground is the dark purple and the content
// is pinned to the dark scheme (LiveStatusContentView), which makes every
// catalog colour resolve to its dark value.
private let liveStatusGround = Color(red: 18/255, green: 14/255, blue: 23/255)

// MARK: - Lock Screen / banner

struct LiveStatusLockScreenView: View {
    let context: ActivityViewContext<LiveStatusAttributes>

    // Three rows fit; the fourth row the state carries is for the expanded
    // Dynamic Island.
    private static let visibleRows = 3

    private var state: LiveStatusState { context.state }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if !state.rows.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(state.rows.prefix(Self.visibleRows)) { row in
                        LiveStatusRowView(row: row)
                    }
                    if state.total > Self.visibleRows {
                        Text("+ \(state.total - Self.visibleRows) weitere")
                            .font(.caption2)
                            .foregroundStyle(Color.hissiTextSecondary)
                    }
                }
            }
            footer
        }
        .padding()
        .activityBackgroundTint(liveStatusGround)
        .activitySystemActionForegroundColor(Color.accentColor)
    }

    // The mark identifies the app (no wordmark: the mark is the identity, as
    // on the watch), then the verdict in the status colours.
    private var header: some View {
        let status = state.verdict.status
        return HStack(spacing: 10) {
            LogoMark()
                .frame(height: 32)
            HStack(spacing: 6) {
                Image(systemName: state.summary.symbolName)
                    .font(.title3)
                    .foregroundStyle(status.symbolColor)
                Text(state.summary.label)
                    .font(.headline)
                    .foregroundStyle(status.textColor)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            remaining
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state.summary.identifiedLabel)
    }

    // The countdown ticks on its own, without an update — which is what keeps
    // the activity honest-looking between the refreshes it actually gets.
    @ViewBuilder
    private var remaining: some View {
        if let endsAt = context.attributes.mode.endsAt {
            VStack(alignment: .trailing, spacing: 0) {
                Text(endsAt, style: .timer)
                    .font(.caption.monospacedDigit())
                    .multilineTextAlignment(.trailing)
                Text("verbleibend")
                    .font(.caption2)
                    .foregroundStyle(Color.hissiTextSecondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Live-Status läuft noch")
        } else {
            Text(context.attributes.mode.label)
                .font(.caption2)
                .foregroundStyle(Color.hissiTextSecondary)
                .multilineTextAlignment(.trailing)
        }
    }

    private var footer: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                // The app's two-timestamp vocabulary (FR9): this is the poll
                // time, shared by the favorites list footer.
                Text("Geprüft \(MonitoredElevator.relativeTime(since: state.checkedAt))")
                    .font(.caption2)
                    .foregroundStyle(Color.hissiTextSecondary)
                if context.isStale {
                    // No push server: an update can be late. Say so instead of
                    // presenting an old status as current.
                    Label("Status möglicherweise veraltet", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(Color.hissiStatusUnknownText)
                }
            }
            Spacer(minLength: 8)
            endButton
        }
    }

    private var endButton: some View {
        Button(intent: EndLiveStatusIntent()) {
            Text("Beenden")
                .font(.caption.weight(.semibold))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .accessibilityLabel("Live-Status beenden")
    }
}

// One elevator, one line — and one VoiceOver element with a full sentence,
// like the widget rows and the accessory families.
struct LiveStatusRowView: View {
    let row: LiveStatusState.Row
    var compact: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: row.status.symbolName)
                .font(.caption2)
                .foregroundStyle(row.status.symbolColor)
            Text(row.stationName)
                .font(compact ? .caption2 : .caption)
                .fontWeight(.semibold)
                .lineLimit(1)
            if !compact, !row.elevatorDescription.isEmpty {
                Text(row.elevatorDescription)
                    .font(.caption2)
                    .foregroundStyle(Color.hissiTextSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(row.status.shortLabel)
                .font(.caption2.weight(.medium))
                .foregroundStyle(row.status.textColor)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            [row.stationName,
             row.elevatorDescription.isEmpty ? nil : row.elevatorDescription,
             row.status.label]
                .compactMap { $0 }
                .joined(separator: ", ")
        )
    }
}

// MARK: - Apple Watch (Smart Stack)

// watchOS 11 mirrors a running Live Activity into the watch's Smart Stack.
// Without a presentation of its own it shows the Dynamic Island's compact
// leading and trailing views there (symbol + "2 defekt"); this one reads like
// the watch's own rectangular complication — mark, verdict, station — plus
// what only the activity has: the countdown and the stale flag. No end
// button: interactive elements don't run on the watch, the activity is ended
// from the phone. Rendered by the phone, like the rest.
struct LiveStatusWatchView: View {
    let context: ActivityViewContext<LiveStatusAttributes>

    private var state: LiveStatusState { context.state }

    var body: some View {
        HStack(spacing: 8) {
            LogoMark()
                .frame(height: 36)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Image(systemName: state.summary.symbolName)
                        .font(.caption2)
                        .foregroundStyle(state.verdict.status.symbolColor)
                    Text(state.summary.label)
                        .font(.headline)
                        .foregroundStyle(state.verdict.status.textColor)
                        .lineLimit(1)
                }
                if let detail = state.summary.detailLine {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(Color.hissiTextSecondary)
                        .lineLimit(1)
                }
                HStack(spacing: 4) {
                    if context.isStale {
                        Label("Status möglicherweise veraltet", systemImage: "exclamationmark.triangle.fill")
                            .labelStyle(.iconOnly)
                            .foregroundStyle(Color.hissiStatusUnknownText)
                        Text("Möglicherweise veraltet")
                    } else {
                        Text("Geprüft \(MonitoredElevator.relativeTime(since: state.checkedAt))")
                    }
                    Spacer(minLength: 4)
                    if let endsAt = context.attributes.mode.endsAt {
                        Text(endsAt, style: .timer)
                            .monospacedDigit()
                            .multilineTextAlignment(.trailing)
                    }
                }
                .font(.caption2)
                .foregroundStyle(Color.hissiTextSecondary)
                .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
        .activityBackgroundTint(liveStatusGround)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            [state.summary.spokenLabel,
             state.summary.detailLine,
             context.isStale ? String(localized: "Status möglicherweise veraltet") : nil]
                .compactMap { $0 }
                .joined(separator: ", ")
        )
    }
}

// Picks the presentation by activity family: .small is the watch, .medium
// the phone's Lock Screen.
private struct LiveStatusContentView: View {
    @Environment(\.activityFamily) private var family
    let context: ActivityViewContext<LiveStatusAttributes>

    var body: some View {
        Group {
            switch family {
            case .small: LiveStatusWatchView(context: context)
            default:     LiveStatusLockScreenView(context: context)
            }
        }
        // Dark on purpose, see liveStatusGround.
        .colorScheme(.dark)
    }
}

// MARK: - Widget

struct LiveStatusActivity: Widget {
    var body: some WidgetConfiguration {
        configuration
            // Opt into the watch's Smart Stack presentation (LiveStatusWatchView).
            .supplementalActivityFamilies([.small])
    }

    private var configuration: ActivityConfiguration<LiveStatusAttributes> {
        ActivityConfiguration(for: LiveStatusAttributes.self) { context in
            LiveStatusContentView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label {
                        Text(context.state.summary.shortLabel)
                            .font(.caption.weight(.semibold))
                    } icon: {
                        Image(systemName: context.state.summary.symbolName)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(context.state.summary.identifiedLabel)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if let endsAt = context.attributes.mode.endsAt {
                        Text(endsAt, style: .timer)
                            .font(.caption.monospacedDigit())
                            .multilineTextAlignment(.trailing)
                            .accessibilityLabel("Live-Status läuft noch")
                    } else {
                        Text(context.attributes.mode.label)
                            .font(.caption2)
                            .foregroundStyle(Color.hissiTextSecondary)
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.summary.detailLine ?? String(localized: "Alle in Betrieb"))
                        .font(.caption2)
                        .foregroundStyle(Color.hissiTextSecondary)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(context.state.rows) { row in
                            LiveStatusRowView(row: row, compact: true)
                        }
                        if context.state.hiddenRowCount > 0 {
                            Text("+ \(context.state.hiddenRowCount) weitere")
                                .font(.caption2)
                                .foregroundStyle(Color.hissiTextSecondary)
                        }
                        HStack {
                            Text("Geprüft \(MonitoredElevator.relativeTime(since: context.state.checkedAt))")
                                .font(.caption2)
                                .foregroundStyle(Color.hissiTextSecondary)
                            Spacer()
                            Button(intent: EndLiveStatusIntent()) {
                                Text("Beenden")
                                    .font(.caption.weight(.semibold))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .accessibilityLabel("Live-Status beenden")
                        }
                    }
                }
            } compactLeading: {
                Image(systemName: context.state.summary.symbolName)
                    .accessibilityLabel(context.state.summary.identifiedLabel)
            } compactTrailing: {
                if #available(iOS 27.0, *) {
                    LiveStatusCompactTrailingView(summary: context.state.summary)
                } else {
                    Text(context.state.summary.shortLabel)
                        .font(.caption2)
                        .accessibilityHidden(true)
                }
            } minimal: {
                Image(systemName: context.state.summary.symbolName)
                    .accessibilityLabel(context.state.summary.identifiedShortLabel)
            }
        }
    }
}

// Since iOS 27 the compact presentation is also visible in landscape, where it
// cannot grow in width — the environment says which situation this is, and the
// verdict shrinks to its minimal form there ("2" instead of "2 defekt"; the
// compact-leading symbol keeps carrying the verdict's shape).
@available(iOS 27.0, *)
private struct LiveStatusCompactTrailingView: View {
    @Environment(\.isDynamicIslandLimitedInWidth) private var isLimitedInWidth
    let summary: ElevatorSummary

    var body: some View {
        Text(isLimitedInWidth ? summary.minimalLabel : summary.shortLabel)
            .font(.caption2)
            .accessibilityHidden(true)
    }
}

// MARK: - Previews

private extension LiveStatusState {
    static func preview(broken: Bool) -> LiveStatusState {
        let elevators = [
            ("900130002-13", "S+U Pankow", "U-Bahnsteig", true),
            ("900130011-367", "U Vinetastr.", "Bahnsteig", !broken),
            ("900100013-356", "U Spittelmarkt", "Bahnsteig", true),
            ("900100011-357", "U Stadtmitte", "Bahnsteig", true),
            ("900100014-324", "U Märkisches Museum", "Bahnsteig", true),
        ].map { id, station, description, working in
            MonitoredElevator(
                id: id,
                stationId: id,
                elevatorId: id,
                stationName: station,
                elevatorDescription: description,
                isWorking: working,
                lastChecked: .now
            )
        }
        return LiveStatusState(elevators)
    }
}

#Preview("Live Activity", as: .content, using: LiveStatusAttributes(
    startedAt: .now,
    mode: .trip(endsAt: .now.addingTimeInterval(LiveStatusMode.tripDuration))
)) {
    LiveStatusActivity()
} contentStates: {
    LiveStatusState.preview(broken: true)
    LiveStatusState.preview(broken: false)
}
#endif
