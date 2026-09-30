import SwiftUI

// The one place the live status (Live Activity) is started and stopped. It sits
// above the favorites list because that is exactly its scope — the whole set,
// not a single elevator.
//
// Two ways to start, because there are two situations: "Für die Fahrt" for the
// next couple of hours, and — only while something is actually broken — "Bis
// alles wieder läuft", which ends itself the moment the news is good.
struct LiveStatusSection: View {
    @ObservedObject var service: ElevatorMonitorService
    @ObservedObject var liveStatus: LiveActivityController

    private var hasBroken: Bool {
        service.elevators.contains { $0.isWorking == false }
    }

    // Carries its own Section so that switching Live Activities off leaves no
    // empty section behind in the favorites list.
    var body: some View {
        // Live Activities switched off for Hissi: nothing is offered and
        // nothing is nagged about — the user turned them off on purpose.
        if liveStatus.areActivitiesEnabled || liveStatus.isRunning {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    if let mode = liveStatus.mode {
                        running(mode)
                    } else {
                        idle
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .hissiRows()
        }
    }

    // MARK: - Not running

    private var idle: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Live-Status starten", systemImage: "bell.badge")
                .font(.subheadline.weight(.semibold))
            Text("Zeigt deine Favoriten auf dem Sperrbildschirm und meldet sich, wenn ein Aufzug ausfällt oder wieder läuft.")
                .font(.footnote)
                .foregroundStyle(Color.hissiTextSecondary)
            HStack(spacing: 12) {
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
            .font(.footnote.weight(.semibold))
            // The system ends Live Activities after a few hours — said once
            // here instead of surprising anyone later.
            Text("Endet automatisch, spätestens nach einigen Stunden.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
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
