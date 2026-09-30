import SwiftUI

// Grouped search results: Berlin/Brandenburg sections (only when both are
// present), one card per station, network subheaders inside stations that
// span several networks (S+U), and an inline favorite toggle per elevator.
// Driven by the shared SearchService; the search field lives in ContentView.
struct SearchResultsList: View {
    @ObservedObject var search: SearchService
    @ObservedObject var service: ElevatorMonitorService
    // Passed through to the detail view's map, nothing else here uses it.
    @ObservedObject var location: LocationProvider
    let query: String

    var body: some View {
        if search.isLoading && search.regions.isEmpty {
            ProgressView()
                .accessibilityLabel("Suche läuft")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = search.errorMessage {
            ContentUnavailableView("Fehler", systemImage: "exclamationmark.triangle", description: Text(error))
        } else if search.regions.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            List {
                // Results are visible but phase 2 (live statuses) is still on
                // its way — without this, a stale snapshot would look final.
                if search.isLoading {
                    RefreshingNotice()
                }
                ForEach(search.regions) { regionGroup in
                    if search.regions.count > 1 {
                        Section {} header: {
                            Text(regionGroup.region.label)
                                .font(.title3.bold())
                                .foregroundStyle(.primary)
                                .textCase(nil)
                        }
                    }
                    ForEach(regionGroup.stations) { group in
                        Section {
                            ForEach(group.sections) { section in
                                if group.sections.count > 1 {
                                    NetworkSubheader(network: section.network)
                                }
                                ForEach(section.elevators) { elevator in
                                    NavigationLink {
                                        ElevatorDetailView(
                                            elevator: elevator, service: service, location: location,
                                            onRefreshed: { search.apply($0, replacing: elevator.id) }
                                        )
                                    } label: {
                                        HStack(spacing: 8) {
                                            ElevatorRowView(elevator: elevator)
                                            FavoriteStar(isFavorite: service.isFavorite(elevator.id)) {
                                                service.toggleFavorite(elevator)
                                            }
                                        }
                                    }
                                }
                            }
                        } header: {
                            StationHeader(station: group.station, networks: group.networks, query: query)
                        }
                        .hissiRows()
                    }
                }
            }
            .hissiList()
        }
    }
}

// Subtle banner while the shown results are the instant (possibly stale)
// phase and the live refresh is still pending.
private struct RefreshingNotice: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Status wird aktualisiert …")
                .font(.footnote)
                .foregroundStyle(Color.hissiTextSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .accessibilityElement(children: .combine)
    }
}

// Per-elevator favorite toggle. `.borderless` keeps the tap from also
// triggering the row's NavigationLink. The set star is lilac, not yellow —
// yellow means "unbekannt" in this palette.
private struct FavoriteStar: View {
    let isFavorite: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isFavorite ? "star.fill" : "star")
                .font(.title3)
                .foregroundStyle(isFavorite ? Color.accentColor : Color.hissiTextSecondary)
                .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(isFavorite ? "Aus Favoriten entfernen" : "Zu Favoriten hinzufügen")
    }
}

private struct StationHeader: View {
    let station: StationSearchResult
    let networks: [TransitNetwork]
    let query: String

    var body: some View {
        HStack(spacing: 6) {
            ForEach(networks, id: \.rawValue) { network in
                if let badge = network.badge {
                    Text(badge)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(network.color, in: RoundedRectangle(cornerRadius: 3))
                        .accessibilityHidden(true)
                }
            }
            // The query match is bolded — VoiceOver keeps the plain name via
            // accessibleLabel below.
            Text(AccessibilityCloudClient.highlightedStationName(station.name, matching: query))
        }
        .accessibilityElement(children: .combine)
        // The badge glyphs ("U"/"S"/"R") are unspeakable on their own; spell
        // the networks out for VoiceOver and Voice Control instead.
        .accessibilityLabel(accessibleLabel)
    }

    private var accessibleLabel: String {
        let spoken = networks.compactMap(\.spokenName)
        return spoken.isEmpty ? station.name : "\(spoken.joined(separator: ", ")), \(station.name)"
    }
}

// Subheader row separating the networks inside an S+U station's card.
private struct NetworkSubheader: View {
    let network: TransitNetwork

    var body: some View {
        HStack(spacing: 6) {
            if let badge = network.badge {
                Text(badge)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(network.color, in: RoundedRectangle(cornerRadius: 3))
                    .accessibilityHidden(true)
            }
            Text(network.label)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.hissiTextSecondary)
        }
        .listRowSeparator(.hidden, edges: .top)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(network.spokenName ?? network.label)
        .accessibilityAddTraits(.isHeader)
    }
}

private extension TransitNetwork {
    var badge: String? {
        switch self {
        case .uBahn:    "U"
        case .sBahn:    "S"
        case .regional: "R"
        case .access:   nil
        }
    }

    // White letter on this — AAA pairs, see Palette.
    var color: Color {
        switch self {
        case .uBahn:    Color(hex: Palette.uBahnBadge)
        case .sBahn:    Color(hex: Palette.sBahnBadge)
        case .regional: Color(hex: Palette.regionalBadge)
        case .access:   Color(hex: Palette.accessBadge)
        }
    }

    // Speakable network name for VoiceOver/Voice Control; nil = use the label.
    var spokenName: String? {
        switch self {
        case .uBahn:    "U-Bahn"
        case .sBahn:    "S-Bahn"
        case .regional: String(localized: "Regionalbahn")
        case .access:   String(localized: "Zugang")
        }
    }
}
