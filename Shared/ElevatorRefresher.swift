import Foundation

// Driven port for the refresh orchestration: the status source as an
// injectable closure. `.live` wires up the real catalog; tests substitute a
// stub, which is what makes the logic below unit-testable at all.
nonisolated struct StatusSources: Sendable {
    // Batch resolution against transit.accessibility.cloud: one targeted
    // request (or a still-fresh catalog cache) answers all favorites at once
    // (EquipmentCatalog.equipment(for:)) — never one request per favorite,
    // never a full catalog build. Keys of the result = the requested ids.
    var equipment: @Sendable (Set<String>) async -> [String: AccessibilityCloudClient.Equipment]
    // The latest status spans of the given elevators (closed ones included),
    // for the "seit" of elevators no current span dates. Nil result =
    // failure; a nil closure = this surface doesn't ask (`statusOnly`).
    var latestSpans: (@Sendable (Set<String>) async -> [AccessibilityCloudClient.StatusSpan]?)?

    static let live = StatusSources(
        equipment: { await EquipmentCatalog.shared.equipment(for: $0) },
        latestSpans: { await AccessibilityCloudClient.fetchLatestSpans(elevatorIds: $0) }
    )

    // Status without the span history: the widget extensions and the watch,
    // which show a duration only for elevators that are not working — those
    // carry their span's start anyway — and read what the app cached.
    static let statusOnly = StatusSources(
        equipment: { await EquipmentCatalog.shared.equipment(for: $0) }
    )
}

// Refreshes all favorites in one catalog batch. transit.accessibility.cloud
// is the only status source — it ingests the operator feeds (incl. DB FaSta)
// itself, which is what the separate FaSta override and the brokenlifts.org
// scraping used to compensate for. On failure an elevator keeps its previous
// values and its id is reported back. Favorites carry the API's numeric ids;
// pre-migration favorites don't resolve here — the iOS app deletes them once
// with a notice (FavoritesStore.removeLegacyFavoritesIfNeeded).
//
// nonisolated because the targets default actor isolation to MainActor.
nonisolated enum ElevatorRefresher {
    static func refreshAll(
        _ elevators: [MonitoredElevator],
        sources: StatusSources = .live
    ) async -> (elevators: [MonitoredElevator], failedStations: Set<String>) {
        guard !elevators.isEmpty else { return ([], []) }
        let equipmentById = await sources.equipment(Set(elevators.map(\.id)))

        var failed = Set<String>()
        let updated = elevators.map { elevator -> MonitoredElevator in
            guard let equipment = equipmentById[elevator.id] else {
                failed.insert(elevator.id)
                return elevator
            }
            return StatusMerge.apply(equipment, to: elevator)
        }
        return (await withHistory(updated, skipping: failed, sources: sources), failed)
    }

    // Dates the statuses that are still undated ("seit") from the span
    // history: at most one extra request, and only when something lacks the
    // date — a favorite whose status didn't change keeps the one it has
    // (StatusMerge), so the steady state asks nothing. A failed request
    // changes nothing.
    static func withHistory(
        _ elevators: [MonitoredElevator],
        skipping skipped: Set<String> = [],
        sources: StatusSources = .live,
        now: Date = Date()
    ) async -> [MonitoredElevator] {
        guard let latestSpans = sources.latestSpans else { return elevators }
        let undated = Set(
            elevators.filter { $0.statusSince == nil && !skipped.contains($0.id) }.map(\.id)
        )
        guard !undated.isEmpty, let spans = await latestSpans(undated) else { return elevators }
        return StatusHistory.applied(to: elevators, spans: spans, now: now)
    }
}
