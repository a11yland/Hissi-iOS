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

    private var isDark: Bool { (appearance.colorScheme ?? colorScheme) == .dark }

    var body: some View {
        NavigationStack {
            // The search field itself is provided by the system: on iOS 26 iPhone
            // `.searchable` renders as a bottom-aligned Liquid Glass bar. `isSearching`
            // (read inside SearchableContent) drives the favorites/recents/results mode.
            SearchableContent(
                service: service,
                search: search,
                recents: recents,
                location: location,
                liveStatus: liveStatus,
                query: $query,
                isSearchPresented: $isSearchPresented,
                isSearchFocused: $isSearchFocused,
                appearance: $appearance,
                isDark: isDark
            )
        }
        .searchable(text: $query, isPresented: $isSearchPresented, prompt: "Station finden")
        .searchFocused($isSearchFocused)
        .autocorrectionDisabled()
        .onSubmit(of: .search) { recents.add(query) }
        .preferredColorScheme(appearance.colorScheme)
        .onAppear { onboarding = OnboardingState.pendingSheet() }
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
        // The nearby widget's tap: same as the empty state's button.
        .onOpenURL { url in
            guard AppDeepLink(url) == .nearby else { return }
            location.locate()
            isSearchPresented = true
        }
    }
}

// The area above the system search bar. Reads `isSearching` — which is only
// available to descendants of the `.searchable` modifier — to pick its mode.
private struct SearchableContent: View {
    @ObservedObject var service: ElevatorMonitorService
    @ObservedObject var search: SearchService
    @ObservedObject var recents: RecentSearchesStore
    @ObservedObject var location: LocationProvider
    @ObservedObject var liveStatus: LiveActivityController
    @Binding var query: String
    @Binding var isSearchPresented: Bool
    var isSearchFocused: FocusState<Bool>.Binding
    @Binding var appearance: AppAppearance
    let isDark: Bool

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
        content
            .background(Color.hissiBackground.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showsAbout) { AboutSheet() }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    // The app icon doubles as the way to "Über Hissi"; the
                    // "Logo" imageset mirrors the AppIcon assets (icon sets
                    // aren't reliably loadable at runtime).
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
                if mode == .favorites, service.elevators.count > 1 {
                    ToolbarItem(placement: .topBarTrailing) {
                        sortMenu
                    }
                }
                if mode == .favorites, !service.elevators.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        if service.isLoading {
                            ProgressView()
                                .accessibilityLabel("Wird aktualisiert")
                        } else {
                            Button {
                                Task { await service.refreshRequestedByUser() }
                            } label: {
                                Image(systemName: "arrow.clockwise")
                            }
                            .accessibilityLabel("Aktualisieren")
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        appearance = isDark ? .light : .dark
                    } label: {
                        Image(systemName: isDark ? "sun.max.fill" : "moon.stars.fill")
                    }
                    .accessibilityLabel(isDark ? "Zu hellem Erscheinungsbild wechseln" : "Zu dunklem Erscheinungsbild wechseln")
                }
            }
    }

    // Sorting sits on the top level, not behind an overflow menu: it belongs
    // to the list below it. The menu is a state display — which order the
    // list is in, and the way back to the default. Nothing in here has to be
    // set before dragging a row; a drag moves the list into "Eigene
    // Reihenfolge" by itself.
    private var sortMenu: some View {
        Menu {
            Section("Sortieren") {
                Picker("Sortieren", selection: Binding(
                    get: { service.order },
                    set: { service.setOrder($0) }
                )) {
                    ForEach(FavoritesOrder.allCases, id: \.self) { order in
                        Text(order.label).tag(order)
                    }
                }
                .pickerStyle(.inline)
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .accessibilityLabel("Sortieren")
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
        case .results:   SearchResultsList(search: search, service: service, location: location, query: query)
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
                    Text("Tippe unten ins Suchfeld, um Aufzüge zu finden und hinzuzufügen.")
                } actions: {
                    Button {
                        showNearby()
                    } label: {
                        Label("Stationen in der Nähe anzeigen", systemImage: "location")
                    }
                    .buttonStyle(.bordered)
                    // 44 pt tall — WCAG 2.5.5 (AAA) target size; the default
                    // bordered control is ~30 pt.
                    .controlSize(.large)
                }
            }
        } else {
            List {
                if service.showsLegacyRemovalNotice {
                    Section {
                        legacyRemovalNotice
                    }
                    .hissiRows()
                }
                // Above the list because the live status covers the whole
                // list. Only here: with no favorites there is nothing to report
                // on. Brings its own Section — it disappears entirely when Live
                // Activities are switched off.
                LiveStatusSection(service: service, liveStatus: liveStatus)
                // Same entry as the empty state's button, above the favorites
                // (the list can run long, the entry must not sit under it).
                Section {
                    Button {
                        showNearby()
                    } label: {
                        Label("Stationen in der Nähe anzeigen", systemImage: "location")
                    }
                }
                .hissiRows()
                ForEach(service.elevators) { elevator in
                    NavigationLink {
                        ElevatorDetailView(elevator: elevator, service: service, location: location)
                    } label: {
                        ElevatorRowView(
                            elevator: elevator,
                            showsReorderHandle: service.elevators.count > 1
                        )
                    }
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
                }
                // Long-press and drag reorders right here — no edit mode, no
                // setting to pick first. The drag itself is what moves the
                // list into "Eigene Reihenfolge"; new favorites still arrive
                // at the top.
                .onMove { source, destination in
                    service.move(from: source, to: destination)
                }

                Section {} footer: {
                    VStack(spacing: 6) {
                        // One shared poll covers all favorites, so "checked" is
                        // global; the per-row line shows the source's data age.
                        if let checked = service.elevators.compactMap(\.lastChecked).max() {
                            Text("Geprüft \(MonitoredElevator.relativeTime(since: checked))")
                                .font(.caption2)
                        }
                        // A file of the favorites to keep or hand on (FR4b) —
                        // quiet, in the footer: it is an occasional errand, not
                        // part of checking elevators.
                        ShareLink(
                            item: FavoritesExportFile(favorites: service.elevators, order: service.order),
                            preview: SharePreview("Hissi-Favoriten")
                        ) {
                            Label("Favoriten exportieren", systemImage: "square.and.arrow.up")
                                .font(.caption)
                        }
                        .padding(.vertical, 4)
                        AttributionFooter()
                    }
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

    // Nearby lives on the recents screen, i.e. behind the search field:
    // locate first (prompting if needed), then present the search so the
    // block is on screen when the fix lands.
    private func showNearby() {
        location.locate()
        isSearchPresented = true
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

// accessibility.cloud requires visible attribution of its data — and the
// platform is Sozialhelden's, so the footer names them too. One Text with
// two markdown links so the line wraps as a whole on narrow widths.
private struct AttributionFooter: View {
    var body: some View {
        Text("Daten von [accessibility.cloud](https://transit.accessibility.cloud), einem Projekt der [Sozialhelden e.V.](https://sozialhelden.de)")
            .font(.caption2)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, alignment: .center)
    }
}

#Preview {
    ContentView()
}
