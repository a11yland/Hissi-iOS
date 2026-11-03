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
//
// Sized to its content: one card, no list — the sheet is as tall as the
// card plus its title row, measured, so it never shows an empty half.
struct LiveStatusSheet: View {
    @ObservedObject var service: ElevatorMonitorService
    @ObservedObject var liveStatus: LiveActivityController
    @Environment(\.dismiss) private var dismiss
    // The measured content height drives the one detent; the initial value
    // only covers the first frame before the measurement lands.
    @State private var contentHeight: CGFloat = 240

    private var hasBroken: Bool {
        service.elevators.contains { $0.isWorking == false }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Live-Status")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Fertig") { dismiss() }
                    .font(.body.weight(.semibold))
            }
            VStack(alignment: .leading, spacing: 8) {
                if let mode = liveStatus.mode {
                    running(mode)
                } else {
                    idle
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Color.hissiSurface, in: RoundedRectangle(cornerRadius: 12))
        }
        .padding(.horizontal, 16)
        // Room for the drag indicator above, the home indicator below.
        .padding(.top, 24)
        .padding(.bottom, 16)
        // Measured at its ideal height, not at the sheet's current one —
        // otherwise the text wraps to whatever the first detent allows and
        // the measurement just confirms the truncation.
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .presentationDetents([.height(contentHeight)])
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
            // text sizes on, one below the other. Centered and 44 pt tall,
            // like the nearby button above the search field.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { startButtons }
                VStack(spacing: 12) { startButtons }
            }
            .controlSize(.large)
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
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
            .controlSize(.large)
        }
    }

    private func endLabel(_ mode: LiveStatusMode) -> String {
        guard let endsAt = mode.endsAt else { return mode.label }
        return String(localized: "Endet um \(endsAt.formatted(date: .omitted, time: .shortened))")
    }
}
