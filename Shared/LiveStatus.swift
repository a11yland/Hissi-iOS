import Foundation

// The "Live-Status": one running report over all favorites that the user starts
// for a trip and that speaks up on its own — as a Live Activity on the Lock
// Screen and in the Dynamic Island. It is what the passive surfaces (widget,
// complications) cannot do: alert when something changes while the phone is in
// a pocket.
//
// Everything in this file is pure Foundation — no ActivityKit — so the rules
// stay unit-testable in the SwiftPM package (which builds on macOS) and the
// ActivityKit side stays a thin shell (Shared/LiveStatusAttributes.swift).
//
// nonisolated throughout: pure value types built from nonisolated contexts
// (widget extension, background task) while the targets default actor isolation
// to MainActor.

// MARK: - Mode

// How a live status ends — chosen when the user starts it, fixed for its
// lifetime (it is part of the Live Activity’s static attributes).
nonisolated enum LiveStatusMode: Codable, Hashable {
    // "Für die Fahrt": runs until a fixed end time.
    case trip(endsAt: Date)
    // "Bis alles wieder läuft": runs until no favorite is broken any more.
    case untilRepaired

    // Two hours cover a cross-town trip with changes and stay well inside the
    // few hours iOS grants a Live Activity before ending it itself.
    static let tripDuration: TimeInterval = 2 * 60 * 60

    var endsAt: Date? {
        switch self {
        case .trip(let date): date
        case .untilRepaired:  nil
        }
    }

    var label: String {
        switch self {
        case .trip:          String(localized: "Fahrt")
        case .untilRepaired: String(localized: "Bis alles wieder läuft")
        }
    }
}

// MARK: - State

// What the Live Activity draws — the ContentState, re-encoded on every update.
// Deliberately not `[MonitoredElevator]`: the payload is capped at 4 KB and the
// surfaces need a handful of fields, not the full records.
nonisolated struct LiveStatusState: Codable, Hashable {
    struct Row: Codable, Hashable, Identifiable {
        let id: String
        let stationName: String
        let elevatorDescription: String
        let isWorking: Bool?

        var status: ElevatorStatus { ElevatorStatus(isWorking: isWorking) }
    }

    // The Lock Screen fits three rows, the expanded Dynamic Island four —
    // beyond that the counts in the header do the talking.
    static let maxRows = 4

    let verdict: ElevatorSummary.Verdict
    let brokenCount: Int
    let unknownCount: Int
    let total: Int
    let affectedStations: [String]
    let rows: [Row]
    // Poll time (MonitoredElevator.lastChecked semantics): when the app last
    // asked — not how fresh the data is at the source. It drives the staleDate
    // the activity marks itself with.
    //
    // Taken from the elevators themselves rather than from "now": a state built
    // when nothing was polled (a favorite toggle, a failed refresh) must not
    // claim a fresh check. Explicit only in tests.
    let checkedAt: Date

    init(_ elevators: [MonitoredElevator], checkedAt: Date? = nil) {
        let summary = ElevatorSummary(elevators)
        verdict = summary.verdict
        brokenCount = summary.brokenCount
        unknownCount = summary.unknownCount
        total = summary.total
        affectedStations = summary.affectedStations
        rows = ElevatorRanking.byUrgency(elevators)
            .prefix(Self.maxRows)
            .map {
                Row(
                    id: $0.id,
                    stationName: $0.stationName,
                    elevatorDescription: $0.elevatorDescription,
                    isWorking: $0.isWorking
                )
            }
        self.checkedAt = checkedAt ?? elevators.compactMap(\.lastChecked).max() ?? Date()
    }

    // The aggregate verdict, rebuilt from the stored counts: the Live Activity
    // carries no elevators, and still has to say exactly what the widget and
    // the complications say (FR13).
    var summary: ElevatorSummary {
        ElevatorSummary(
            verdict: verdict,
            brokenCount: brokenCount,
            unknownCount: unknownCount,
            total: total,
            affectedStations: affectedStations
        )
    }

    // Favorites beyond the row cap — the "+ n weitere" line.
    var hiddenRowCount: Int { max(0, total - rows.count) }
}

// MARK: - Alerts

// A status change worth interrupting for. Without a push server this is the
// app's only way to warn actively, so it has to be rare enough to stay
// credible: only real transitions, never a re-announcement of a standing
// disruption on every refresh.
nonisolated enum LiveStatusAlert: Equatable {
    case broke(station: String, count: Int)
    case repaired(station: String)

    // Compared per elevator id, not by counts: one elevator breaking while
    // another is repaired leaves the counts identical and still deserves an
    // alert. Computed from the full favorites rather than the capped rows, so a
    // defect outside the displayed rows is not missed.
    //
    // Only elevators the live status already knew about count — one favorited
    // mid-trip that arrives broken is a fact, not an event it witnessed.
    static func transition(
        from previous: [MonitoredElevator]?,
        to current: [MonitoredElevator]
    ) -> LiveStatusAlert? {
        guard let previous, !previous.isEmpty else { return nil }
        let known = Set(previous.map(\.id))
        let brokenBefore = Set(previous.filter { $0.isWorking == false }.map(\.id))

        // Bad news outranks good news, same precedence as the verdict itself.
        let newlyBroken = current.filter {
            $0.isWorking == false && known.contains($0.id) && !brokenBefore.contains($0.id)
        }
        if let first = newlyBroken.first {
            return .broke(station: first.stationName, count: newlyBroken.count)
        }

        let repaired = current.filter { $0.isWorking == true && brokenBefore.contains($0.id) }
        if let first = repaired.first {
            return .repaired(station: first.stationName)
        }
        return nil
    }

    var title: String {
        switch self {
        case .broke:    String(localized: "Aufzug außer Betrieb")
        case .repaired: String(localized: "Aufzug wieder in Betrieb")
        }
    }

    var body: String {
        switch self {
        case .broke(let station, let count):
            count > 1 ? String(localized: "\(station) und \(count - 1) weitere") : station
        case .repaired(let station):
            station
        }
    }
}

// MARK: - Rules

nonisolated enum LiveStatusRules {
    // Why a live status stops: its time is up, the news is good again, or there
    // is nothing left to report on — an activity over an empty favorites list
    // would sit on the Lock Screen saying nothing.
    static func shouldEnd(mode: LiveStatusMode, state: LiveStatusState, now: Date) -> Bool {
        if state.verdict == .noFavorites { return true }
        switch mode {
        case .trip(let endsAt): return now >= endsAt
        case .untilRepaired:    return state.verdict == .allWorking
        }
    }
}

// MARK: - Cadence hint

// Whether a live status is running, mirrored into the App Group so nonisolated
// callers (the background-task scheduler) can pick the refresh cadence without
// reaching into ActivityKit or the main actor. ActivityKit stays the source of
// truth; this is a hint, and a stale `true` costs nothing but one earlier
// background-refresh request.
nonisolated enum LiveStatusFlag {
    private static let key = "liveStatusRunning"

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: ElevatorCache.appGroupID) ?? .standard
    }

    static var isRunning: Bool {
        get { defaults.bool(forKey: key) }
        set { defaults.set(newValue, forKey: key) }
    }
}
