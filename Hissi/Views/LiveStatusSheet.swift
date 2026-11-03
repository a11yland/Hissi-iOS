import SwiftUI

// The one place the live status (Live Activity) is started and stopped — a
// sheet behind the bell in the favorites toolbar, so the list itself stays
// the favorites. Its scope is the whole set, not a single elevator, which is
// why it is a toolbar action of the favorites screen and not a row.
//
// Two ways to start, because there are two situations: "Für die Fahrt" for the
// next couple of hours, and — only while something is actually broken — "Bis
// alles wieder läuft", which ends itself the moment the news is good. The
// sheet stays up after a start so the switch to "läuft" is seen, not guessed.
struct LiveStatusSheet: View {
    @ObservedObject var service: ElevatorMonitorService
    @ObservedObject var liveStatus: LiveActivityController
    @Environment(\.dismiss) private var dismiss

    private var hasBroken: Bool {
        service.elevators.contains { $0.isWorking == false }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        if let mode = liveStatus.mode {
                            running(mode)
                        } else {
                            idle
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }
                .hissiRows()
            }
            .hissiList()
            .navigationTitle("Live-Status")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Color.hissiBackground)
    }

    // MARK: - Not running

    private var idle: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Live-Status starten", systemImage: "bell.badge")
                .font(.subheadline.weight(.semibold))
            // The system ends Live Activities after a few hours — said once
            // here instead of surprising anyone later.
            Text("Zeigt deine Favoriten auf dem Sperrbildschirm und meldet sich, wenn ein Aufzug ausfällt oder wieder läuft. Endet automatisch, spätestens nach einigen Stunden.")
                .font(.footnote)
                .foregroundStyle(Color.hissiTextSecondary)
            // Side by side while they fit; from the larger accessibility
            // text sizes on, one below the other.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { startButtons }
                VStack(alignment: .leading, spacing: 12) { startButtons }
            }
            .font(.footnote.weight(.semibold))
        }
    }

    @ViewBuilder
    private var startButtons: some View {
        Button {
            liveStatus.start(
                .trip(endsAt: Date().addingTimeInterval(LiveStatusMode.tripDuration)),
                with: service.elevators
            )
        } label: {
            Text("Für die Fahrt (2 Std.)")
                .prominentButtonLabel()
        }
        .buttonStyle(.borderedProminent)
        if hasBroken {
            Button("Bis alles wieder läuft") {
                liveStatus.start(.untilRepaired, with: service.elevators)
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: - Running

    private func running(_ mode: LiveStatusMode) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Label("Live-Status läuft", systemImage: "bell.badge.fill")
                    .font(.subheadline.weight(.semibold))
                Text(endLabel(mode))
                    .font(.footnote)
                    .foregroundStyle(Color.hissiTextSecondary)
            }
            Spacer(minLength: 0)
            Button("Beenden") {
                Task { await liveStatus.end() }
            }
            .buttonStyle(.bordered)
            .font(.footnote.weight(.semibold))
        }
    }

    private func endLabel(_ mode: LiveStatusMode) -> String {
        guard let endsAt = mode.endsAt else { return mode.label }
        return String(localized: "Endet um \(endsAt.formatted(date: .omitted, time: .shortened))")
    }
}
