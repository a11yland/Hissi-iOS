import Foundation

// Folds a live catalog record into a favorite, pure and unit-tested. Since
// the transit.accessibility.cloud migration there is only one source — the
// platform ingests the operator feeds (incl. DB FaSta) itself, so the old
// cross-source policy (FaSta status override, brokenlifts page mapping) is
// gone.
nonisolated enum StatusMerge {
    static func apply(_ equipment: AccessibilityCloudClient.Equipment, to elevator: MonitoredElevator) -> MonitoredElevator {
        var updated = elevator
        // A seed-id favorite resolved through the inventory-number bridge
        // (EquipmentCatalog.bridgedLiveIds) comes back as its live record —
        // adopt the live identity so the favorite matches search results and
        // refreshes by its numeric id from now on. The app persists the
        // migration (FavoritesStore.migrateIds).
        if equipment.id != elevator.id, ElevatorSource(id: equipment.id).isLive {
            updated = MonitoredElevator(
                id: equipment.id,
                stationId: equipment.stationId.isEmpty ? elevator.stationId : equipment.stationId,
                elevatorId: equipment.id,
                elevatorIndex: elevator.elevatorIndex,
                stationName: elevator.stationName,
                elevatorDescription: elevator.elevatorDescription,
                isWorking: elevator.isWorking,
                lastChecked: elevator.lastChecked,
                lastUpdated: elevator.lastUpdated,
                statusSince: elevator.statusSince,
                sourceName: elevator.sourceName,
                organizationName: elevator.organizationName,
                stateExplanation: elevator.stateExplanation,
                latitude: elevator.latitude,
                longitude: elevator.longitude,
                fastaEquipmentNumber: elevator.fastaEquipmentNumber,
                // The favorite's position in the list must survive the
                // identity change — the bridge swaps the id, not the entry.
                addedAt: elevator.addedAt
            )
        }
        if !equipment.stationName.isEmpty { updated.stationName = equipment.stationName }
        if !equipment.description.isEmpty { updated.elevatorDescription = equipment.description }
        // "Seit": a record that names the transition wins. One that doesn't
        // (the catalog cache carries no span history) says nothing about it —
        // while the status is unchanged the favorite keeps what it knows,
        // a changed status drops it rather than dating the new status with
        // the old one's start.
        updated.statusSince = equipment.statusSince
            ?? (equipment.isWorking == elevator.isWorking ? elevator.statusSince : nil)
        updated.isWorking = equipment.isWorking
        updated.lastChecked = Date()
        updated.lastUpdated = equipment.lastUpdate
        updated.stateExplanation = equipment.stateExplanation
        // Source, operator and coordinates are not served by the API — they
        // reach a record only through the seed overlay (EquipmentCatalog).
        // A refresh whose record carries none of them therefore says nothing
        // about them, and must not erase what the favorite already knows;
        // the status fields above are the opposite case (a cleared
        // disruption has to clear its reason). Coordinates move as a pair.
        if !equipment.sourceName.isEmpty { updated.sourceName = equipment.sourceName }
        if !equipment.organizationName.isEmpty { updated.organizationName = equipment.organizationName }
        if let latitude = equipment.latitude, let longitude = equipment.longitude {
            updated.latitude = latitude
            updated.longitude = longitude
        }
        // Keeps the seed bridge fresh; absent on gap-station records, where
        // the number the favorite was created with survives.
        if let number = equipment.fastaEquipmentNumber {
            updated.fastaEquipmentNumber = number
        }
        return updated
    }
}
