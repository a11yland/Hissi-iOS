import WidgetKit
import SwiftUI

private extension Color {
    // watchOS complications render on a dark/translucent background: the
    // palette's dark status values (#3FE0C5 → 11.5:1, #FB7185 → 7.1:1 on the
    // dark ground), spelled out — the face never switches to light.
    static let statusGreen = Color(red: 63/255,  green: 224/255, blue: 197/255)
    static let statusRed   = Color(red: 251/255, green: 113/255, blue: 133/255)
}

private func statusColor(_ working: Bool?) -> Color {
    switch working {
    case .some(true):  .statusGreen
    case .some(false): .statusRed
    case .none:        .secondary
    }
}

// MARK: - Fetching

private func fetchAllElevators() async -> [MonitoredElevator] {
    // On the watch the favorites live on the phone; the watch app mirrors them
    // into ElevatorCache via WatchConnectivity. Use that as the membership and
    // refresh the statuses, falling back to the cached values on failure.
    let cached = ElevatorCache.load()
    guard !cached.isEmpty else { return [] }
    // A reload right after the sync mirrored fresh statuses (which is what
    // triggers it) answers from them instead of fetching the same data again.
    if let checked = cached.compactMap(\.lastChecked).max(),
       Date().timeIntervalSince(checked) < RefreshInterval.cacheReuseSeconds {
        return cached
    }
    let (updated, _) = await ElevatorRefresher.refreshAll(cached)
    ElevatorCache.save(updated)
    return updated
}

// MARK: - Timeline

struct LiftEntry: TimelineEntry {
    let date: Date
    let elevators: [MonitoredElevator]
    // False until the first favorites sync has ever been mirrored — an empty
    // cache then means "membership unknown", not "no favorites".
    var membershipKnown: Bool = true

    // The aggregate verdict — shared with the iOS widget so the same situation
    // reads the same on the wrist and on the phone.
    var summary: ElevatorSummary {
        guard elevators.isEmpty, !membershipKnown else { return ElevatorSummary(elevators) }
        // The phone may well have favorites — "Keine Favoriten" would be a
        // false statement, the same honesty that makes noFavorites its own case.
        return ElevatorSummary(
            verdict: .awaitingSync,
            brokenCount: 0,
            unknownCount: 0,
            total: 0,
            affectedStations: []
        )
    }

    // Ranking in the Smart Stack: watchOS surfaces the widget on its own when
    // something is broken, keeps it available on unknown status, and leaves an
    // all-clear at baseline so it doesn't push aside what the user put there.
    var relevance: TimelineEntryRelevance? {
        TimelineEntryRelevance(score: summary.relevanceScore)
    }
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> LiftEntry {
        LiftEntry(date: .now, elevators: previewElevators(showBroken: true))
    }

    func getSnapshot(in context: Context, completion: @escaping (LiftEntry) -> Void) {
        // Snapshot must render fast: preview data in the gallery, otherwise the
        // mirrored cache — no network round-trip. getTimeline does the live fetch.
        let elevators = context.isPreview ? previewElevators(showBroken: true) : ElevatorCache.load()
        completion(LiftEntry(date: .now, elevators: elevators, membershipKnown: ElevatorCache.hasStoredOnce))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LiftEntry>) -> Void) {
        Task {
            let elevators = await fetchAllElevators()
            let now = Date.now
            // The complications show status only (no data-age display), so a
            // single entry per refresh interval suffices.
            let next = Calendar.current.date(byAdding: .minute, value: RefreshInterval.minutes, to: now) ?? now
            completion(Timeline(
                entries: [LiftEntry(date: now, elevators: elevators, membershipKnown: ElevatorCache.hasStoredOnce)],
                policy: .after(next)
            ))
        }
    }
}

private func previewElevators(showBroken: Bool) -> [MonitoredElevator] {
    [
        ("900130002", "13",  "S+U Pankow",          true),
        ("900130011", "367", "U Vinetastr.",        !showBroken),
        ("900100014", "324", "U Märkisches Museum", true),
        ("900100013", "356", "U Spittelmarkt",      true),
        ("900100011", "357", "U Stadtmitte",        !showBroken),
    ].map { s, e, name, working in
        MonitoredElevator(
            id: "\(s)-\(e)",
            stationId: s,
            elevatorId: e,
            stationName: name,
            elevatorDescription: "",
            isWorking: working,
            lastChecked: .now
        )
    }
}

// MARK: - Views

struct CircularComplicationView: View {
    let entry: LiftEntry

    private var ringColor: Color {
        switch entry.summary.verdict {
        case .allWorking:                           .statusGreen
        case .broken:                               .statusRed
        case .unknown, .noFavorites, .awaitingSync: .secondary
        }
    }

    // Carried in the symbol's shape for sighted users — colour is flattened on
    // tinted faces. Bare glyphs, not ElevatorSummary's filled symbols: they sit
    // inside the ring, which already supplies the enclosing shape.
    private var symbolName: String {
        switch entry.summary.verdict {
        case .allWorking:             "checkmark"
        case .broken:                 "exclamationmark"
        case .unknown, .awaitingSync: "questionmark"
        case .noFavorites:            "star"
        }
    }

    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            Circle()
                .stroke(ringColor, lineWidth: 3)
                .padding(2)
            Image(systemName: symbolName)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundStyle(ringColor)
        }
        .containerBackground(.clear, for: .widget)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.summary.spokenLabel)
    }
}

// Also the Smart Stack's face on watchOS 10+: it is the widest family the
// stack shows, so it gets the extra line the small faces have no room for.
// The mark on the left is the identity (no wordmark — same layout as the
// nearby and empty faces), which frees the height for the station line.
struct RectangularComplicationView: View {
    let entry: LiftEntry

    private var statusColor: Color {
        switch entry.summary.verdict {
        case .allWorking:                           .statusGreen
        case .broken:                               .statusRed
        case .unknown, .noFavorites, .awaitingSync: .secondary
        }
    }

    // Which stations are actually affected — an all-clear needs no
    // elaboration, and the per-elevator list stays in the watch app.
    private var stations: String? {
        entry.summary.affectedStations.isEmpty ? nil : entry.summary.affectedStations.joined(separator: ", ")
    }

    var body: some View {
        HStack(spacing: 8) {
            LogoMark()
                .frame(height: 36)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Image(systemName: entry.summary.symbolName)
                        .font(.caption2)
                    Text(entry.summary.label)
                        .font(.headline)
                        .lineLimit(1)
                }
                .foregroundStyle(statusColor)
                if let stations {
                    Text(stations)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .containerBackground(.clear, for: .widget)
        // One element, one sentence — not name/status/station as three stops.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            [entry.summary.spokenLabel, stations]
                .compactMap { $0 }
                .joined(separator: ", ")
        )
    }
}

struct InlineComplicationView: View {
    let entry: LiftEntry
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        // The mark is the identity; the status text alone is unambiguous
        // even in the family's monochrome rendering.
        Label {
            Text(entry.summary.shortLabel)
        } icon: {
            LogoMark.image(pointSize: 18, scale: displayScale)
        }
        .containerBackground(.clear, for: .widget)
        // The short text is for the line's width; VoiceOver gets the full
        // sentence like every other family — "?" would be read out as a
        // question mark.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.summary.spokenLabel)
    }
}

struct CornerComplicationView: View {
    let entry: LiftEntry

    private var statusColor: Color {
        switch entry.summary.verdict {
        case .allWorking:                           .statusGreen
        case .broken:                               .statusRed
        case .unknown, .noFavorites, .awaitingSync: .secondary
        }
    }

    // The tightest surface there is: verdict only, no count — the status
    // word has to stay legible in the corner. The arc along the bezel adds
    // the share (ElevatorSummary.affectedShare) in the verdict's colour.
    private var statusLabel: String {
        switch entry.summary.verdict {
        case .allWorking:                           "OK"
        case .broken:                               String(localized: "DEFEKT")
        case .unknown, .noFavorites, .awaitingSync: "?"
        }
    }

    var body: some View {
        Text(statusLabel)
            .font(.system(.title3, design: .rounded).weight(.semibold))
            .foregroundStyle(statusColor)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .widgetLabel {
                // Colour only, no words: the word is inside. On tinted faces
                // the arc flattens to the tint and the word carries the status.
                Gauge(value: entry.summary.affectedShare, in: 0...1) { EmptyView() }
                    .tint(statusColor)
                    // The system renders the label outside this view's
                    // element, so a gauge would otherwise announce its
                    // percentage as a second stop.
                    .accessibilityHidden(true)
            }
            .containerBackground(.clear, for: .widget)
            // The abbreviated status word is for the corner's space, not for
            // VoiceOver — announce the full sentence like every other family.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(entry.summary.spokenLabel)
    }
}

// Nothing to monitor: with an empty mirror (no favorites, or none synced yet
// — the watch can't tell the two apart, and neither is actionable on the
// wrist) the complication shows the app's mark instead of a verdict. The
// small families carry the mark alone, the wide ones say "Keine Favoriten"
// next to it. VoiceOver says "Keine Lift-Favoriten" everywhere — the sync
// distinction is not worth a second wording.
private struct EmptyComplicationView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.displayScale) private var displayScale

    private var label: String { ElevatorSummary([]).label }

    var body: some View {
        Group {
            switch family {
            case .accessoryRectangular:
                HStack(spacing: 8) {
                    LogoMark()
                        .frame(height: 36)
                    Text(label)
                        .font(.headline)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

            case .accessoryInline:
                Label {
                    Text(label)
                } icon: {
                    LogoMark.image(pointSize: 18, scale: displayScale)
                }

            case .accessoryCorner:
                LogoMark()
                    .frame(width: 26, height: 26)

            default:
                ZStack {
                    AccessoryWidgetBackground()
                    LogoMark()
                        .padding(9)
                }
            }
        }
        .containerBackground(.clear, for: .widget)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ElevatorSummary([]).spokenLabel)
    }
}

struct HissiWatchWidgetEntryView: View {
    @Environment(\.widgetFamily) var family
    let entry: LiftEntry

    var body: some View {
        if entry.elevators.isEmpty {
            EmptyComplicationView()
        } else {
            statusView
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch family {
        case .accessoryCircular:    CircularComplicationView(entry: entry)
        case .accessoryRectangular: RectangularComplicationView(entry: entry)
        case .accessoryInline:      InlineComplicationView(entry: entry)
        case .accessoryCorner:      CornerComplicationView(entry: entry)
        default:                    CircularComplicationView(entry: entry)
        }
    }
}

// MARK: - Widgets

// Two complications: the status (hero, listed first) and the nearby launcher
// (NearbyComplication.swift). The bundle's order is the picker's order.
@main
struct HissiWatchWidgetBundle: WidgetBundle {
    var body: some Widget {
        HissiWatchWidget()
        NearbyComplication()
    }
}

struct HissiWatchWidget: Widget {
    // The picker already groups under the app name, so the display name says
    // what the complication shows instead of repeating "Hissi". The kind is
    // the identity and stays put — changing it would drop the complication off
    // every watch face it is already on.
    let kind = "HissiWatchWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            HissiWatchWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Aufzug-Status")
        .description("Status der überwachten Aufzüge.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline, .accessoryCorner])
    }
}

// MARK: - Previews

#Preview("Circular OK", as: .accessoryCircular) {
    HissiWatchWidget()
} timeline: {
    LiftEntry(date: .now, elevators: previewElevators(showBroken: false))
}

#Preview("Circular broken", as: .accessoryCircular) {
    HissiWatchWidget()
} timeline: {
    LiftEntry(date: .now, elevators: previewElevators(showBroken: true))
}

// Also what the Smart Stack shows on watchOS 10+.
#Preview("Rectangular", as: .accessoryRectangular) {
    HissiWatchWidget()
} timeline: {
    LiftEntry(date: .now, elevators: previewElevators(showBroken: true))
    LiftEntry(date: .now, elevators: previewElevators(showBroken: false))
    // Empty mirror: the app's mark.
    LiftEntry(date: .now, elevators: [])
}

#Preview("Inline", as: .accessoryInline) {
    HissiWatchWidget()
} timeline: {
    LiftEntry(date: .now, elevators: previewElevators(showBroken: true))
}

#Preview("Corner", as: .accessoryCorner) {
    HissiWatchWidget()
} timeline: {
    LiftEntry(date: .now, elevators: previewElevators(showBroken: false))
}
