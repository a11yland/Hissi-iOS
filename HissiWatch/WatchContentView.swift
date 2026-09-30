import SwiftUI

// The palette's dark values, spelled out: the watch is always dark and the
// wrist is not the place to trust the catalog's appearance resolution. On
// black: #3FE0C5 → 12.7:1, #FBBF24 → 12.3:1, #FB7185 → 7.8:1, #B9AEC2 → 9.7:1.
extension Color {
    static let watchStatusGreen = Color(red: 63/255,  green: 224/255, blue: 197/255)
    static let watchStatusAmber = Color(red: 251/255, green: 191/255, blue: 36/255)
    static let watchStatusRed   = Color(red: 251/255, green: 113/255, blue: 133/255)
    // Rows as cards on the dark surface, like the phone's list.
    static let watchSurface = Color(red: 34/255, green: 27/255, blue: 43/255)
    static let watchTextSecondary = Color(red: 185/255, green: 174/255, blue: 194/255)
}

extension ElevatorStatus {
    var watchColor: Color {
        switch self {
        case .working: .watchStatusGreen
        case .broken:  .watchStatusRed
        case .unknown: .watchStatusAmber
        }
    }
}

private func statusColor(_ working: Bool?) -> Color {
    ElevatorStatus(isWorking: working).watchColor
}

extension View {
    // A carousel row as a card on the surface colour — a plain Color would
    // fill the row square, the rounded shape keeps the carousel's outline.
    func watchCard() -> some View {
        listRowBackground(RoundedRectangle(cornerRadius: 14).fill(Color.watchSurface))
    }
}

private func statusLabel(_ working: Bool?) -> String {
    ElevatorStatus(isWorking: working).label
}

// Screens the root stack pushes besides an elevator id (String).
enum WatchRoute: Hashable {
    case nearby
}

struct WatchContentView: View {
    @StateObject private var sync = WatchSync()
    @StateObject private var service = WatchElevatorService()
    // Type-erased on purpose: the nearby screen pushes its own station
    // values from inside the stack (WatchNearbyView), which a typed path
    // couldn't hold next to the elevator ids.
    @State private var path = NavigationPath()

    private var elevators: [MonitoredElevator] {
        sync.received ?? service.elevators
    }

    var body: some View {
        NavigationStack(path: $path) {
            // Without favorites the list is just the nearby entry — no
            // "Keine Daten" placeholder: the watch can't tell "none" from
            // "not synced yet", and neither reading is something to act on
            // here (favorites are managed on the phone).
            List {
                // First, above the favorites: reachable without the
                // complication (a face slot is optional, the feature isn't),
                // and where the wrist starts scrolling — the favorites can
                // run long, this entry must not sit under them.
                NavigationLink(value: WatchRoute.nearby) {
                    Label("In der Nähe", systemImage: "location")
                        .font(.caption)
                        .fontWeight(.semibold)
                }
                .watchCard()

                ForEach(elevators) { elevator in
                    NavigationLink(value: elevator.id) {
                        WatchElevatorRow(elevator: elevator)
                    }
                    .watchCard()
                }

                // One shared poll covers all favorites, so "checked"
                // is shown once instead of per elevator.
                if let checked = elevators.compactMap(\.lastChecked).max() {
                    Text("Geprüft \(MonitoredElevator.relativeTime(since: checked))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                }
            }
            .listStyle(.carousel)
            .navigationDestination(for: String.self) { id in
                WatchElevatorPager(elevators: elevators, startId: id)
            }
            .navigationDestination(for: WatchRoute.self) { route in
                switch route {
                case .nearby: WatchNearbyView()
                }
            }
            // The mark instead of a wordmark: watchOS puts the title top-left,
            // where the icon identifies the app just as well and spends no
            // width on letters. VoiceOver still gets the name.
            .navigationTitle {
                LogoMark()
                    .frame(height: 18)
                    .accessibilityLabel(Text(verbatim: "Hissi"))
            }
        }
        .task {
            await service.refresh()
        }
        // The nearby complication's tap lands here (cold start included):
        // replace whatever is pushed, the user asked for one screen.
        .onOpenURL { url in
            guard let link = AppDeepLink(url) else { return }
            switch link {
            case .nearby: path = NavigationPath([WatchRoute.nearby])
            }
        }
    }
}

struct WatchElevatorPager: View {
    let elevators: [MonitoredElevator]
    @State private var selection: String

    init(elevators: [MonitoredElevator], startId: String) {
        self.elevators = elevators
        _selection = State(initialValue: startId)
    }

    var body: some View {
        TabView(selection: $selection) {
            ForEach(elevators) { elevator in
                WatchElevatorDetailView(elevator: elevator)
                    .tag(elevator.id)
            }
        }
        .tabViewStyle(.verticalPage)
    }
}

struct WatchElevatorDetailView: View {
    let elevator: MonitoredElevator

    var body: some View {
        let color = statusColor(elevator.isWorking)
        let status = ElevatorStatus(isWorking: elevator.isWorking)
        VStack(spacing: 6) {
            Image(systemName: status.symbolName)
                .font(.title3)
                .foregroundStyle(color)
                .accessibilityHidden(true)

            Text(elevator.stationName)
                .font(.headline)
                .multilineTextAlignment(.center)
                .lineLimit(2)

            if !elevator.elevatorDescription.isEmpty {
                Text(elevator.elevatorDescription)
                    .font(.caption2)
                    .foregroundStyle(Color.watchTextSecondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }

            Text(statusLabel(elevator.isWorking))
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(color)

            if let stateExplanation = elevator.stateExplanation, !stateExplanation.isEmpty {
                Text(stateExplanation)
                    .font(.caption2)
                    .foregroundStyle(Color.watchTextSecondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            }

            Text(elevator.lastUpdatedLabel)
                .font(.caption2)
                .foregroundStyle(.tertiary)

            if elevator.isDataStale {
                Label("Evtl. veraltet", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(Color.watchStatusAmber)
            }

            if !elevator.sourceName.isEmpty || !elevator.organizationName.isEmpty {
                VStack(spacing: 1) {
                    if !elevator.sourceName.isEmpty { Text(elevator.sourceName) }
                    if !elevator.organizationName.isEmpty { Text(elevator.organizationName) }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
            }

        }
        .padding(.horizontal, 8)
    }
}

struct WatchElevatorRow: View {
    let elevator: MonitoredElevator

    var body: some View {
        let color = statusColor(elevator.isWorking)
        let status = ElevatorStatus(isWorking: elevator.isWorking)
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: status.symbolName)
                .font(.caption)
                .foregroundStyle(color)
                .padding(.top, 2)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(elevator.stationName)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .lineLimit(2)

                if !elevator.elevatorDescription.isEmpty {
                    Text(elevator.elevatorDescription)
                        .font(.caption2)
                        .foregroundStyle(Color.watchTextSecondary)
                        .lineLimit(2)
                }

                Text(statusLabel(elevator.isWorking))
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundStyle(color)
            }
        }
        .padding(.vertical, 2)
    }
}
