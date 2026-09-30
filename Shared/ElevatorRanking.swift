import Foundation

// Urgency order for every surface that has to cut the favorites short: broken
// first, then unknown, then working — a broken elevator is the whole point of
// the app and must survive the cap. Stable within each group, which
// `sorted(by:)` does not promise on its own; hence the index tie-breaker.
//
// nonisolated: pure ordering, called from nonisolated contexts (timeline
// providers, Live Activity state) while the targets default to MainActor.
nonisolated enum ElevatorRanking {
    static func byUrgency(_ elevators: [MonitoredElevator]) -> [MonitoredElevator] {
        elevators.enumerated()
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map(\.element)
    }

    private static func rank(_ elevator: MonitoredElevator) -> Int {
        switch elevator.isWorking {
        case .some(false): 0
        case .none:        1
        case .some(true):  2
        }
    }
}
