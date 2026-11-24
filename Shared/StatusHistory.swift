import Foundation

// Since when a status holds that no current span dates — above all "in
// Betrieb": a working elevator has no active span, the moment it came back is
// the end of the span before. Pure and unit-tested; the spans come from
// AccessibilityCloudClient.fetchLatestSpans.
nonisolated enum StatusHistory {
    typealias StatusSpan = AccessibilityCloudClient.StatusSpan

    // The latest-started span decides. Closed with another status than the
    // current one ⇒ its end is the transition (upstream chains spans, often
    // through `unknown`: out_of_service → unknown → in_service). Still open ⇒
    // nil: had it agreed with the status, the join would have dated it; as it
    // doesn't, the order of events is unclear. Closed with the same status ⇒
    // nil, the gap after it is unaccounted for. Never a guess.
    static func since(isWorking: Bool?, spans: [StatusSpan], now: Date = Date()) -> Date? {
        let latest = spans
            .filter { span in span.start.map { $0 <= now } ?? false }
            .max { ($0.start ?? .distantPast) < ($1.start ?? .distantPast) }
        guard let latest, let end = latest.end, end <= now, latest.isWorking != isWorking else { return nil }
        return end
    }

    // Fills `statusSince` where it is still unknown; a known value is never
    // overwritten (the current span's start is the better witness).
    static func applied(
        to elevators: [MonitoredElevator],
        spans: [StatusSpan],
        now: Date = Date()
    ) -> [MonitoredElevator] {
        let spansByElevator = Dictionary(
            grouping: spans.flatMap { span in span.elevatorIds.map { ($0, span) } },
            by: { $0.0 }
        ).mapValues { $0.map(\.1) }
        return elevators.map { elevator in
            guard elevator.statusSince == nil, let own = spansByElevator[elevator.id] else { return elevator }
            var dated = elevator
            dated.statusSince = since(isWorking: elevator.isWorking, spans: own, now: now)
            return dated
        }
    }
}
