import SwiftUI
import WidgetKit

// "In der Nähe" on the watch face: a launcher, not a status. A complication
// can't run a search itself — tapping it opens the watch app on the nearby
// screen (AppDeepLink.nearby), which locates the wrist and lists the stations
// within walking distance. Static by design: there is nothing to refresh, so
// the timeline is one entry that never expires.
struct NearbyEntry: TimelineEntry {
    let date: Date
}

struct NearbyProvider: TimelineProvider {
    func placeholder(in context: Context) -> NearbyEntry { NearbyEntry(date: .now) }

    func getSnapshot(in context: Context, completion: @escaping (NearbyEntry) -> Void) {
        completion(NearbyEntry(date: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NearbyEntry>) -> Void) {
        completion(Timeline(entries: [NearbyEntry(date: .now)], policy: .never))
    }
}

struct NearbyComplicationView: View {
    @Environment(\.widgetFamily) private var family
    let entry: NearbyEntry

    // Every family carries the app's identity somewhere (FR14): the face
    // gives a launcher no context. The wide families spell the name out, the
    // small ones show the icon's mark — a bare location glyph could be any
    // app's. VoiceOver names the subject instead of the brand.
    private var spokenLabel: String { String(localized: "Lifte in der Nähe") }

    var body: some View {
        Group {
            switch family {
            case .accessoryCorner:
                // The mark alone: it is the app's identity (FR14), and a
                // curved label would only crowd the corner.
                LogoMark()
                    .frame(width: 26, height: 26)

            case .accessoryRectangular:
                // The mark is the identity here too — no "Hissi" wordmark
                // next to it, the row's one headline is what the tap does.
                HStack(spacing: 8) {
                    LogoMark()
                        .frame(height: 36)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("In der Nähe")
                            .font(.headline)
                        Text("Stationen mit Aufzug, bis \(radiusLabel) zu Fuß")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

            case .accessoryInline:
                Label(spokenLabel, systemImage: "location.fill")

            default:
                ZStack {
                    AccessoryWidgetBackground()
                    LogoMark()
                        .padding(9)
                }
            }
        }
        .containerBackground(.clear, for: .widget)
        .widgetURL(AppDeepLink.nearby.url)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenLabel)
        .accessibilityHint(Text("Öffnet die Stationen in deiner Nähe."))
    }

    private var radiusLabel: String {
        Measurement(value: NearbyStations.walkingRadiusMeters, unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road))
    }
}

struct NearbyComplication: Widget {
    // Identity — never rename (see HissiWatchWidget.kind).
    let kind = "HissiWatchNearby"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NearbyProvider()) { entry in
            NearbyComplicationView(entry: entry)
        }
        .configurationDisplayName("In der Nähe")
        .description("Öffnet die Stationen in deiner Nähe.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline, .accessoryCorner])
    }
}

#Preview("Nearby circular", as: .accessoryCircular) {
    NearbyComplication()
} timeline: {
    NearbyEntry(date: .now)
}

#Preview("Nearby rectangular", as: .accessoryRectangular) {
    NearbyComplication()
} timeline: {
    NearbyEntry(date: .now)
}

#Preview("Nearby corner", as: .accessoryCorner) {
    NearbyComplication()
} timeline: {
    NearbyEntry(date: .now)
}
