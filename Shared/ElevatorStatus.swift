import Foundation

// Presentation-agnostic status vocabulary shared across all targets so the same
// SF Symbol and wording represent a status everywhere. Colours stay target-local
// (the app and the watch use different palettes).
//
// The symbol differs by *shape*, not only colour — this is what makes the status
// legible for colour-blind users and in monochrome contexts. The shapes follow
// the app icon's system: circle with a check for working, square for unknown,
// a cross for broken.
// nonisolated: pure value semantics, referenced from nonisolated contexts
// (ElevatorSummary, the intents' perform()) while the targets default actor
// isolation to MainActor — same reason MonitoredElevator carries it.
nonisolated enum ElevatorStatus: Equatable {
    case working, broken, unknown

    init(isWorking: Bool?) {
        switch isWorking {
        case .some(true):  self = .working
        case .some(false): self = .broken
        case .none:        self = .unknown
        }
    }

    var symbolName: String {
        switch self {
        case .working: "checkmark.circle.fill"
        case .broken:  "xmark"
        case .unknown: "questionmark.square.fill"
        }
    }

    // Full sentence, used for on-screen text and VoiceOver. German literals
    // double as the localization keys (catalog in Shared/Localizable.xcstrings).
    var label: String {
        switch self {
        case .working: String(localized: "In Betrieb")
        case .broken:  String(localized: "Außer Betrieb")
        case .unknown: String(localized: "Status unbekannt")
        }
    }

    // Compact form for space-constrained surfaces (widgets, complications).
    var shortLabel: String {
        switch self {
        case .working: "OK"
        case .broken:  String(localized: "Defekt")
        case .unknown: "?"
        }
    }
}
