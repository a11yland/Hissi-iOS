import Foundation

// Since when a disruption holds that the status request itself doesn't date.
// transit.accessibility.cloud serves no current span with the elevator
// (`current_status_span` comes back empty), so the targeted favorites
// request knows that a lift is out of service, not since when. The spans
// themselves say it: the one running now — started, not yet ended (upstream
// gives a running span a planned end a month ahead) — began when the status
// did. Pure and unit-tested; the spans come from
// AccessibilityCloudClient.fetchLatestSpans.
//
// Only disruptions are dated ("außer Betrieb" / "unbekannt"): how long a
// lift has been working is not shown anywhere, so it is not asked for.
nonisolated enum StatusHistory {
    typealias StatusSpan = AccessibilityCloudClient.StatusSpan

    // The latest-started span decides, if it runs now and agrees with the
    // status it is quoted for: its start. A span that has ended, or one of
    // another status (the elevator moved on and upstream hasn't caught up),
    // dates nothing — never a guess. A working elevator is never dated.
    static func since(isWorking: Bool?, spans: [StatusSpan], now: Date = Date()) -> Date? {
        guard isWorking != true else { return nil }
        let latest = spans
            .filter { span in span.start.map { $0 <= now } ?? false }
            .max { ($0.start ?? .distantPast) < ($1.start ?? .distantPast) }
        guard let latest, latest.end.map({ $0 > now }) ?? true, latest.isWorking == isWorking else { return nil }
        return latest.start
    }

    // Fills `statusSince` where it is still unknown; a known value is never
    // overwritten.
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
