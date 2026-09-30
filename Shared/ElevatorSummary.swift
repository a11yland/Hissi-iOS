import Foundation

// The single aggregate verdict every glanceable surface gives (FR13): "is my
// route okay?", reduced from all favorites before anything is rendered. Lock
// Screen widgets, StandBy, the watch complications and the watch Smart Stack
// share this vocabulary, so the same situation reads the same everywhere.
//
// Pure and platform-free (no WidgetKit, no SwiftUI) so it stays unit-testable;
// colours and layout stay target-local. Status is carried by the symbol's
// *shape* and by words, never by colour alone — Lock Screen widgets and tinted
// watch faces flatten colour to a single tint.
//
// nonisolated: a pure value type built from nonisolated contexts (timeline
// providers), while the targets default to MainActor isolation.
nonisolated struct ElevatorSummary: Equatable {
    // Precedence order: broken outranks unknown outranks all-clear, and "no
    // favorites" is its own case — with nothing to monitor, "Alle in Betrieb"
    // would be a false all-clear.
    //
    // String-backed and Codable because the Live Activity's ContentState
    // carries the verdict across process boundaries (LiveStatusState); the
    // raw values are that payload's wire format and must stay stable.
    enum Verdict: String, Codable, Equatable {
        case noFavorites
        case broken
        case unknown
        case allWorking
        // The watch before the first favorites sync has ever landed: an empty
        // mirror means "membership unknown", not "no favorites" — the phone
        // may well have some. Only the watch constructs this (memberwise
        // init); it can never fall out of an elevator list.
        case awaitingSync
    }

    let verdict: Verdict
    let brokenCount: Int
    let unknownCount: Int
    let total: Int
    // Stations behind a non-clear verdict, broken before unknown and
    // deduplicated in input order — the rectangular families have room for a
    // name, the circular ones don't.
    let affectedStations: [String]

    init(_ elevators: [MonitoredElevator]) {
        let broken = elevators.filter { $0.isWorking == false }
        let unknown = elevators.filter { $0.isWorking == nil }
        total = elevators.count
        brokenCount = broken.count
        unknownCount = unknown.count
        if elevators.isEmpty {
            verdict = .noFavorites
        } else if !broken.isEmpty {
            verdict = .broken
        } else if !unknown.isEmpty {
            verdict = .unknown
        } else {
            verdict = .allWorking
        }

        var seen = Set<String>()
        affectedStations = (broken + unknown)
            .map(\.stationName)
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    // Rebuilt from an already-derived verdict instead of from the elevators —
    // the Live Activity's ContentState carries the counts, not the records
    // (LiveStatusState.summary), and still has to speak this vocabulary.
    init(
        verdict: Verdict,
        brokenCount: Int,
        unknownCount: Int,
        total: Int,
        affectedStations: [String]
    ) {
        self.verdict = verdict
        self.brokenCount = brokenCount
        self.unknownCount = unknownCount
        self.total = total
        self.affectedStations = affectedStations
    }

    var symbolName: String {
        switch verdict {
        case .noFavorites: "star"
        case .broken:      ElevatorStatus.broken.symbolName
        case .unknown,
             .awaitingSync: ElevatorStatus.unknown.symbolName
        case .allWorking:  ElevatorStatus.working.symbolName
        }
    }

    // Full sentence — rectangular families and VoiceOver.
    var label: String {
        switch verdict {
        case .noFavorites:  String(localized: "Keine Favoriten")
        case .broken:       String(localized: "\(brokenCount) außer Betrieb")
        case .unknown:      String(localized: "\(unknownCount) unbekannt")
        case .allWorking:   String(localized: "Alle in Betrieb")
        case .awaitingSync: String(localized: "Status unbekannt")
        }
    }

    // Compact form for the space-constrained families (circular, inline, corner).
    var shortLabel: String {
        switch verdict {
        case .noFavorites: String(localized: "Keine Favoriten")
        case .broken:      String(localized: "\(brokenCount) defekt")
        case .unknown,
             .awaitingSync: "?"
        case .allWorking:  "OK"
        }
    }

    // The narrowest form: the iOS 27 landscape Dynamic Island shows the
    // compact view without room to grow in width, so the verdict shrinks to a
    // count or two characters — the compact-leading symbol carries the rest.
    var minimalLabel: String {
        switch verdict {
        case .noFavorites:  "–"
        case .broken:       "\(brokenCount)"
        case .unknown,
             .awaitingSync: "?"
        case .allWorking:   "OK"
        }
    }

    // Surfaces that are otherwise anonymous — accessoryInline sits bare on the
    // Lock Screen / watch face, accessoryCircular spends its space on the
    // status shape — have to carry the app name themselves (FR16).
    var identifiedLabel: String { String(localized: "Hissi: \(label)") }
    var identifiedShortLabel: String { String(localized: "Hissi: \(shortLabel)") }

    // What VoiceOver says on the watch face, where nothing around a
    // complication names the app and the system doesn't either: the sentence
    // names the subject ("Lifte") instead of the brand, so it stands on its
    // own without a "Hissi:" prefix.
    var spokenLabel: String {
        switch verdict {
        case .noFavorites:
            String(localized: "Keine Lift-Favoriten")
        case .broken:
            brokenCount == 1
                ? String(localized: "1 Lift außer Betrieb")
                : String(localized: "\(brokenCount) Lifte außer Betrieb")
        case .unknown:
            unknownCount == 1
                ? String(localized: "1 Lift unbekannt")
                : String(localized: "\(unknownCount) Lifte unbekannt")
        case .allWorking:
            String(localized: "Alle Lifte in Betrieb")
        case .awaitingSync:
            String(localized: "Lift-Status unbekannt")
        }
    }

    // The one extra line the rectangular families (Lock Screen, Smart Stack)
    // have room for: which station is actually affected.
    var detailLine: String? { affectedStations.first }

    // How much of the route is affected, for a gauge in the verdict's colour:
    // an all-clear fills the whole arc (green), otherwise the arc is the share
    // of broken and unknown elevators — one of three broken is a third of red,
    // one of one the full arc. Nothing to monitor draws nothing.
    var affectedShare: Double {
        switch verdict {
        case .allWorking:                 1
        case .broken, .unknown:           total > 0 ? Double(brokenCount + unknownCount) / Double(total) : 0
        case .noFavorites, .awaitingSync: 0
        }
    }

    // Ranking inside a widget stack / the watch Smart Stack. A broken elevator
    // is the whole point of the app and should surface on its own; unknown is
    // worth a nudge; an all-clear stays at baseline so it never crowds the
    // stack out of surfaces the user picked for something else.
    var relevanceScore: Float {
        switch verdict {
        case .broken:       100
        case .unknown:      25
        case .allWorking,
             .noFavorites,
             .awaitingSync: 0
        }
    }
}
