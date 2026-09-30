import CoreLocation
import SwiftUI
import WidgetKit

// "In der Nähe" on the Home Screen: the stations with elevators within
// walking distance of the phone and the status of their lifts — the app's
// nearby block as a tile, so "which station near me works?" needs no tap.
//
// Location comes to the extension through NSWidgetWantsLocation (Info.plist)
// and the app's when-in-use authorization, which the system extends to the
// widget when the user adds it; `isAuthorizedForWidgetUpdates` tells whether
// that happened. Data comes from the catalog snapshot the app persists into
// the App Group (EquipmentCatalog), overlaid with the bundled seed for the
// coordinates, and one targeted status request per timeline — never a full
// catalog build here, that stays with the app's search. Before the app has
// ever built a catalog, the seed previews names with unknown statuses.
struct NearbyWidgetEntry: TimelineEntry {
    enum State: Equatable {
        case preview
        // The app has no location permission, or the user declined to
        // extend it to the widget.
        case notAuthorized
        // Authorized, but no fix — the widget hasn't been visible for a
        // while, so the system stopped treating it as in use.
        case locationUnavailable
        case stations([NearbyStations.Station])
    }

    let date: Date
    let state: State
}

// MARK: - Location

// One fix per timeline, with a timeout: a widget refresh can't wait for a
// slow fix, and the last known location is still better than nothing.
@MainActor
private final class WidgetLocationFetcher: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation?, Never>?

    var isAuthorized: Bool { manager.isAuthorizedForWidgetUpdates }
    var lastKnown: CLLocation? { manager.location }

    func fetch(timeout: Duration = .seconds(8)) async -> CLLocation? {
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        let fix = await withCheckedContinuation { (continuation: CheckedContinuation<CLLocation?, Never>) in
            self.continuation = continuation
            manager.requestLocation()
            Task {
                try? await Task.sleep(for: timeout)
                self.resume(nil)
            }
        }
        return fix ?? lastKnown
    }

    private func resume(_ location: CLLocation?) {
        continuation?.resume(returning: location)
        continuation = nil
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let fix = locations.last
        Task { @MainActor in self.resume(fix) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.resume(nil) }
    }
}

// MARK: - Timeline

struct NearbyWidgetProvider: TimelineProvider {
    // More than the app's five: a tile has no scroll, the large family is
    // the "show me everything" surface, and eight covers every walkable
    // radius in the network.
    private static let stationLimit = 8

    func placeholder(in context: Context) -> NearbyWidgetEntry {
        NearbyWidgetEntry(date: .now, state: .preview)
    }

    func getSnapshot(in context: Context, completion: @escaping (NearbyWidgetEntry) -> Void) {
        if context.isPreview {
            completion(NearbyWidgetEntry(date: .now, state: .preview))
            return
        }
        // Fast path: last known fix and whatever statuses the snapshot has.
        Task { @MainActor in
            let state = await Self.nearbyState(freshLocation: false, refreshStatus: false)
            completion(NearbyWidgetEntry(date: .now, state: state))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NearbyWidgetEntry>) -> Void) {
        Task { @MainActor in
            let state = await Self.nearbyState(freshLocation: true, refreshStatus: true)
            let next = Calendar.current.date(byAdding: .minute, value: RefreshInterval.minutes, to: .now) ?? .now
            completion(Timeline(entries: [NearbyWidgetEntry(date: .now, state: state)], policy: .after(next)))
        }
    }

    @MainActor
    private static func nearbyState(freshLocation: Bool, refreshStatus: Bool) async -> NearbyWidgetEntry.State {
        let fetcher = WidgetLocationFetcher()
        guard fetcher.isAuthorized else { return .notAuthorized }
        guard let fix = freshLocation ? await fetcher.fetch() : fetcher.lastKnown else {
            return .locationUnavailable
        }
        // Read-only snapshot: a stale catalog is fine for names and
        // coordinates, and a rebuild is the app's job (30 s, megabytes —
        // not for a widget's budget).
        let catalog = await EquipmentCatalog.shared.snapshot(rebuildingIfStale: false)
            ?? EquipmentCatalog.overlaid(live: [], seed: SeedCatalog.records)
        var stations = NearbyStations.nearest(
            toLatitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude,
            in: catalog, limit: stationLimit
        )
        if refreshStatus, !stations.isEmpty {
            let fresh = await EquipmentCatalog.shared.equipment(for: NearbyStations.elevatorIds(of: stations))
            stations = NearbyStations.restated(stations, with: fresh)
        }
        return .stations(stations)
    }
}

private func previewStations() -> [NearbyStations.Station] {
    [
        ("S+U Alexanderplatz", 120.0, [false, true, true, true, true, true]),
        ("U Rotes Rathaus", 350.0, [true, true]),
        ("S Hackescher Markt", 780.0, [true]),
        ("U Klosterstr.", 940.0, [nil]),
    ].map { name, meters, statuses in
        NearbyStations.Station(
            name: name,
            distanceMeters: meters,
            elevators: statuses.enumerated().map { index, working in
                NearbyStations.Station.Elevator(id: "\(name)-\(index)", isWorking: working)
            }
        )
    }
}

// MARK: - Views

private func radiusLabel() -> String {
    Measurement(value: NearbyStations.walkingRadiusMeters, unit: UnitLength.meters)
        .formatted(.measurement(width: .abbreviated, usage: .road))
}

private func distanceLabel(_ meters: Double) -> String {
    Measurement(value: meters, unit: UnitLength.meters)
        .formatted(.measurement(width: .abbreviated, usage: .road))
}

private func accessibleRow(_ station: NearbyStations.Station) -> String {
    [station.name, station.statusLabel, distanceLabel(station.distanceMeters)].joined(separator: ", ")
}

struct NearbyWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: NearbyWidgetEntry

    private var stations: [NearbyStations.Station]? {
        switch entry.state {
        case .preview:                 previewStations()
        case .stations(let stations):  stations
        case .notAuthorized, .locationUnavailable: nil
        }
    }

    var body: some View {
        Group {
            switch entry.state {
            case .notAuthorized:
                notice("Standort in der App erlauben", systemImage: "location.slash")
            case .locationUnavailable:
                notice("Standort nicht verfügbar", systemImage: "location")
            case .preview, .stations:
                let stations = stations ?? []
                switch family {
                case .systemSmall: NearbyWidgetSmallView(stations: stations)
                case .systemLarge: NearbyWidgetListView(stations: stations, maxRows: 8)
                default:           NearbyWidgetListView(stations: stations, maxRows: 3)
                }
            }
        }
        .hissiWidgetBackground()
        .widgetURL(AppDeepLink.nearby.url)
    }

    private func notice(_ text: LocalizedStringKey, systemImage: String) -> some View {
        VStack(spacing: 6) {
            WidgetMark()
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(Color.hissiTextSecondary)
            Text(text)
                .font(.caption)
                .foregroundStyle(Color.hissiTextSecondary)
                .multilineTextAlignment(.center)
        }
        .accessibilityElement(children: .combine)
    }
}

// The nearest station only — the one the user is most likely standing at.
struct NearbyWidgetSmallView: View {
    let stations: [NearbyStations.Station]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                WidgetMark()
                Text("In der Nähe")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.hissiTextSecondary)
            }
            if let station = stations.first {
                Spacer(minLength: 0)
                Text(station.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                HStack(spacing: 4) {
                    Image(systemName: station.status.symbolName)
                        .foregroundStyle(station.status.symbolColor)
                    Text(station.statusLabel)
                        .lineLimit(1)
                        .foregroundStyle(station.status.textColor)
                }
                .font(.caption)
                Text(distanceLabel(station.distanceMeters))
                    .font(.caption2)
                    .foregroundStyle(Color.hissiTextSecondary)
                Spacer(minLength: 0)
            } else {
                Spacer(minLength: 0)
                Text("Keine Station mit Aufzug im Umkreis von \(radiusLabel()).")
                    .font(.caption)
                    .foregroundStyle(Color.hissiTextSecondary)
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            stations.first.map(accessibleRow)
                ?? String(localized: "Keine Station mit Aufzug im Umkreis von \(radiusLabel()).")
        )
    }
}

// Shared by systemMedium and systemLarge: same rows, different cap. Sorted
// by distance only, like everywhere else — status is what a row says, not
// where it sits.
struct NearbyWidgetListView: View {
    let stations: [NearbyStations.Station]
    let maxRows: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                WidgetMark()
                Image(systemName: "location.fill")
                    .font(.caption)
                Text("In der Nähe")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text("bis \(radiusLabel()) zu Fuß")
                    .font(.caption2)
            }
            .foregroundStyle(Color.hissiTextSecondary)
            .padding(.bottom, 2)
            .accessibilityElement(children: .combine)

            if stations.isEmpty {
                Text("Keine Station mit Aufzug im Umkreis von \(radiusLabel()).")
                    .font(.caption)
                    .foregroundStyle(Color.hissiTextSecondary)
            }
            ForEach(stations.prefix(maxRows)) { station in
                row(station)
            }
            if stations.count > maxRows {
                Text("+ \(stations.count - maxRows) weitere")
                    .font(.caption2)
                    .foregroundStyle(Color.hissiTextSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
    }

    private func row(_ station: NearbyStations.Station) -> some View {
        HStack(spacing: 8) {
            Image(systemName: station.status.symbolName)
                .font(.caption)
                .foregroundStyle(station.status.symbolColor)
            Text(station.name)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            Spacer()
            Text(station.statusLabel)
                .font(.caption2.weight(.medium))
                .foregroundStyle(station.status.textColor)
                .lineLimit(1)
            Text(distanceLabel(station.distanceMeters))
                .font(.caption2)
                .foregroundStyle(Color.hissiTextSecondary)
                .frame(minWidth: 40, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibleRow(station))
    }
}

// MARK: - Widget

struct NearbyWidget: Widget {
    // Identity — never rename (see HissiWidget.kind).
    let kind = "HissiNearbyWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NearbyWidgetProvider()) { entry in
            NearbyWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("In der Nähe")
        .description("Stationen mit Aufzug in Fußweite und ihr Status.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

#Preview("Nearby small", as: .systemSmall) {
    NearbyWidget()
} timeline: {
    NearbyWidgetEntry(date: .now, state: .preview)
    NearbyWidgetEntry(date: .now, state: .stations([]))
    NearbyWidgetEntry(date: .now, state: .notAuthorized)
}

#Preview("Nearby medium", as: .systemMedium) {
    NearbyWidget()
} timeline: {
    NearbyWidgetEntry(date: .now, state: .preview)
    NearbyWidgetEntry(date: .now, state: .locationUnavailable)
}

#Preview("Nearby large", as: .systemLarge) {
    NearbyWidget()
} timeline: {
    NearbyWidgetEntry(date: .now, state: .preview)
}
