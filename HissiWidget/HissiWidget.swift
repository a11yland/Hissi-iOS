import WidgetKit
import SwiftUI
import UIKit

// Internal, not private: the Live Activity (LiveStatusActivity.swift) and the
// nearby widget draw the same palette. Unlike the accessory families the
// Home Screen families render in full colour, so they can use it: the app's
// cream/dark ground, the status pairs (symbol colour + darker text variant)
// and the mark as the app's identity in the tile.
extension ElevatorSummary.Verdict {
    // The verdict as a status, for its colours: anything that is not a clear
    // "broken" or "all working" reads as unknown.
    var status: ElevatorStatus {
        switch self {
        case .broken:     .broken
        case .allWorking: .working
        case .unknown, .noFavorites, .awaitingSync: .unknown
        }
    }
}

extension View {
    // The palette's ground behind a Home Screen family.
    func hissiWidgetBackground() -> some View {
        containerBackground(Color.hissiBackground, for: .widget)
    }
}

// The mark as the tile's identity, sized to sit in a caption line.
struct WidgetMark: View {
    var height: CGFloat = 16

    var body: some View {
        LogoMark()
            .frame(height: height)
            .accessibilityHidden(true)
    }
}

private func statusLabel(_ working: Bool?) -> String {
    ElevatorStatus(isWorking: working).shortLabel
}

private func statusText(_ text: String, _ status: ElevatorStatus) -> some View {
    Text(text).foregroundStyle(status.textColor)
}

// MARK: - Fetching

// Favorites (membership + index) overlaid with the iPhone app's cache for the
// freshest known status. No network — used for fast snapshots.
private func cachedElevators() -> [MonitoredElevator] {
    let cache = ElevatorCache.load()
    return FavoritesStore.load().map { favorite -> MonitoredElevator in
        guard var merged = cache.first(where: { $0.id == favorite.id }) else { return favorite }
        merged.elevatorIndex = favorite.elevatorIndex
        return merged
    }
}

private func fetchAllElevators() async -> [MonitoredElevator] {
    // Two widget kinds share this logic and reload together — when the cache
    // was written moments ago (the other kind, or the app right before it
    // reloaded the timelines), answer from it instead of repeating the fetch.
    let cached = cachedElevators()
    if let checked = cached.compactMap(\.lastChecked).max(),
       Date().timeIntervalSince(checked) < RefreshInterval.cacheReuseSeconds {
        return cached
    }
    // Migrated ids are deliberately not persisted here — the widget mirrors
    // the favorites, the app owns them and persists the migration on its next
    // refresh; the catalog resolves old ids via legacyId either way.
    let (updated, _) = await ElevatorRefresher.refreshAll(cached)
    ElevatorCache.save(updated)
    return updated
}

// MARK: - Timeline

struct LiftEntry: TimelineEntry {
    let date: Date
    let elevators: [MonitoredElevator]

    // The aggregate verdict — shared with the watch complications so the same
    // situation reads the same on every surface.
    var summary: ElevatorSummary { ElevatorSummary(elevators) }
    var brokenCount: Int { summary.brokenCount }
    var unknownCount: Int { summary.unknownCount }

    // Rank in the Smart Stack: a broken elevator ranks highest, unknown status
    // mid, all-clear stays at baseline so it doesn't crowd the stack.
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
        // cache — no network round-trip. getTimeline does the live fetch.
        let elevators = context.isPreview ? previewElevators(showBroken: true) : cachedElevators()
        completion(LiftEntry(date: .now, elevators: elevators))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LiftEntry>) -> Void) {
        Task {
            let elevators = await fetchAllElevators()
            let entry = LiftEntry(date: .now, elevators: elevators)
            let next = Calendar.current.date(byAdding: .minute, value: RefreshInterval.minutes, to: .now) ?? .now
            completion(Timeline(entries: [entry], policy: .after(next)))
        }
    }
}

private func previewElevators(showBroken: Bool) -> [MonitoredElevator] {
    // Six, not four: enough to fill the large family and to make medium show
    // its "+ n weitere" overflow line in the gallery preview.
    [
        ("900130002", "13", "S+U Pankow", "U-Bahnsteig", true),
        ("900130011", "367", "U Vinetastr.", "Bahnsteig", !showBroken),
        ("900100013", "356", "U Spittelmarkt", "Bahnsteig", true),
        ("900100011", "357", "U Stadtmitte", "Bahnsteig", !showBroken),
        ("900100014", "324", "U Märkisches Museum", "Bahnsteig", true),
        ("900120005", "412", "S Ostkreuz", "Zugang Sonntagstr.", true),
    ].map { s, e, name, desc, working in
        MonitoredElevator(
            id: "\(s)-\(e)",
            stationId: s,
            elevatorId: e,
            stationName: name,
            elevatorDescription: desc,
            isWorking: working,
            lastChecked: .now
        )
    }
}

// MARK: - Views

struct HissiWidgetSmallView: View {
    let entry: LiftEntry

    var body: some View {
        VStack(spacing: 6) {
            // The mark, top-leading, is the tile's identity; the verdict below
            // it gets the rest of the room.
            WidgetMark()
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            if entry.elevators.isEmpty {
                // Without favorites there is nothing to monitor — "Alle in
                // Betrieb" here would be a false all-clear.
                Image(systemName: "star")
                    .font(.title2)
                    .foregroundStyle(Color.hissiTextSecondary)
                Text("Keine Favoriten")
                    .font(.caption)
                    .foregroundStyle(Color.hissiTextSecondary)
            } else if entry.brokenCount > 0 {
                verdict(.broken, number: "\(entry.brokenCount)", caption: "außer Betrieb")
            } else if entry.unknownCount > 0 {
                verdict(.unknown, number: "\(entry.unknownCount)", caption: "unbekannt")
            } else {
                verdict(.working, number: String(localized: "Alle"), caption: "in Betrieb")
            }
            Spacer(minLength: 0)
        }
        .hissiWidgetBackground()
        // One element, one sentence — instead of symbol/number/caption as
        // three separate VoiceOver stops. The widget's app identity comes
        // from the system (widget display name).
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.summary.label)
    }

    @ViewBuilder
    private func verdict(_ status: ElevatorStatus, number: String, caption: LocalizedStringKey) -> some View {
        Image(systemName: status.symbolName)
            .font(.title2)
            .foregroundStyle(status.symbolColor)
        Text(number)
            .font(.system(size: 32, weight: .bold, design: .rounded))
            .foregroundStyle(status.textColor)
        Text(caption)
            .font(.caption2)
            .foregroundStyle(Color.hissiTextSecondary)
    }
}

// Shared by systemMedium and systemLarge: same rows, different cap. Both
// open with a header line — the mark as the tile's identity and the
// aggregate verdict — which is why medium fits three rows, not four.
struct HissiWidgetListView: View {
    let entry: LiftEntry
    let maxRows: Int

    // Broken elevators must survive the cap — the shared urgency order, which
    // the Live Activity's row list uses as well.
    private var ranked: [MonitoredElevator] { ElevatorRanking.byUrgency(entry.elevators) }

    var body: some View {
        Group {
            if entry.elevators.isEmpty {
                VStack(spacing: 6) {
                    WidgetMark()
                    Image(systemName: "star")
                        .font(.title3)
                        .foregroundStyle(Color.hissiTextSecondary)
                    Text("Keine Favoriten")
                        .font(.caption)
                        .foregroundStyle(Color.hissiTextSecondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    header
                    ForEach(ranked.prefix(maxRows)) { elevator in
                        row(elevator)
                    }
                    if entry.elevators.count > maxRows {
                        Text("+ \(entry.elevators.count - maxRows) weitere")
                            .font(.caption2)
                            .foregroundStyle(Color.hissiTextSecondary)
                    }
                    // Taller than its content whenever there are few
                    // favorites — pin the rows to the top instead of letting
                    // them float in the middle of the tile.
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 4)
            }
        }
        .hissiWidgetBackground()
    }

    private var header: some View {
        let status = entry.summary.verdict.status
        return HStack(spacing: 6) {
            WidgetMark()
            Image(systemName: entry.summary.symbolName)
                .font(.caption)
                .foregroundStyle(status.symbolColor)
            Text(entry.summary.label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(status.textColor)
                .lineLimit(1)
            Spacer()
        }
        .padding(.bottom, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.summary.label)
    }

    private func row(_ elevator: MonitoredElevator) -> some View {
        let status = ElevatorStatus(isWorking: elevator.isWorking)
        return HStack(spacing: 8) {
            Image(systemName: status.symbolName)
                .font(.caption)
                .foregroundStyle(status.symbolColor)
            VStack(alignment: .leading, spacing: 0) {
                Text(elevator.stationName)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                if !elevator.elevatorDescription.isEmpty {
                    Text(elevator.elevatorDescription)
                        .font(.caption2)
                        .foregroundStyle(Color.hissiTextSecondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            statusText(statusLabel(elevator.isWorking), status)
                .font(.caption2.weight(.medium))
        }
        // One row, one sentence for VoiceOver.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibleRow(elevator, status: status))
    }

    private func accessibleRow(_ elevator: MonitoredElevator, status: ElevatorStatus) -> String {
        [elevator.stationName,
         elevator.elevatorDescription.isEmpty ? nil : elevator.elevatorDescription,
         status.label]
            .compactMap { $0 }
            .joined(separator: ", ")
    }
}

// MARK: - Lock Screen / StandBy (accessory families)

// The Lock Screen renders widgets in vibrant mode, which flattens everything to
// a single tint — so these views carry the status in the symbol's *shape* and
// in words, never in colour, and skip the app's status palette entirely. They
// show the same aggregate verdict as the watch complications (FR13); the
// per-elevator list stays with the Home Screen families and the app.

struct HissiAccessoryCircularView: View {
    let entry: LiftEntry

    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            Image(systemName: entry.summary.symbolName)
                .font(.system(size: 20, weight: .semibold))
        }
        .containerBackground(.clear, for: .widget)
        .accessibilityElement(children: .ignore)
        // Visually anonymous by design — the little space there is goes to the
        // status shape, so the app name has to come from the label (FR16).
        .accessibilityLabel(entry.summary.identifiedLabel)
    }
}

struct HissiAccessoryRectangularView: View {
    let entry: LiftEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Image(systemName: entry.summary.symbolName)
                    .font(.caption2)
                Text("Hissi")
                    .font(.headline)
            }
            Text(entry.summary.label)
                .font(.caption)
                .lineLimit(1)
            // Three lines is what the family fits, so the third one names the
            // station actually affected — an all-clear needs no elaboration.
            if let detail = entry.summary.detailLine {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .containerBackground(.clear, for: .widget)
        // One element, one sentence — not name/status/station as three stops.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            [entry.summary.identifiedLabel, entry.summary.detailLine]
                .compactMap { $0 }
                .joined(separator: ", ")
        )
    }
}

struct HissiAccessoryInlineView: View {
    let entry: LiftEntry

    // One line next to the Lock Screen clock — the shortest form, and it has to
    // name the app itself since nothing around it does.
    var body: some View {
        Text(entry.summary.identifiedShortLabel)
            .containerBackground(.clear, for: .widget)
    }
}

struct HissiWidgetEntryView: View {
    @Environment(\.widgetFamily) var family
    let entry: LiftEntry

    var body: some View {
        switch family {
        case .accessoryCircular:
            HissiAccessoryCircularView(entry: entry)
        case .accessoryRectangular:
            HissiAccessoryRectangularView(entry: entry)
        case .accessoryInline:
            HissiAccessoryInlineView(entry: entry)
        case .systemSmall:
            HissiWidgetSmallView(entry: entry)
        case .systemLarge:
            HissiWidgetListView(entry: entry, maxRows: 8)
        default:
            HissiWidgetListView(entry: entry, maxRows: 3)
        }
    }
}

// MARK: - Widget

// The declaration order here is the order the widget gallery lists them under
// the app, so the hero use case ("is my route okay?") goes first.
@main
struct HissiWidgetBundle: WidgetBundle {
    var body: some Widget {
        HissiWidget()
        HissiFavoritesWidget()
        NearbyWidget()
        // Not a gallery tile: a Live Activity is started from the app, so its
        // position here is irrelevant to what the user browses. None on Mac.
        #if !targetEnvironment(macCatalyst)
        LiveStatusActivity()
        #endif
    }
}

struct HissiWidget: Widget {
    // The gallery already groups tiles under the app name, so the display name
    // spends its one line on what the widget *does* instead of repeating
    // "Hissi". The kind stays untouched — it is the widget's identity, and
    // changing it would orphan every already-placed instance.
    let kind = "HissiWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            HissiWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Aufzug-Status")
        .description("Status der überwachten Aufzüge.")
        // Home Screen / StandBy plus the three Lock Screen accessory families.
        .supportedFamilies([
            .systemSmall, .systemMedium,
            .accessoryCircular, .accessoryRectangular, .accessoryInline,
        ])
    }
}

// The second gallery tile, and deliberately a separate widget rather than
// another family on the first one: a widget kind is what the gallery lists, so
// folding systemLarge into HissiWidget would have added a size option nobody
// browsing the gallery ever sees. Large earns its own tile because it answers a
// different question — not "is anything broken?" but "show me all of them".
struct HissiFavoritesWidget: Widget {
    let kind = "HissiFavoritesWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            HissiWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Alle Favoriten")
        .description("Alle überwachten Aufzüge in einer Liste.")
        .supportedFamilies([.systemLarge])
    }
}

// MARK: - Previews

#Preview("Small", as: .systemSmall) {
    HissiWidget()
} timeline: {
    LiftEntry(date: .now, elevators: previewElevators(showBroken: false))
}

#Preview("Medium", as: .systemMedium) {
    HissiWidget()
} timeline: {
    LiftEntry(date: .now, elevators: previewElevators(showBroken: true))
}

#Preview("Large", as: .systemLarge) {
    HissiFavoritesWidget()
} timeline: {
    LiftEntry(date: .now, elevators: previewElevators(showBroken: true))
    LiftEntry(date: .now, elevators: previewElevators(showBroken: false))
    LiftEntry(date: .now, elevators: [])
}

#Preview("Lock Screen circular", as: .accessoryCircular) {
    HissiWidget()
} timeline: {
    LiftEntry(date: .now, elevators: previewElevators(showBroken: false))
    LiftEntry(date: .now, elevators: previewElevators(showBroken: true))
}

#Preview("Lock Screen rectangular", as: .accessoryRectangular) {
    HissiWidget()
} timeline: {
    LiftEntry(date: .now, elevators: previewElevators(showBroken: true))
    LiftEntry(date: .now, elevators: previewElevators(showBroken: false))
}

#Preview("Lock Screen inline", as: .accessoryInline) {
    HissiWidget()
} timeline: {
    LiftEntry(date: .now, elevators: previewElevators(showBroken: true))
}
