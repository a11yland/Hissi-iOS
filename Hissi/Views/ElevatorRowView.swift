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
                Text(elevator.stationName)
                    .font(.body)
                    .fontWeight(.semibold)

                if !elevator.elevatorDescription.isEmpty {
                    Text(elevator.elevatorDescription)
                        .font(.subheadline)
                        .foregroundStyle(Color.hissiTextSecondary)
                }

                Text(status.label)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(status.textColor)

                Text(elevator.lastUpdatedLabel)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

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
                    .foregroundStyle(.tertiary)
                    // Centered against a top-aligned row.
                    .frame(maxHeight: .infinity)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 6)
    }
}
