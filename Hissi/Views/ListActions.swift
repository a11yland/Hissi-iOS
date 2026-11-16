import SwiftUI

// The list screen's actions, in the one order every bar shows them: sort,
// refresh, appearance, live status, nearby. One declaration for two homes —
// the sidebar's bar, or, where list and detail stand side by side in
// landscape (iPhone Duo's inner display, iPad, Mac), the detail column's bar
// at the far trailing edge (ContentView decides).
//
// Every action is a `Label` with a title and a system symbol: the bar draws
// the symbol (on iPhone Duo's side bar it only takes items it can draw as
// one), the overflow menu shows symbol and title, and VoiceOver reads the
// title. Never a custom view or a custom image as the label's icon — one
// such item (the logo, tried as a Label) folds the whole bar into its
// overflow menu on iOS 27.
struct ListActions: ToolbarContent {
    @ObservedObject var service: ElevatorMonitorService
    @ObservedObject var liveStatus: LiveActivityController
    // Sort, refresh, live status and nearby belong to the favorites; the
    // appearance toggle is there in every mode.
    let showsFavoritesActions: Bool
    @Binding var appearance: AppAppearance
    let isDark: Bool
    @Binding var showsLiveStatus: Bool
    let showNearby: () -> Void

    var body: some ToolbarContent {
        if showsFavoritesActions, service.elevators.count > 1 {
            ToolbarItem(placement: .topBarTrailing) {
                sortMenu
            }
        }
        if showsFavoritesActions, !service.elevators.isEmpty {
            // Stays a button while loading — swapping in a spinner would make
            // the item jump out of a vertical bar and back.
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await service.refreshRequestedByUser() }
                } label: {
                    Label(service.isLoading ? "Wird aktualisiert" : "Aktualisieren", systemImage: "arrow.clockwise")
                        .symbolEffect(.rotate, isActive: service.isLoading)
                }
                .disabled(service.isLoading)
            }
            .hissiVisibilityPriority(.high)
        }
        // The least used item — first into the overflow menu when a side bar
        // runs out of room.
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                appearance = isDark ? .light : .dark
            } label: {
                Label(
                    isDark ? "Zu hellem Erscheinungsbild wechseln" : "Zu dunklem Erscheinungsbild wechseln",
                    systemImage: isDark ? "sun.max.fill" : "moon.stars.fill"
                )
            }
        }
        .hissiVisibilityPriority(.low)
        // The live status covers the whole favorites set, so it is an action
        // of this screen — the bell, filled while it runs. Only with
        // favorites (nothing to report on otherwise), and not at all while
        // Live Activities are switched off for Hissi: the user turned them
        // off on purpose. Its fill is a status, so it stays visible longest.
        if showsFavoritesActions, !service.elevators.isEmpty,
           liveStatus.areActivitiesEnabled || liveStatus.isRunning {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showsLiveStatus = true
                } label: {
                    Label(
                        liveStatus.isRunning ? "Live-Status läuft" : "Live-Status",
                        systemImage: liveStatus.isRunning ? "bell.badge.fill" : "bell.badge"
                    )
                }
                .accessibilityIdentifier("liveStatusButton")
            }
            .hissiVisibilityPriority(.high)
        }
        // Opens the search with the nearby block and starts the location fix.
        // With or without favorites — on an empty list it is one of the two
        // ways in.
        if showsFavoritesActions {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: showNearby) {
                    Label("Stationen in der Nähe anzeigen", systemImage: "location")
                }
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
            Label("Sortieren", systemImage: "arrow.up.arrow.down")
        }
    }
}
