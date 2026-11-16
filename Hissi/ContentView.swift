import SwiftUI

struct ContentView: View {
    @StateObject private var service = ElevatorMonitorService()
    @StateObject private var search = SearchService()
    @StateObject private var recents = RecentSearchesStore()
    @StateObject private var location = LocationProvider()
    // The running Live Activity, if any. A singleton because there is at most
    // one live status and it outlives any view — it even outlives the app
    // process.
    @ObservedObject private var liveStatus = LiveActivityController.shared
    // Session-only: resets to .system on every cold start by design.
    @State private var appearance: AppAppearance = .system

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme

    @State private var query = ""
    // Lets the empty favorites state open the search (and with it the nearby
    // block) from a button — the field itself is system-provided.
    @State private var isSearchPresented = false
    // Tapping a nearby station or recent search fills the field; the keyboard
    // has done its job by then and would cover the result.
    @FocusState private var isSearchFocused: Bool
    // Welcome on first launch, "Was ist neu" once per curated release.
    @State private var onboarding: WelcomeGate.Sheet?
    // The elevator in the detail column. Side by side wherever the width is
    // regular (iPhone Duo's inner display, iPad, Mac); collapsed into a push
    // on a compact width, where clearing it is the back navigation.
    @State private var selection: DetailSelection?
    // Both columns from the start: the list is the app's home. The system's
    // sidebar toggle stays — removing it also took the search field off the
    // iPad's bar.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    // Mirrored from the sidebar, which alone can read `isSearching`: whether
    // the list shows the favorites, the mode the favorites actions belong to.
    @State private var listShowsFavorites = true
    @State private var showsLiveStatus = false
    // Side by side in landscape: the actions leave the narrow sidebar's bar
    // for the detail column's, at the far trailing edge. Decided by the
    // window's own size and size class, never by device or orientation.
    @State private var actionsInDetail = false
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var isDark: Bool { (appearance.colorScheme ?? colorScheme) == .dark }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            // The search field itself is provided by the system: on iOS 26 iPhone
            // `.searchable` renders as a bottom-aligned Liquid Glass bar. `isSearching`
            // (read inside SearchableContent) drives the favorites/recents/results mode.
            SearchableContent(
                service: service,
                search: search,
                recents: recents,
                location: location,
                query: $query,
                isSearchFocused: $isSearchFocused,
                selection: $selection,
                listShowsFavorites: $listShowsFavorites
            )
            .toolbar {
                if !actionsInDetail { listActions }
            }
        } detail: {
            detailColumn
        }
        // Even columns: on iPhone Duo the system lines their boundary up
        // with the fold, so neither pane loses content to it.
        .navigationSplitViewStyle(.balanced)
        .onGeometryChange(for: Bool.self) { proxy in
            proxy.size.width > proxy.size.height
        } action: { isWide in
            actionsInDetail = isWide && horizontalSizeClass == .regular
        }
        .onChange(of: horizontalSizeClass) { _, sizeClass in
            if sizeClass != .regular { actionsInDetail = false }
        }
        .sheet(isPresented: $showsLiveStatus) {
            LiveStatusSheet(service: service, liveStatus: liveStatus)
        }
        .searchable(text: $query, isPresented: $isSearchPresented, prompt: "Station finden")
        .searchFocused($isSearchFocused)
        .autocorrectionDisabled()
        .onSubmit(of: .search) { recents.add(query) }
        .preferredColorScheme(appearance.colorScheme)
        .onAppear {
            onboarding = OnboardingState.pendingSheet()
            if DemoMode.launchLink == .nearby {
                showNearby()
                // Screenshot runs: the keyboard would cover half the shot.
                Task {
                    try? await Task.sleep(for: .seconds(1))
                    isSearchFocused = false
                }
            }
        }
        .sheet(item: $onboarding) { sheet in
            switch sheet {
            case .welcome:                 WelcomeSheet()
            case .whatsNew(let version):   WhatsNewSheet(version: version)
            }
        }
        // Selection feedback on favorite add/remove (count only changes then),
        // and error feedback when a refresh fails. Routine polls stay silent.
        .sensoryFeedback(.selection, trigger: service.elevators.count)
        // Starting and stopping the live status is a deliberate act — confirm
        // it like a favorite toggle.
        .sensoryFeedback(.selection, trigger: liveStatus.isRunning)
        .sensoryFeedback(trigger: service.errorMessage) { _, message in
            message == nil ? nil : .error
        }
        // Initial load + periodic refresh. Keyed on the live status so a mode
        // change restarts the loop: an in-flight 30-minute sleep would
        // otherwise keep its old cadence, and the restart's immediate refresh
        // is what hands a freshly started activity current data instead of
        // whatever age the last poll left behind.
        .task(id: liveStatus.isRunning) {
            await service.refresh()
            while !Task.isCancelled {
                // Tighter while the live status is running: the Live Activity
                // is the surface the user is looking at, and it only learns
                // something when the app refreshes (no push server).
                try? await Task.sleep(
                    for: .seconds(RefreshInterval.interval(liveStatusRunning: liveStatus.isRunning))
                )
                await service.refresh()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                // A Live Activity survives the app being killed — pick a
                // running one back up before offering to start another.
                liveStatus.adoptRunningActivity()
                Task { await service.refresh() }
            case .background:
                BackgroundRefreshManager.schedule()
            default:
                break
            }
        }
        // Debounce keystrokes; .task(id:) cancels the previous search — and its
        // in-flight catalog fetch — when the query changes.
        .task(id: query) {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await search.search(query)
        }
        // The error banner is a silent overlay; announce it so VoiceOver users
        // learn a refresh failed.
        .onChange(of: service.errorMessage) { _, message in
            if let message { AccessibilityNotification.Announcement(message).post() }
        }
        // A refresh's outcome: the status change in the live status alert's
        // words, or "no change" after a refresh the user asked for.
        .onChange(of: service.announcement) { _, announcement in
            if let announcement {
                AccessibilityNotification.Announcement(announcement.message).post()
            }
        }
        // The nearby widget's tap: same as the nearby button.
        .onOpenURL { url in
            guard AppDeepLink(url) == .nearby else { return }
            showNearby()
        }
    }

    @ViewBuilder
    private var detailColumn: some View {
        if let selection {
            ElevatorDetailView(
                elevator: selection.elevator,
                service: service,
                location: location,
                onRefreshed: selection.fromSearch
                    ? { search.apply($0, replacing: selection.elevator.id) }
                    : nil,
                listActions: actionsInDetail ? listActions : nil
            )
            // A fresh view per elevator: the map camera and the
            // street-level scene are state seeded from the elevator.
            .id(selection)
        } else {
            ContentUnavailableView {
                Label("Kein Aufzug ausgewählt", systemImage: "hand.tap")
            } description: {
                Text("Wähle einen Aufzug aus der Liste, um seinen Status und seine Lage zu sehen.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.hissiBackground.ignoresSafeArea())
            .toolbar {
                if actionsInDetail { listActions }
            }
        }
    }

    private var listActions: ListActions {
        ListActions(
            service: service,
            liveStatus: liveStatus,
            showsFavoritesActions: listShowsFavorites,
            appearance: $appearance,
            isDark: isDark,
            showsLiveStatus: $showsLiveStatus,
            showNearby: showNearby
        )
    }

    // Nearby lives on the recents screen, i.e. behind the search field:
    // locate first (prompting if needed), then present the search so the
    // block is on screen when the fix lands.
    private func showNearby() {
        location.locate()
        isSearchPresented = true
    }
}

// The area above the system search bar. Reads `isSearching` — which is only
// available to descendants of the `.searchable` modifier — to pick its mode.
private struct SearchableContent: View {
    @ObservedObject var service: ElevatorMonitorService
    @ObservedObject var search: SearchService
    @ObservedObject var recents: RecentSearchesStore
    @ObservedObject var location: LocationProvider
    @Binding var query: String
    var isSearchFocused: FocusState<Bool>.Binding
    @Binding var selection: DetailSelection?
    @Binding var listShowsFavorites: Bool

    @Environment(\.isSearching) private var isSearching
    @State private var showsAbout = false

    private enum Mode { case favorites, recents, results }
    private var mode: Mode {
        if !query.trimmingCharacters(in: .whitespaces).isEmpty { return .results }
        if isSearching { return .recents }
        return .favorites
    }

    private var title: String {
        switch mode {
        case .favorites: String(localized: "Favoriten")
        case .recents:   String(localized: "Letzte Suchen")
        case .results:   String(localized: "Suche")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The mode's headline sits below the toolbar, not in it: large
            // and left-aligned like a large title, but outside the scroll
            // view, so it stays put while the list moves under it (a system
            // large title would collapse into the bar instead).
            headline
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 8)
            content
        }
            // The recents' bulk delete, pinned right above the search field
            // so a long list never hides it.
            .safeAreaInset(edge: .bottom) { bottomAction }
            .onChange(of: mode == .favorites, initial: true) { _, isFavorites in
                listShowsFavorites = isFavorites
            }
            .background(Color.hissiBackground.ignoresSafeArea())
            // The title stays set for the detail's back button ("Favoriten"
            // rather than "Zurück") but is removed from the bar itself — the
            // headline above is the visible one.
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(removing: .title)
            .sheet(isPresented: $showsAbout) { AboutSheet() }
            // The logo stays with the list in every layout; the actions
            // (ListActions) are placed by ContentView.
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    // The app icon doubles as the way to "Über Hissi"; the
                    // "Logo" imageset mirrors the AppIcon assets (icon sets
                    // aren't reliably loadable at runtime). An image with an
                    // accessibility label, not a Label: a Label with a custom
                    // image folds the whole bar into its overflow menu on
                    // iOS 27 (see ListActions).
                    Button {
                        showsAbout = true
                    } label: {
                        Image("Logo")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 28, height: 28)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .accessibilityLabel("Über Hissi")
                }
            }
    }

    // The favorites carry the poll time at the headline's right: one shared
    // poll covers all of them, so "checked" is global (the rows show the
    // source's data age). Side by side while it fits, stacked at the larger
    // text sizes.
    private var headline: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                headlineTitle
                Spacer(minLength: 0)
                checkedLabel
            }
            VStack(alignment: .leading, spacing: 2) {
                headlineTitle
                checkedLabel
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var headlineTitle: some View {
        Text(title)
            .font(.largeTitle.weight(.bold))
            .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private var checkedLabel: some View {
        if mode == .favorites, let checked = service.elevators.compactMap(\.lastChecked).max() {
            Text("Geprüft \(MonitoredElevator.relativeTime(since: checked))")
                .font(.caption)
                .foregroundStyle(Color.hissiTextSecondary)
        }
    }

    @ViewBuilder
    private var bottomAction: some View {
        if mode == .recents, !recents.searches.isEmpty {
            pinnedAction("Letzte Suchen löschen", systemImage: "trash") { recents.clear() }
        }
    }

    private func pinnedAction(_ title: LocalizedStringKey, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
        }
        .buttonStyle(.bordered)
        // 44 pt tall — WCAG 2.5.5 (AAA) target size; the default bordered
        // control is ~30 pt.
        .controlSize(.large)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(Color.hissiBackground)
    }

    // Move-by-one, offered to assistive technologies in place of the drag.
    // Same call as `onMove`, so it lands in the manual order the same way.
    @ViewBuilder
    private func moveActions(for elevator: MonitoredElevator) -> some View {
        if let index = service.elevators.firstIndex(where: { $0.id == elevator.id }) {
            if index > 0 {
                Button("Nach oben bewegen") {
                    service.move(from: IndexSet(integer: index), to: index - 1)
                    announceMove(of: elevator, to: index - 1)
                }
            }
            if index < service.elevators.count - 1 {
                // SwiftUI's insertion offset counts the row itself, so one
                // step down is index + 2.
                Button("Nach unten bewegen") {
                    service.move(from: IndexSet(integer: index), to: index + 2)
                    announceMove(of: elevator, to: index + 1)
                }
            }
        }
    }

    // A drag tells you where the row landed by looking at it; an action
    // doesn't, so say it. Focus follows the row itself (ForEach is keyed on
    // the id), which leaves only the position to announce.
    private func announceMove(of elevator: MonitoredElevator, to index: Int) {
        let message = String(
            localized: "\(elevator.stationName) an Position \(index + 1) von \(service.elevators.count)"
        )
        AccessibilityNotification.Announcement(message).post()
    }

    @ViewBuilder
    private var content: some View {
        switch mode {
        case .favorites: favoritesContent
        case .recents:   recentsContent
        case .results:   SearchResultsList(search: search, service: service, selection: $selection, query: query)
        }
    }

    // MARK: - Favorites

    // Shown once after the transit.accessibility.cloud migration deleted
    // favorites stored under the old id schemes.
    private var legacyRemovalNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Favoriten zurückgesetzt", systemImage: "info.circle")
                .font(.subheadline.weight(.semibold))
            Text("Die App nutzt jetzt eine neue Datenquelle. Deine bisherigen Favoriten ließen sich nicht übernehmen und wurden entfernt – bitte füge deine Aufzüge über die Suche neu hinzu.")
                .font(.footnote)
                .foregroundStyle(Color.hissiTextSecondary)
            Button("Verstanden") {
                service.dismissLegacyRemovalNotice()
            }
            .font(.footnote.weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var favoritesContent: some View {
        if service.elevators.isEmpty {
            VStack(spacing: 0) {
                if service.showsLegacyRemovalNotice {
                    legacyRemovalNotice
                        .padding()
                        .background(Color.hissiSurface, in: RoundedRectangle(cornerRadius: 12))
                        .padding([.horizontal, .top])
                }
                ContentUnavailableView {
                    Label("Keine Favoriten", systemImage: "star")
                } description: {
                    Text("Suche nach einer Station, um Aufzüge zu finden und hinzuzufügen.")
                }
            }
        } else {
            List(selection: $selection) {
                if service.showsLegacyRemovalNotice {
                    Section {
                        legacyRemovalNotice
                    }
                    .hissiRows()
                }
                ForEach(service.elevators) { elevator in
                    let row = DetailSelection(elevator: elevator, fromSearch: false)
                    NavigationLink(value: row) {
                        ElevatorRowView(
                            elevator: elevator,
                            showsReorderHandle: service.elevators.count > 1
                        )
                    }
                    .accessibilityIdentifier("elevatorRow.\(ElevatorStatus(isWorking: elevator.isWorking))")
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            service.toggleFavorite(elevator)
                        } label: {
                            Label("Entfernen", systemImage: "star.slash")
                        }
                    }
                    // Dragging a row is a gesture VoiceOver and Switch Control
                    // users don't have — the same move as an action each.
                    .accessibilityActions { moveActions(for: elevator) }
                    .hissiRows()
                    .selectedRowMarker(selection == row)
                }
                // Long-press and drag reorders right here — no edit mode, no
                // setting to pick first. The drag itself is what moves the
                // list into "Eigene Reihenfolge"; new favorites still arrive
                // at the top.
                .onMove { source, destination in
                    service.move(from: source, to: destination)
                }

            }
            .hissiList()
            .refreshable { await service.refreshRequestedByUser() }
            .overlay {
                if let error = service.errorMessage {
                    VStack {
                        Spacer()
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(Color.hissiTextSecondary)
                            .padding(.bottom, 8)
                    }
                }
            }
        }
    }

    // MARK: - Recent searches & nearby

    private var recentsContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                NearbyStationsSection(location: location) { name in
                    query = name
                    recents.add(name)
                    isSearchFocused.wrappedValue = false
                }
                RecentSearchChips(recents: recents) { term in
                    query = term
                    recents.add(term)
                    isSearchFocused.wrappedValue = false
                }
            }
            .padding()
        }
    }
}

// The split view's selection: the elevator the detail column shows, and
// whether it was opened from the search — that one's refreshed copy goes back
// to the results row. Equal by id and origin only: a refresh rewrites the
// row's elevator, and the list must still recognise it as the selected one.
struct DetailSelection: Hashable {
    let elevator: MonitoredElevator
    let fromSearch: Bool

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.elevator.id == rhs.elevator.id && lhs.fromSearch == rhs.fromSearch
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(elevator.id)
        hasher.combine(fromSearch)
    }
}

extension View {
    // Rows paint their own surface (hissiRows), which hides the List's
    // selection highlight — with list and detail side by side, the row the
    // detail belongs to gets a tint bar along its leading edge instead. A
    // shape, not a fill: the row's text keeps the contrast it was tested on,
    // and the tint is well above the 3:1 non-text minimum on the surface.
    // Must come after hissiRows(), which it overrides for the selected row.
    func selectedRowMarker(_ isSelected: Bool) -> some View {
        listRowBackground(
            Color.hissiSurface.overlay(alignment: .leading) {
                if isSelected {
                    Rectangle().fill(.tint).frame(width: 4)
                }
            }
        )
    }
}

extension ToolbarContent {
    // Which items a side bar on iPhone Duo keeps longest before moving them
    // into the overflow menu. The API is iOS 27; earlier systems have no
    // overflow to order.
    @ToolbarContentBuilder
    func hissiVisibilityPriority(_ priority: HissiToolbarPriority) -> some ToolbarContent {
        if #available(iOS 27.0, *) {
            visibilityPriority(priority == .high ? .high : .low)
        } else {
            self
        }
    }
}

enum HissiToolbarPriority { case high, low }

#Preview {
    ContentView()
}
