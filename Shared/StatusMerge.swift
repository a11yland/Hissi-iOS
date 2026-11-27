import Foundation

// Folds a live catalog record into a favorite, pure and unit-tested. Since
// the transit.accessibility.cloud migration there is only one source — the
// platform ingests the operator feeds (incl. DB FaSta) itself, so the old
// cross-source policy (FaSta status override, brokenlifts page mapping) is
// gone.
nonisolated enum StatusMerge {
    // `replacingMetadata`: the record comes with the bundled seed overlaid,
    // so its source and operator names are complete — an empty one means
    // "none", and replaces a name the favorite still carries from an older
    // seed. Without the seed (watch widget extension) an empty name says
    // nothing and the favorite keeps what it knows.
    static func apply(
        _ equipment: AccessibilityCloudClient.Equipment,
        to elevator: MonitoredElevator,
        replacingMetadata: Bool = SeedCatalog.isBundled
    ) -> MonitoredElevator {
        var updated = elevator
        // A seed-id favorite resolved through the inventory-number bridge
        // (EquipmentCatalog.bridgedLiveIds) comes back as its live record —
        // adopt the live identity so the favorite matches search results and
        // refreshes by its numeric id from now on. The app persists the
        // migration (FavoritesStore.migrateIds).
        if equipment.id != elevator.id, Int(equipment.id) != nil {
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
        // "Seit" is status like the rest: every path dates a disruption
        // from the span running now, so a record without a date means
        // there is none — it must not keep an old one alive.
        updated.statusSince = equipment.statusSince
        updated.isWorking = equipment.isWorking
        updated.lastChecked = Date()
        updated.lastUpdated = equipment.lastUpdate
        updated.stateExplanation = equipment.stateExplanation
        // Source, operator and coordinates are not served by the API — they
        // reach a record only through the seed overlay (EquipmentCatalog).
        // With the seed overlaid (`replacingMetadata`) the names are
        // complete and replace the favorite's; without it, a record that
        // carries none says nothing about them and must not erase what the
        // favorite already knows. The status fields above are the opposite
        // case (a cleared disruption has to clear its reason). Coordinates
        // are only ever filled in, and move as a pair.
        if replacingMetadata || !equipment.sourceName.isEmpty { updated.sourceName = equipment.sourceName }
        if replacingMetadata || !equipment.organizationName.isEmpty {
            updated.organizationName = equipment.organizationName
        }
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
