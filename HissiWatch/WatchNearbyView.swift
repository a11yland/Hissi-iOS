import SwiftUI

// "In der Nähe" on the wrist — what the nearby complication opens, and the
// only screen on the watch that isn't a mirror of the phone's favorites. The
// watch locates itself and sorts the catalog on-device, exactly like the
// phone (NearbyStations, walking distance), because the phone may be out of
// reach when someone taps the face.
//
// Statuses land in two phases like the phone's nearby block: the catalog
// snapshot renders instantly, then a targeted request re-states the rows.
// The one wrist-specific case is the very first use: the watch has no
// snapshot yet, only the bundled seed (names, coordinates, no statuses, and
// only the seed's elevators), so phase 2 has to build the catalog once
// (~30 s) — the rows are up during the wait and say so. From then on the
// persisted snapshot answers phase 1 and the targeted request phase 2.
struct WatchNearbyView: View {
    @StateObject private var location = LocationProvider()

    @State private var stations: [NearbyStations.Station] = []
    // The records behind the rows, so tapping a station can show its
    // elevators without another lookup.
    @State private var records: [String: AccessibilityCloudClient.Equipment] = [:]
    @State private var hasLoaded = false
    @State private var isRefreshingStatus = false

    private var radiusLabel: String {
        Measurement(value: NearbyStations.walkingRadiusMeters, unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road))
    }

    var body: some View {
        Group {
            switch location.state {
            case .idle:
                Button {
                    location.locate()
                } label: {
                    Label("Standort verwenden", systemImage: "location")
                }

            case .locating:
                ProgressView("Standort wird ermittelt …")

            case .denied:
                Text("Standortzugriff ist deaktiviert – erlaube ihn in den Einstellungen.")
                    .font(.footnote)
                    .foregroundStyle(Color.watchTextSecondary)
                    .multilineTextAlignment(.center)

            case .located(let latitude, let longitude):
                List {
                    if hasLoaded, stations.isEmpty {
                        Text("Keine Station mit Aufzug im Umkreis von \(radiusLabel).")
                            .font(.footnote)
                            .foregroundStyle(Color.watchTextSecondary)
                            .listRowBackground(Color.clear)
                    }
                    ForEach(stations) { station in
                        NavigationLink(value: station) {
                            WatchNearbyStationRow(station: station)
                        }
                        .watchCard()
                    }
                    VStack(spacing: 2) {
                        if isRefreshingStatus {
                            HStack(spacing: 6) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Status wird aktualisiert …")
                            }
                        }
                        Text("bis \(radiusLabel) zu Fuß")
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                    .accessibilityElement(children: .combine)
                }
                .listStyle(.carousel)
                .task(id: location.state) {
                    await load(latitude: latitude, longitude: longitude)
                }
            }
        }
        .navigationTitle("In der Nähe")
        .navigationDestination(for: NearbyStations.Station.self) { station in
            WatchNearbyStationView(station: station, records: records)
        }
        .onAppear {
            // Already authorized (here or inherited from the phone app): no
            // button ceremony, locate straight away.
            if location.state == .idle, location.isAuthorized { location.locate() }
        }
    }

    private func load(latitude: Double, longitude: Double) async {
        hasLoaded = false
        let snapshot = await EquipmentCatalog.shared.snapshot()
        let catalog = snapshot ?? EquipmentCatalog.overlaid(live: [], seed: SeedCatalog.records)
        guard !Task.isCancelled else { return }
        let nearby = NearbyStations.nearest(toLatitude: latitude, longitude: longitude, in: catalog)
        stations = nearby
        records = Self.index(catalog)
        hasLoaded = true
        guard !nearby.isEmpty else { return }

        isRefreshingStatus = true
        defer { if !Task.isCancelled { isRefreshingStatus = false } }
        if snapshot != nil {
            // Phase 2, targeted: one request over the shown stations' elevators.
            let fresh = await EquipmentCatalog.shared.equipment(
                for: NearbyStations.elevatorIds(of: nearby)
            )
            guard !Task.isCancelled, !fresh.isEmpty else { return }
            stations = NearbyStations.restated(nearby, with: fresh)
            records.merge(fresh) { _, live in live }
        } else if let built = await EquipmentCatalog.shared.all() {
            // First use: the seed can't be re-stated (its ids have no live
            // counterpart yet), so the rows are re-derived from the built
            // catalog. Distances come from the seed either way, so the order
            // holds — only statuses and elevator counts change.
            guard !Task.isCancelled else { return }
            stations = NearbyStations.nearest(toLatitude: latitude, longitude: longitude, in: built)
            records = Self.index(built)
        }
    }

    private static func index(
        _ catalog: [AccessibilityCloudClient.Equipment]
    ) -> [String: AccessibilityCloudClient.Equipment] {
        Dictionary(catalog.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }
}

private struct WatchNearbyStationRow: View {
    let station: NearbyStations.Station

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(station.name)
                .font(.caption)
                .fontWeight(.semibold)
                .lineLimit(2)
            HStack(spacing: 4) {
                Image(systemName: station.status.symbolName)
                    .accessibilityHidden(true)
                Text(station.statusLabel)
                    .lineLimit(1)
            }
            .font(.caption2)
            .fontWeight(.medium)
            .foregroundStyle(station.status.watchColor)
            Text(distanceLabel(station.distanceMeters))
                .font(.caption2)
                .foregroundStyle(Color.watchTextSecondary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private func distanceLabel(_ meters: Double) -> String {
        Measurement(value: meters, unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road))
    }
}

// One station's elevators, in the same pager the favorites use — the row
// vocabulary (status, description, map) is the same, only the membership
// differs: catalog records instead of favorites.
struct WatchNearbyStationView: View {
    let station: NearbyStations.Station
    let records: [String: AccessibilityCloudClient.Equipment]

    private var elevators: [MonitoredElevator] {
        station.elevators.compactMap { records[$0.id] }.map { record in
            MonitoredElevator(
                id: record.id,
                stationId: record.stationId,
                elevatorId: record.id,
                stationName: record.stationName,
                elevatorDescription: record.description,
                isWorking: record.isWorking,
                lastChecked: nil,
                lastUpdated: record.lastUpdate,
                sourceName: record.sourceName,
                organizationName: record.organizationName,
                stateExplanation: record.stateExplanation,
                latitude: record.latitude,
                longitude: record.longitude,
                fastaEquipmentNumber: record.fastaEquipmentNumber
            )
        }
    }

    var body: some View {
        let elevators = elevators
        if let first = elevators.first {
            WatchElevatorPager(elevators: elevators, startId: first.id)
        } else {
            Text("Keine Daten")
                .foregroundStyle(Color.watchTextSecondary)
        }
    }
}
