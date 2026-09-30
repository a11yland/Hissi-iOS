import SwiftUI

// "In der Nähe" block on the recents screen: a priming button until the
// user opts in, then the stations within walking distance (on-device sort
// over the catalog snapshot) as tappable rows that run the station search.
// The radius is said out loud in the header, so an empty list reads as
// "nothing within reach" rather than as a failure.
//
// Statuses land in two phases, like the search: the snapshot renders
// instantly and may be stale or status-less (first launch previews from the
// seed), then one targeted request over exactly the shown stations' elevators
// re-states the rows. A failed refresh keeps what is on screen — nearby is a
// suggestion, not a core flow.
struct NearbyStationsSection: View {
    @ObservedObject var location: LocationProvider
    let onSelect: (String) -> Void

    @State private var stations: [NearbyStations.Station] = []
    // Phase 1 has landed for the current fix — before that an empty list is
    // "not loaded yet", not "nothing within reach".
    @State private var hasLoaded = false
    @State private var isRefreshingStatus = false

    // "1 km", localized like the row distances.
    private var radiusLabel: String {
        Measurement(value: NearbyStations.walkingRadiusMeters, unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("In der Nähe")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.hissiTextSecondary)
                Text("bis \(radiusLabel) zu Fuß")
                    .font(.footnote)
                    .foregroundStyle(Color.hissiTextSecondary)
                // The shown statuses are the snapshot's and the refresh is
                // still out — without this a stale row would look final.
                if isRefreshingStatus {
                    ProgressView()
                        .controlSize(.small)
                    Text("Status wird aktualisiert …")
                        .font(.footnote)
                        .foregroundStyle(Color.hissiTextSecondary)
                }
            }
            .accessibilityElement(children: .combine)

            switch location.state {
            case .idle:
                Button {
                    location.locate()
                } label: {
                    Label("Stationen in der Nähe anzeigen", systemImage: "location")
                        .font(.subheadline)
                }
                .buttonStyle(.bordered)
                // 44 pt tall — WCAG 2.5.5 (AAA) target size.
                .controlSize(.large)

            case .locating:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Standort wird ermittelt …")
                        .font(.footnote)
                        .foregroundStyle(Color.hissiTextSecondary)
                }
                .accessibilityElement(children: .combine)

            case .denied:
                VStack(alignment: .leading, spacing: 6) {
                    Text("Standortzugriff ist deaktiviert – erlaube ihn in den Einstellungen.")
                        .font(.footnote)
                        .foregroundStyle(Color.hissiTextSecondary)
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        Link("Einstellungen öffnen", destination: url)
                            .font(.footnote.weight(.semibold))
                    }
                }

            case .located(let latitude, let longitude):
                VStack(spacing: 0) {
                    if hasLoaded, stations.isEmpty {
                        Text("Keine Station mit Aufzug im Umkreis von \(radiusLabel).")
                            .font(.footnote)
                            .foregroundStyle(Color.hissiTextSecondary)
                    }
                    ForEach(stations) { station in
                        Button {
                            onSelect(station.name)
                        } label: {
                            NearbyStationRow(station: station)
                        }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .combine)
                        if station.id != stations.last?.id {
                            Divider().overlay(Color.hissiSeparator)
                        }
                    }
                }
                .task(id: location.state) {
                    await load(latitude: latitude, longitude: longitude)
                }
            }
        }
        .onAppear {
            // Permission already granted in an earlier session: no button
            // ceremony, locate straight away.
            if location.state == .idle, location.isAuthorized { location.locate() }
        }
    }

    private func load(latitude: Double, longitude: Double) async {
        // Phase 1, instant: names, distances and whatever statuses the
        // snapshot carries. On the very first launch there is no snapshot yet
        // and the seed previews the names, all statuses unknown.
        hasLoaded = false
        let catalog = await EquipmentCatalog.shared.snapshot()
            ?? EquipmentCatalog.overlaid(live: [], seed: SeedCatalog.records)
        guard !Task.isCancelled else { return }
        let nearby = NearbyStations.nearest(
            toLatitude: latitude, longitude: longitude, in: catalog
        )
        withAnimation {
            stations = nearby
            hasLoaded = true
        }
        guard !nearby.isEmpty else { return }

        // Phase 2, fresh: one targeted request covers every elevator of the
        // handful of shown stations (a still-fresh catalog cache answers it
        // for free). Seed ids bridge to their live records on the way.
        isRefreshingStatus = true
        defer {
            if !Task.isCancelled { withAnimation { isRefreshingStatus = false } }
        }
        let fresh = await EquipmentCatalog.shared.equipment(
            for: NearbyStations.elevatorIds(of: nearby)
        )
        guard !Task.isCancelled, !fresh.isEmpty else { return }
        withAnimation { stations = NearbyStations.restated(nearby, with: fresh) }
    }
}

// One suggestion: station, its lifts' verdict, distance. Sorted by distance
// only — the status is what the row says, never where it sits, so a landing
// refresh can't reshuffle the list under the user's finger.
private struct NearbyStationRow: View {
    let station: NearbyStations.Station

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "tram")
                .font(.subheadline)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(station.name)
                    .font(.subheadline)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    // Shape carries the status, colour only reinforces it.
                    Image(systemName: station.status.symbolName)
                        .font(.caption2)
                        .contentTransition(.symbolEffect(.replace))
                        .animation(.default, value: station.status)
                        .foregroundStyle(station.status.symbolColor)
                        .accessibilityHidden(true)
                    Text(station.statusLabel)
                        .font(.caption)
                        .lineLimit(1)
                }
                .foregroundStyle(station.status.textColor)
            }

            Spacer()

            Text(distanceLabel(station.distanceMeters))
                .font(.footnote)
                .foregroundStyle(Color.hissiTextSecondary)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    // "350 m" / "1,2 km", localized.
    private func distanceLabel(_ meters: Double) -> String {
        Measurement(value: meters, unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road))
    }
}
