import Foundation

// Which system an elevator id belongs to. Ids are opaque strings everywhere
// (favorites, iCloud copy, export file); their shape names the source:
// numeric = transit.accessibility.cloud, "vrr:<resourceId>" = the VRR
// infrastructure API (opendata-oepnv.de), anything else = an id scheme from
// before the transit.accessibility.cloud migration (Mongo _id, "fasta-…",
// "brokenlifts-…"). Replaces the former "non-numeric means legacy" checks.
// Pure, unit-tested.
nonisolated enum ElevatorSource: Equatable, Sendable {
    case accessibilityCloud, vrr, legacy

    static let vrrPrefix = "vrr:"

    init(id: String) {
        if id.hasPrefix(Self.vrrPrefix), id.count > Self.vrrPrefix.count {
            self = .vrr
        } else if Int(id) != nil {
            self = .accessibilityCloud
        } else {
            self = .legacy
        }
    }

    // "de:05112:16580:31" → "vrr:de:05112:16580:31".
    static func vrrId(resourceId: String) -> String { vrrPrefix + resourceId }

    // An id a status source answers for — as opposed to a legacy id, which
    // only resolves through the seed's `legacyIds` bridge, if at all.
    var isLive: Bool { self != .legacy }
}
