import AppIntents
import Foundation

// The three intents behind the App Shortcuts. They live in the app target only
// (not Shared/, which is synchronized into all four targets) because the
// Shortcuts app, Siri and Spotlight read them from the app.
//
// nonisolated throughout: AppIntent's static requirements are synchronous and
// non-isolated, while the targets default actor isolation to MainActor.

nonisolated enum IntentRefresh {
    // One targeted request answers every favorite at once
    // (ElevatorRefresher.refreshAll), so both status intents refresh the whole
    // set and then report on whatever they were asked about — same cost as
    // fetching one, and the cache stays coherent for the widget and the watch.
    static func refreshedFavorites() async -> [MonitoredElevator] {
        let favorites = await RefreshFanOut.cachedFavorites()
        guard !favorites.isEmpty else { return [] }
        let (updated, _) = await ElevatorRefresher.refreshAll(favorites)
        // A Shortcut run is a refresh like any other — the widgets, the watch
        // and a running live status all learn what it just fetched.
        await RefreshFanOut.distribute(updated, previous: favorites)
        return updated
    }
}

// MARK: - "Aufzugstatus prüfen"

// The hero shortcut: the same aggregate verdict every glanceable surface gives
// (ElevatorSummary), spoken instead of drawn. Runs without opening the app.
nonisolated struct CheckElevatorsIntent: AppIntent, PredictableIntent {
    static let title: LocalizedStringResource = "Aufzugstatus prüfen"
    static let description = IntentDescription(
        "Prüft alle favorisierten Aufzüge und meldet, ob einer außer Betrieb ist."
    )
    static let openAppWhenRun = false

    // How the action reads where the system proposes it (Siri Suggestions,
    // Spotlight) — without this it shows up as a bare intent name. No
    // parameters, so there is nothing to fill in.
    static var predictionConfiguration: some IntentPredictionConfiguration {
        IntentPrediction {
            DisplayRepresentation(title: "Aufzugstatus prüfen")
        }
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let elevators = await IntentRefresh.refreshedFavorites()
        let summary = ElevatorSummary(elevators)
        // summary.label covers the empty case as "Keine Favoriten" — with
        // nothing to monitor, "Alle in Betrieb" would be a false all-clear.
        return .result(dialog: IntentDialog(stringLiteral: summary.label))
    }
}

// MARK: - "⟨Aufzug⟩ prüfen"

// The parameterized shortcut. The system builds one phrase per favorite from
// ElevatorEntityQuery.suggestedEntities(), which is why the favorites have to
// be re-published whenever they change (see HissiShortcuts).
// Unlike its two siblings this one is *not* a `nonisolated struct`: @Parameter
// is a mutable stored property, and nonisolated cannot be applied to those
// (an error in the Swift 6 language mode). Only the static requirements need
// to be nonisolated, so they carry the annotation individually.
struct CheckElevatorIntent: AppIntent, PredictableIntent {
    nonisolated static let title: LocalizedStringResource = "Aufzug prüfen"
    nonisolated static let description = IntentDescription(
        "Prüft einen einzelnen favorisierten Aufzug."
    )
    nonisolated static let openAppWhenRun = false

    @Parameter(title: "Aufzug")
    var elevator: ElevatorEntity

    // Naming the station is the whole point here: "S+U Pankow prüfen" is a
    // proposal someone can act on, "Aufzug prüfen" is not.
    nonisolated static var predictionConfiguration: some IntentPredictionConfiguration {
        IntentPrediction(parameters: (\Self.$elevator)) { elevator in
            DisplayRepresentation(title: "\(elevator.stationName) prüfen")
        }
    }

    // Also returns the entity, so a Shortcut can chain the checked elevator
    // into a next action — on iOS 26.4+ it travels as a place (the
    // Transferable conformance on ElevatorEntity), e.g. into directions.
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<ElevatorEntity> {
        let refreshed = await IntentRefresh.refreshedFavorites()
        // The phrase list can outlive the favorite it names — the system keeps
        // known entities around until the next update. Say so instead of
        // inventing a status.
        guard let match = refreshed.first(where: { $0.id == elevator.id }) else {
            return .result(value: elevator, dialog: IntentDialog(
                stringLiteral: String(localized: "Dieser Aufzug ist kein Favorit mehr.")
            ))
        }
        let place = [match.stationName,
                     match.elevatorDescription.isEmpty ? nil : match.elevatorDescription]
            .compactMap { $0 }
            .joined(separator: ", ")
        let status = ElevatorStatus(isWorking: match.isWorking).label
        return .result(
            value: ElevatorEntity(match),
            dialog: IntentDialog(stringLiteral: String(localized: "\(place): \(status)"))
        )
    }
}

// MARK: - "Favoriten öffnen"

// Little use on its own — its point is automations ("wenn ich am Bahnhof
// ankomme …"). ContentView opens on the favorites area, so there is nothing to
// navigate to.
nonisolated struct OpenFavoritesIntent: AppIntent, PredictableIntent {
    static let title: LocalizedStringResource = "Favoriten öffnen"
    static let description = IntentDescription("Öffnet Hissi bei den Favoriten.")
    static let openAppWhenRun = true

    static var predictionConfiguration: some IntentPredictionConfiguration {
        IntentPrediction {
            DisplayRepresentation(title: "Favoriten öffnen")
        }
    }

    func perform() async throws -> some IntentResult {
        .result()
    }
}
