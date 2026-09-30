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

    static let live = StatusSources(
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
        return (updated, failed)
    }
}
