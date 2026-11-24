import SwiftUI

struct ElevatorRowView: View {
    let elevator: MonitoredElevator
    // Favorites can be dragged into any order, which is a gesture nothing on
    // screen would otherwise hint at — the grip is that hint. Purely visual:
    // the drag starts anywhere on the row, and assistive technologies get the
    // move as an action instead (ContentView.moveActions).
    var showsReorderHandle = false

    private var status: ElevatorStatus { .init(isWorking: elevator.isWorking) }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: status.symbolName)
                .font(.title3)
                .foregroundStyle(status.symbolColor)
                // Morph the symbol instead of hard-swapping when a status
                // flips (search phase 2 landing, favorites refresh).
                .contentTransition(.symbolEffect(.replace))
                .animation(.default, value: elevator.isWorking)
                .padding(.top, 2)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                // Spelled out rather than the inherited primary style: a
                // selected row (list beside detail) would otherwise turn it
                // white on the row's light surface.
                Text(elevator.stationName)
                    .font(.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color(uiColor: .label))

                if !elevator.elevatorDescription.isEmpty {
                    Text(elevator.elevatorDescription)
                        .font(.subheadline)
                        .foregroundStyle(Color.hissiTextSecondary)
                }

                Text(status.label)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(status.textColor)

                // How long the status has held; left out while the source
                // doesn't say — never a data age dressed up as a duration.
                if let since = elevator.statusSinceLabel() {
                    Text(since)
                        .font(.caption2)
                        .foregroundStyle(Color.hissiTextSecondary)
                        .accessibilityLabel(elevator.statusSinceLabel(spoken: true) ?? since)
                }

                if elevator.isDataStale {
                    Label("Status möglicherweise veraltet", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(Color.hissiStatusUnknownText)
                }
            }

            Spacer()

            if showsReorderHandle {
                Image(systemName: "line.3.horizontal")
                    .font(.footnote)
                    .foregroundStyle(Color(uiColor: .tertiaryLabel))
                    // Centered against a top-aligned row.
                    .frame(maxHeight: .infinity)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 6)
    }
}
