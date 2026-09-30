import CoreLocation
import Foundation

// nonisolated: a pure value type constructed from nonisolated contexts
// (SearchGrouping, ElevatorRefresher) — the targets default to MainActor
// isolation, which would otherwise bind the initializer to the main actor.
nonisolated struct MonitoredElevator: Identifiable, Codable, Equatable {
    let id: String
    let stationId: String
    let elevatorId: String
    // Position of this elevator within its station page (lift order). Needed
    // because /station/{id}/{elevatorId} returns all elevators, not just one.
    var elevatorIndex: Int
    var stationName: String
    var elevatorDescription: String
    var isWorking: Bool?
    // When the app last fetched this elevator (our poll time).
    var lastChecked: Date?
    // When the status was last updated at the source (accessibility.cloud's
    // `lastUpdate`). Distinct from lastChecked: a fresh poll can still return
    // stale source data.
    var lastUpdated: Date?
    // accessibility.cloud source/organization for this record, e.g.
    // "BVG Elevators (2025)" / "BVG Berliner Verkehrsbetriebe AöR".
    var sourceName: String = ""
    var organizationName: String = ""
    // Human-readable disruption reason from the source's
    // lastDisruptionProperties.stateExplanation, e.g. "Außer Betrieb". Nil when
    // no disruption is on record.
    var stateExplanation: String?
    // Station coordinates from the source's GeoJSON geometry, for the map
    // snippet in the detail views. Nil when the source carried none.
    var latitude: Double?
    var longitude: Double?
    // DB FaSta equipment number (from the seed catalog) — enables live status
    // fetches from FaSta for elevators whose accessibility.cloud record is
    // stale or missing.
    var fastaEquipmentNumber: Int?
    // When the user favorited this elevator — the key of the default
    // "zuletzt hinzugefügt" order (FavoritesOrdering). Optional because
    // favorites stored before manual sorting existed carry no timestamp;
    // FavoritesStore backfills them once from their stored (append) order.
    var addedAt: Date?

    init(
        id: String,
        stationId: String,
        elevatorId: String,
        elevatorIndex: Int = 0,
        stationName: String,
        elevatorDescription: String,
        isWorking: Bool?,
        lastChecked: Date?,
        lastUpdated: Date? = nil,
        sourceName: String = "",
        organizationName: String = "",
        stateExplanation: String? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        fastaEquipmentNumber: Int? = nil,
        addedAt: Date? = nil
    ) {
        self.id = id
        self.stationId = stationId
        self.elevatorId = elevatorId
        self.elevatorIndex = elevatorIndex
        self.stationName = stationName
        self.elevatorDescription = elevatorDescription
        self.isWorking = isWorking
        self.lastChecked = lastChecked
        self.lastUpdated = lastUpdated
        self.sourceName = sourceName
        self.organizationName = organizationName
        self.stateExplanation = stateExplanation
        self.latitude = latitude
        self.longitude = longitude
        self.fastaEquipmentNumber = fastaEquipmentNumber
        self.addedAt = addedAt
    }

    // Tolerate caches written before elevatorIndex/addedAt existed
    // (elevatorIndex defaults to 0, addedAt stays nil).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        stationId = try c.decode(String.self, forKey: .stationId)
        elevatorId = try c.decode(String.self, forKey: .elevatorId)
        elevatorIndex = try c.decodeIfPresent(Int.self, forKey: .elevatorIndex) ?? 0
        stationName = try c.decode(String.self, forKey: .stationName)
        elevatorDescription = try c.decode(String.self, forKey: .elevatorDescription)
        isWorking = try c.decodeIfPresent(Bool.self, forKey: .isWorking)
        lastChecked = try c.decodeIfPresent(Date.self, forKey: .lastChecked)
        lastUpdated = try c.decodeIfPresent(Date.self, forKey: .lastUpdated)
        sourceName = try c.decodeIfPresent(String.self, forKey: .sourceName) ?? ""
        organizationName = try c.decodeIfPresent(String.self, forKey: .organizationName) ?? ""
        stateExplanation = try c.decodeIfPresent(String.self, forKey: .stateExplanation)
        latitude = try c.decodeIfPresent(Double.self, forKey: .latitude)
        longitude = try c.decodeIfPresent(Double.self, forKey: .longitude)
        fastaEquipmentNumber = try c.decodeIfPresent(Int.self, forKey: .fastaEquipmentNumber)
        addedAt = try c.decodeIfPresent(Date.self, forKey: .addedAt)
    }

    // Localized relative time, e.g. "gerade eben" / "vor 3 Min." / "vor 2 Std."
    // / "vor 3 Tagen"; beyond a week an absolute date ("am 12.12.2024") — some
    // sources (VBB S-Bahn) go stale for months and huge relative values are
    // meaningless. nonisolated: pure formatting, referenced from nonisolated
    // contexts (the project defaults to MainActor isolation).
    nonisolated static func relativeTime(since date: Date) -> String {
        let minutes = Int(-date.timeIntervalSinceNow / 60)
        switch minutes {
        case ..<1:            return String(localized: "gerade eben")
        case 1..<60:          return String(localized: "vor \(minutes) Min.")
        case 60..<1440:       return String(localized: "vor \(minutes / 60) Std.")
        case 1440..<(7*1440):
            let days = minutes / 1440
            return days == 1
                ? String(localized: "vor 1 Tag")
                : String(localized: "vor \(days) Tagen")
        default:
            return String(localized: "am \(date.formatted(Date.FormatStyle(date: .numeric)))")
        }
    }

    // Individual records can silently decouple from their disruption feed
    // (observed with VBB S-Bahn: frozen since 2024 while sibling records
    // update). Beyond this age the status is flagged as possibly outdated —
    // a warning, not a downgrade to unknown, since an old lastUpdate can
    // also just mean a long disruption-free stretch.
    nonisolated static let staleAfterDays = 14

    var isDataStale: Bool {
        guard let lastUpdated else { return false }
        return -lastUpdated.timeIntervalSinceNow > Double(Self.staleAfterDays) * 86_400
    }

    // Poll time — "when did we last check". Self-contained for standalone use.
    var lastCheckedLabel: String {
        guard let date = lastChecked else { return String(localized: "Noch nie geprüft") }
        return String(localized: "Geprüft \(Self.relativeTime(since: date))")
    }

    // Source freshness — "how old is the status at the source".
    var lastUpdatedLabel: String {
        guard let date = lastUpdated else { return String(localized: "Stand unbekannt") }
        return String(localized: "Stand \(Self.relativeTime(since: date))")
    }

    var coordinate: CLLocationCoordinate2D? {
        guard let latitude, let longitude else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}
