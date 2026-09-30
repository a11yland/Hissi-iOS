import AppIntents
import CoreLocation
import CoreTransferable
import Foundation
import GeoToolbox

// A favorited elevator, projected into the App Intents world so a Shortcut can
// take one as a parameter. Deliberately a projection and not a second source of
// truth: everything is read back out of FavoritesStore, the iPhone stays the
// only place favorites exist (FR4).
//
// nonisolated: AppEntity's requirements are synchronous and non-isolated, while
// the targets default actor isolation to MainActor — same reason
// MonitoredElevator and ElevatorRefresher carry the annotation.
nonisolated struct ElevatorEntity: AppEntity {
    let id: String
    let stationName: String
    let elevatorDescription: String
    // Seed-backfilled station coordinates, carried so the entity can travel as
    // a place (see the Transferable conformance below). Optional like on
    // MonitoredElevator — not every record has them.
    let latitude: Double?
    let longitude: Double?

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Aufzug")
    static let defaultQuery = ElevatorEntityQuery()

    var displayRepresentation: DisplayRepresentation {
        // Two elevators at one station carry the same name — the description
        // ("U-Bahnsteig", "Zugang …") is what tells them apart in the picker.
        var subtitle: LocalizedStringResource?
        if !elevatorDescription.isEmpty { subtitle = "\(elevatorDescription)" }
        return DisplayRepresentation(title: "\(stationName)", subtitle: subtitle)
    }

    init(_ elevator: MonitoredElevator) {
        id = elevator.id
        stationName = elevator.stationName
        elevatorDescription = elevator.elevatorDescription
        latitude = elevator.latitude
        longitude = elevator.longitude
    }
}

// The entity travels across apps as a *place* (FR20a): a Shortcut can chain
// "⟨Aufzug⟩ prüfen" into any action that takes a location — directions to the
// station, a message with the place attached. Export-only; nothing imports an
// elevator from a place, the favorites stay iPhone-managed (FR4).
@available(iOS 26.4, *)
extension ElevatorEntity: Transferable {
    nonisolated static var transferRepresentation: some TransferRepresentation {
        ValueRepresentation(exporting: { (entity: Self) -> PlaceDescriptor in
            guard let latitude = entity.latitude, let longitude = entity.longitude else {
                // No coordinates (offline-only seed record): no place, rather
                // than a wrong one — the receiving action simply gets nothing.
                throw ElevatorPlaceError.noCoordinates
            }
            return PlaceDescriptor(
                representations: [.coordinate(
                    CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
                )],
                commonName: entity.stationName
            )
        })
    }
}

private nonisolated enum ElevatorPlaceError: Error {
    case noCoordinates
}

nonisolated struct ElevatorEntityQuery: EntityQuery {
    func entities(for identifiers: [ElevatorEntity.ID]) async throws -> [ElevatorEntity] {
        let wanted = Set(identifiers)
        return await favorites()
            .filter { wanted.contains($0.id) }
            .map(ElevatorEntity.init)
    }

    // Not optional in practice: this is the list the system enumerates to build
    // one parameterized App Shortcut per favorite. Without it the phrase
    // "⟨Aufzug⟩ in Hissi prüfen" produces no shortcuts at all.
    func suggestedEntities() async throws -> [ElevatorEntity] {
        await favorites().map(ElevatorEntity.init)
    }

    // FavoritesStore is MainActor-isolated (project default); hop once here
    // instead of sprinkling awaits through the query.
    private func favorites() async -> [MonitoredElevator] {
        await MainActor.run { FavoritesStore.load() }
    }
}
