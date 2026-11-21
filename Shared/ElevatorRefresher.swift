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
    // Resolution against the Aufzugsstatus API for the favorites beyond the
    // VBB (namespaced ids, AufzugsstatusClient.isNationalId): one request
    // per id — the API has no batch endpoint — so only ever asked for the
    // handful of national favorites, never for a catalog. Keys = requested ids.
    var national: @Sendable (Set<String>) async -> [String: AccessibilityCloudClient.Equipment] = { _ in [:] }

    static let live = StatusSources(
        equipment: { await EquipmentCatalog.shared.equipment(for: $0) },
        national: { await AufzugsstatusClient.fetchLifts(ids: $0) }
    )

    // Splits a mixed id set by source, asks both in parallel and merges the
    // answers — the one routing step every status lookup goes through
    // (favorites refresh, a search result's detail). A source with nothing
    // to resolve is not called.
    func resolve(_ ids: Set<String>) async -> [String: AccessibilityCloudClient.Equipment] {
        let nationalIds = ids.filter(AufzugsstatusClient.isNationalId)
        let localIds = ids.subtracting(nationalIds)
        async let local = localIds.isEmpty ? [:] : equipment(localIds)
        async let beyond = nationalIds.isEmpty ? [:] : national(nationalIds)
        return await local.merging(beyond) { first, _ in first }
    }
}

// Refreshes all favorites: the VBB ones in one catalog batch against
// transit.accessibility.cloud (which ingests the operator feeds, incl. DB
// FaSta, itself — what the separate FaSta override and the brokenlifts.org
// scraping used to compensate for), the ones beyond the VBB against the
// Aufzugsstatus API, both in parallel (StatusSources.resolve). On failure an
// elevator keeps its previous values and its id is reported back. Favorites
// carry the APIs' own ids (numeric, or "source:…"); pre-migration favorites
// don't resolve here — the iOS app deletes them once with a notice
// (FavoritesStore.removeLegacyFavoritesIfNeeded).
//
// nonisolated because the targets default actor isolation to MainActor.
nonisolated enum ElevatorRefresher {
    static func refreshAll(
        _ elevators: [MonitoredElevator],
        sources: StatusSources = .live
    ) async -> (elevators: [MonitoredElevator], failedStations: Set<String>) {
        guard !elevators.isEmpty else { return ([], []) }
        let equipmentById = await sources.resolve(Set(elevators.map(\.id)))

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
