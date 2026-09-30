import CoreLocation
import MapKit
import SwiftUI

struct ElevatorDetailView: View {
    // Snapshot the view was pushed with (a search result or favorite row).
    private let initial: MonitoredElevator
    @ObservedObject var service: ElevatorMonitorService
    // Shared with the nearby suggestions: one provider, one permission
    // decision — a grant given there already shows the dot here.
    @ObservedObject var location: LocationProvider
    // Where the refreshed copy of a search result goes besides this view: the
    // search list folds it into the row behind (SearchService.apply). Nil
    // from the favorites list, which refreshes on its own.
    private let onRefreshed: ((MonitoredElevator) -> Void)?

    init(
        elevator: MonitoredElevator,
        service: ElevatorMonitorService,
        location: LocationProvider,
        onRefreshed: ((MonitoredElevator) -> Void)? = nil
    ) {
        self.initial = elevator
        self.service = service
        self.location = location
        self.onRefreshed = onRefreshed
        // Framed on the station from the first frame — `.automatic` would
        // render one auto-fitted frame and then snap.
        let position: MapCameraPosition = if let coordinate = elevator.coordinate {
            .region(MKCoordinateRegion(center: coordinate, span: Self.stationSpan))
        } else {
            .automatic
        }
        _camera = State(initialValue: position)
    }

    // A search result's own refresh (targeted request on appear, see below):
    // the pushed snapshot is only as fresh as the catalog it came from, and
    // that may be the seed with no status at all. Favorites don't need it —
    // the service refreshes them.
    @State private var refreshed: MonitoredElevator?

    // Favorites refresh while the view is open (e.g. right after favoriting a
    // status-less search result) — prefer the service's live copy over the
    // pushed snapshot, then the view's own refresh. A refreshed seed record
    // may carry the live id, so the favorite is looked up under both.
    private var elevator: MonitoredElevator {
        service.elevators.first { $0.id == initial.id || $0.id == refreshed?.id }
            ?? refreshed
            ?? initial
    }

    private var status: ElevatorStatus { .init(isWorking: elevator.isWorking) }

    // Whether the landscape column's last row is on screen — drives the
    // overflow fade. Starts false so the fade never flashes before the
    // sentinel's first onAppear settles it.
    @State private var reachedBottom = false

    // Look Around scene for the station's coordinate, loaded once per
    // elevator. nil means "no street-level view here" — either the request
    // failed or Apple has no coverage at that spot.
    @State private var lookAroundScene: MKLookAroundScene?

    // The snippet's camera. Non-interactive, so nothing but this view moves
    // it: it frames the station, and the device position only when that fits
    // without losing the station's surroundings (see cameraRegion).
    @State private var camera: MapCameraPosition

    // Roughly 600 m across — enough to recognise the street the elevator is
    // on. Widening beyond `maxFitMeters` would trade that context for a dot.
    private static let stationSpan = MKCoordinateSpan(latitudeDelta: 0.006, longitudeDelta: 0.006)
    private static let maxFitMeters: CLLocationDistance = 2_000

    // Landscape column metrics: one protective gap for the top edge and for
    // the space between the floating bar button and the title beside it.
    private static let columnGap: CGFloat = 20
    private static let barButtonSize: CGFloat = 44

    var body: some View {
        GeometryReader { geometry in
            // Landscape iPhone: fields and map side by side. Portrait (and no
            // coordinate at all): stacked in a single list, as before.
            if geometry.size.width > geometry.size.height, let coordinate = elevator.coordinate {
                HStack(spacing: 0) {
                    // Landscape height is scarce (~400 pt): the station name
                    // stays in the (otherwise empty) inline bar, the sections
                    // pack tighter and the favorite action moves to the
                    // toolbar, so the fields fit without scrolling at
                    // standard type sizes.
                    List {
                        // The bar is fully transparent here (no edge blur), so
                        // a centered bar title would sit on the map without a
                        // dependable contrast backing — the name lives in the
                        // column instead, on its solid background. It shares
                        // the back button's row, so its leading inset clears
                        // the button plus the same protective gap the column
                        // keeps to the top edge.
                        Section {
                            Text(elevator.stationName)
                                .font(.title2.bold())
                                .listRowBackground(Color.clear)
                                .listRowInsets(EdgeInsets(
                                    top: 0,
                                    leading: Self.barButtonSize + Self.columnGap,
                                    bottom: 0,
                                    trailing: 0
                                ))
                                .listRowSeparator(.hidden)
                        }
                        fieldsSection
                        bottomSentinel
                    }
                    .hissiList()
                    .listSectionSpacing(.compact)
                    .scrollIndicatorsFlash(onAppear: true)
                    // Like the map: the column runs under the bars — rows rest
                    // below the bar (content margin) and slide under it on
                    // scroll. Text-only content needs no grouped canvas of its
                    // own next to the full-bleed map, and no edge blur either:
                    // the map side has none, so the left column hiding it is
                    // what makes the bar read as one transparent surface.
                    .scrollContentBackground(.hidden)
                    .contentMargins(.top, Self.columnGap)
                    .withoutTopScrollEdgeEffect()
                    .overlay(alignment: .bottom) { overflowFade }
                    .frame(width: geometry.size.width / 2)
                    .ignoresSafeArea(edges: .vertical)

                    mapColumn(coordinate)
                        .frame(width: geometry.size.width / 2, height: geometry.size.height)
                }
                // The station name lives in the left column (see above) — an
                // empty inline title keeps the bar clear of the map.
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
            } else {
                List {
                    fieldsSection
                    if let coordinate = elevator.coordinate {
                        mapRow(coordinate)
                    }
                    if let scene = lookAroundScene {
                        lookAroundRow(scene)
                    }
                    favoriteSection
                }
                .hissiList()
                .navigationTitle(elevator.stationName)
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        // The star rides the bar in both orientations — in landscape it is
        // the only favorite action (the column has no room for a row), in
        // portrait it is the one that stays reachable while the fields, the
        // map and the street-level view scroll past the list's own row.
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                let isFav = service.isFavorite(elevator.id)
                Button {
                    service.toggleFavorite(elevator)
                } label: {
                    Image(systemName: isFav ? "star.fill" : "star")
                }
                .accessibilityLabel(isFav ? "Aus Favoriten entfernen" : "Zu Favoriten hinzufügen")
            }
        }
        // A fix (or a later one) can bring the device into the frame.
        .onChange(of: location.state) { _, _ in
            guard let coordinate = elevator.coordinate else { return }
            withAnimation { camera = .region(cameraRegion(for: coordinate)) }
        }
        .task(id: elevator.id) {
            guard let coordinate = elevator.coordinate else {
                lookAroundScene = nil
                return
            }
            await loadLookAroundScene(at: coordinate)
        }
        // Live status before favoriting (FR3): one targeted request — the
        // same path a favorites refresh takes, free while the catalog cache
        // is fresh — instead of waiting for the search's full rebuild, which
        // this view would not even see (it holds a pushed snapshot).
        .task(id: initial.id) {
            guard !service.isFavorite(initial.id) else { return }
            let records = await EquipmentCatalog.shared.equipment(for: [initial.id])
            guard !Task.isCancelled, let record = records[initial.id] else { return }
            let merged = StatusMerge.apply(record, to: initial)
            refreshed = merged
            onRefreshed?(merged)
        }
    }

    @ViewBuilder
    private var fieldsSection: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: status.symbolName)
                    .font(.title2)
                    .foregroundStyle(status.symbolColor)
                    .accessibilityHidden(true)
                Text(status.label)
                    .font(.headline)
                    .foregroundStyle(status.textColor)
            }
            if !elevator.elevatorDescription.isEmpty {
                LabeledContent("Aufzug", value: elevator.elevatorDescription)
            }
            LabeledContent("Datenstand", value: elevator.lastUpdated.map(MonitoredElevator.relativeTime(since:)) ?? "unbekannt")
            if elevator.isDataStale {
                Label("Status möglicherweise veraltet", systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(Color.hissiStatusUnknownText)
            }
            if let stateExplanation = elevator.stateExplanation, !stateExplanation.isEmpty {
                LabeledContent("Störungsgrund", value: stateExplanation)
            }
            if !elevator.sourceName.isEmpty {
                LabeledContent("Quelle", value: elevator.sourceName)
            }
            if !elevator.organizationName.isEmpty {
                LabeledContent("Betreiber", value: elevator.organizationName)
            }
        }
        .hissiRows()
    }

    // Landscape only: whether the column shows everything is otherwise
    // invisible — List's laziness makes this row a reliable "end is on
    // screen" detector. When the content fits outright, it is visible from
    // the start and the fade never appears.
    private var bottomSentinel: some View {
        Color.clear
            .frame(height: 1)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets())
            .onAppear { reachedBottom = true }
            .onDisappear { reachedBottom = false }
            .accessibilityHidden(true)
    }

    // Content visibly fading out says "there is more" — the affordance plain
    // clipping doesn't give. Decorative only: no hit-testing, no VoiceOver
    // stop (traversal has no discoverability problem to solve).
    private var overflowFade: some View {
        LinearGradient(
            colors: [.clear, Color.hissiBackground],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: 32)
        .allowsHitTesting(false)
        .opacity(reachedBottom ? 0 : 1)
        .animation(.easeInOut(duration: 0.2), value: reachedBottom)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var favoriteSection: some View {
        Section {
            Button {
                service.toggleFavorite(elevator)
            } label: {
                let isFav = service.isFavorite(elevator.id)
                Label(
                    isFav ? "Aus Favoriten entfernen" : "Zu Favoriten hinzufügen",
                    systemImage: isFav ? "star.slash" : "star"
                )
            }
        }
        .hissiRows()
    }

    // Portrait: a fixed-height snippet as its own list row.
    private func mapRow(_ coordinate: CLLocationCoordinate2D) -> some View {
        Section {
            mapButton(coordinate)
                .frame(height: 160)
                .listRowInsets(EdgeInsets())
        }
        .hissiRows()
    }

    // The snippet, tappable, with the location affordance layered on top.
    private func mapButton(_ coordinate: CLLocationCoordinate2D) -> some View {
        Button {
            openInMaps(coordinate)
        } label: {
            mapSnippet(coordinate)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Kartenausschnitt \(elevator.stationName)")
        .accessibilityHint("In Karten öffnen")
        // Layered over the map button, not inside its label: a button nested
        // in another button's label leaves neither reliably tappable. Top
        // leading is the one free corner — the open-in-Maps pill holds the
        // bottom trailing one, and at 160 pt both would collide on a narrow
        // iPhone.
        .overlay(alignment: .topLeading) { locationAffordance }
    }

    // Priming affordance for the location prompt. The system dialog fires
    // from this tap and from nothing else — same rule as the nearby
    // suggestions, and the reason the map never asks on its own. Once the
    // grant is in (here or there) the dot speaks for itself and the pill
    // goes; a denial leaves the map as it was, without nagging.
    @ViewBuilder
    private var locationAffordance: some View {
        if !location.isAuthorized {
            switch location.state {
            case .idle:
                Button {
                    location.locate()
                } label: {
                    mapPill(Label("Meinen Standort anzeigen", systemImage: "location"))
                }
                .buttonStyle(.plain)
                .padding(8)
            case .locating:
                mapPill(Label("Standort wird ermittelt …", systemImage: "location"))
                    .padding(8)
                    .accessibilityElement(children: .combine)
            default:
                EmptyView()
            }
        }
    }

    // Same opaque pill as the open-in-Maps affordance — a translucent
    // material over arbitrary map imagery guarantees no contrast ratio.
    private func mapPill(_ label: Label<Text, Image>) -> some View {
        label
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.tint)
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(Color.hissiSurface, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.hissiSeparator))
    }

    // Portrait: the street-level view follows the map, same fixed height.
    private func lookAroundRow(_ scene: MKLookAroundScene) -> some View {
        Section {
            lookAroundPreview(scene)
                .frame(height: 160)
                .listRowInsets(EdgeInsets())
        }
        .hissiRows()
    }

    // Landscape: fills the trailing column edge-to-edge. Where Look Around
    // has coverage the column splits in half — the map keeps the context, the
    // street-level view shows what the elevator actually looks like.
    private func mapColumn(_ coordinate: CLLocationCoordinate2D) -> some View {
        VStack(spacing: 0) {
            mapButton(coordinate)

            if let scene = lookAroundScene {
                lookAroundPreview(scene)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // Tapping the preview opens the full-screen Look Around viewer — that is
    // MapKit's own behaviour, so no button wrapper, and unlike the map
    // snippet this keeps the user inside Hissi. The badge is Apple's
    // required attribution; top-trailing keeps it clear of the map snippet's
    // own bottom-trailing pill, which sits right above it in portrait.
    private func lookAroundPreview(_ scene: MKLookAroundScene) -> some View {
        LookAroundPreview(initialScene: scene, badgePosition: .topTrailing)
            // The preview exposes no useful VoiceOver label of its own.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Straßenansicht \(elevator.stationName)")
            .accessibilityHint("Rundumansicht öffnen")
            .accessibilityAddTraits(.isButton)
    }

    // Look Around covers Berlin and Brandenburg, but not every spot in them —
    // and a request can simply fail. Both mean the same thing here: no
    // street-level view, so the section stays away rather than showing an
    // empty frame.
    @MainActor
    private func loadLookAroundScene(at coordinate: CLLocationCoordinate2D) async {
        let request = MKLookAroundSceneRequest(coordinate: coordinate)
        lookAroundScene = try? await request.scene
    }

    private func mapSnippet(_ coordinate: CLLocationCoordinate2D) -> some View {
        Map(position: $camera) {
            // Lilac, not MapKit's red: red means "gestört" in this palette.
            Marker(elevator.stationName, coordinate: coordinate)
                .tint(Color.accentColor)
            // MapKit draws the dot itself once authorized — and never asks
            // for that authorization on its own, so this cannot surprise
            // anyone with a prompt. Without the grant it renders nothing.
            if location.isAuthorized {
                UserAnnotation()
            }
        }
        // Display-only — panning belongs to Maps, which the button opens.
        .allowsHitTesting(false)
        // A fully non-hit-testable label leaves the enclosing button nothing
        // to hit; the clear overlay is the tappable surface.
        .overlay(Color.clear.contentShape(Rectangle()))
        // Visible affordance — without it the snippet reads as static
        // content. The whole snippet stays the tap target; VoiceOver already
        // gets the button's own label and hint. Opaque background on purpose:
        // a translucent material over arbitrary map imagery cannot guarantee
        // any contrast ratio; the tint on the surface colour is WCAG AAA
        // (Shared/Colors.xcassets, checked in PaletteTests).
        .overlay(alignment: .bottomTrailing) {
            Label("In Karten öffnen", systemImage: "map.fill")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tint)
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .background(Color.hissiSurface, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.hissiSeparator))
                .padding(8)
        }
    }

    // Station alone, or station plus device position when the two are close
    // enough to share a frame. Further apart than `maxFitMeters` the fit
    // would zoom out so far that the station loses its context — and someone
    // 5 km away learns nothing from seeing both dots at once — so the
    // station keeps the frame and the dot simply sits off-screen.
    private func cameraRegion(for coordinate: CLLocationCoordinate2D) -> MKCoordinateRegion {
        let station = MKCoordinateRegion(center: coordinate, span: Self.stationSpan)
        guard case .located(let latitude, let longitude) = location.state else { return station }

        let distance = CLLocation(latitude: latitude, longitude: longitude)
            .distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
        guard distance <= Self.maxFitMeters else { return station }

        // Both points plus a margin, never tighter than the station frame.
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: (latitude + coordinate.latitude) / 2,
                longitude: (longitude + coordinate.longitude) / 2
            ),
            span: MKCoordinateSpan(
                latitudeDelta: max(abs(latitude - coordinate.latitude) * 2.4, Self.stationSpan.latitudeDelta),
                longitudeDelta: max(abs(longitude - coordinate.longitude) * 2.4, Self.stationSpan.longitudeDelta)
            )
        )
    }

    private func openInMaps(_ coordinate: CLLocationCoordinate2D) {
        let mapItem = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
        mapItem.name = elevator.stationName
        mapItem.openInMaps()
    }
}

private extension View {
    // iOS 26 renders a progressive blur (scroll edge effect) where content
    // scrolls under a bar. The deployment target predates the API, hence the
    // guard; earlier systems draw no such blur to begin with.
    @ViewBuilder
    func withoutTopScrollEdgeEffect() -> some View {
        if #available(iOS 26.0, *) {
            scrollEdgeEffectHidden(true, for: .top)
        } else {
            self
        }
    }
}
