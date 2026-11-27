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
    // When the current status began ("seit …") — a real transition time or
    // nil, never a guess (AccessibilityCloudClient.statusSince, in `join`).
    // Shown for disruptions only (shownStatusSince).
    var statusSince: Date?
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
        statusSince: Date? = nil,
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
        self.statusSince = statusSince
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
        statusSince = try c.decodeIfPresent(Date.self, forKey: .statusSince)
        sourceName = try c.decodeIfPresent(String.self, forKey: .sourceName) ?? ""
        organizationName = try c.decodeIfPresent(String.self, forKey: .organizationName) ?? ""
        stateExplanation = try c.decodeIfPresent(String.self, forKey: .stateExplanation)
        latitude = try c.decodeIfPresent(Double.self, forKey: .latitude)
        longitude = try c.decodeIfPresent(Double.self, forKey: .longitude)
        fastaEquipmentNumber = try c.decodeIfPresent(Int.self, forKey: .fastaEquipmentNumber)
        addedAt = try c.decodeIfPresent(Date.self, forKey: .addedAt)
    }

    // An age in the coarsest unit that still says something. Times are
    // always shown relative — never as a date: days for two weeks, then
    // weeks, months and years. Pure; `relativeTime` and `sinceLabel` word it.
    enum Age: Equatable {
        case minutes(Int), hours(Int), days(Int), weeks(Int), months(Int), years(Int)

        init(minutes: Int) {
            let days = minutes / 1440
            switch minutes {
            case ..<60:                self = .minutes(minutes)
            case ..<1440:              self = .hours(minutes / 60)
            case ..<(14 * 1440):       self = .days(days)
            case ..<(60 * 1440):       self = .weeks(days / 7)
            case ..<(730 * 1440):      self = .months(days / 30)
            default:                   self = .years(days / 365)
            }
        }
    }

    // Localized relative time, e.g. "gerade eben" / "vor 3 Min." / "vor 2 Std."
    // / "vor 3 Tagen" / "vor 5 Wochen" / "vor 4 Monaten" / "vor 2 Jahren".
    // `spoken` writes the short units out for VoiceOver ("vor 8 Stunden").
    // nonisolated: pure formatting, referenced from nonisolated contexts
    // (the project defaults to MainActor isolation).
    nonisolated static func relativeTime(since date: Date, now: Date = Date(), spoken: Bool = false) -> String {
        let minutes = Int(now.timeIntervalSince(date) / 60)
        guard minutes >= 1 else { return String(localized: "gerade eben") }
        switch Age(minutes: minutes) {
        case .minutes(let count):
            if spoken {
                return count == 1 ? String(localized: "vor 1 Minute") : String(localized: "vor \(count) Minuten")
            }
            return String(localized: "vor \(count) Min.")
        case .hours(let count):
            if spoken {
                return count == 1 ? String(localized: "vor 1 Stunde") : String(localized: "vor \(count) Stunden")
            }
            return String(localized: "vor \(count) Std.")
        case .days(let count):
            return count == 1 ? String(localized: "vor 1 Tag") : String(localized: "vor \(count) Tagen")
        case .weeks(let count):   return String(localized: "vor \(count) Wochen")
        case .months(let count):  return String(localized: "vor \(count) Monaten")
        case .years(let count):   return String(localized: "vor \(count) Jahren")
        }
    }

    // How long a status has held: "seit 5 Min." / "seit 3 Std." / "seit 1
    // Tag" / "seit 3 Tagen" / "seit 5 Wochen" / "seit 4 Monaten" / "seit 2
    // Jahren" — the same wording in the row, the detail, the widget and the
    // Live Activity, always relative. `spoken` writes the short units out
    // for VoiceOver. `now` is explicit so widgets format against their entry
    // date and tests stay deterministic.
    nonisolated static func sinceLabel(_ date: Date, now: Date = Date(), spoken: Bool = false) -> String {
        // Under a minute — or a start slightly ahead of this device's clock —
        // counts as one minute: "seit 0 Min." says nothing.
        switch Age(minutes: max(1, Int(now.timeIntervalSince(date) / 60))) {
        case .minutes(let count):
            if spoken {
                return count == 1 ? String(localized: "seit 1 Minute") : String(localized: "seit \(count) Minuten")
            }
            return String(localized: "seit \(count) Min.")
        case .hours(let count):
            if spoken {
                return count == 1 ? String(localized: "seit 1 Stunde") : String(localized: "seit \(count) Stunden")
            }
            return String(localized: "seit \(count) Std.")
        case .days(let count):
            return count == 1 ? String(localized: "seit 1 Tag") : String(localized: "seit \(count) Tagen")
        case .weeks(let count):  return String(localized: "seit \(count) Wochen")
        case .months(let count): return String(localized: "seit \(count) Monaten")
        case .years(let count):  return String(localized: "seit \(count) Jahren")
        }
    }

    // Since when the current status holds, as far as it is shown: only for
    // a status that is not "in Betrieb". How long an outage has lasted is
    // what matters; a working lift needs no duration. nil also while the
    // source doesn't say when the status began.
    var shownStatusSince: Date? { isWorking == true ? nil : statusSince }

    // The row's "seit …" line; nil when there is nothing to show — the line
    // is then left out.
    func statusSinceLabel(now: Date = Date(), spoken: Bool = false) -> String? {
        shownStatusSince.map { Self.sinceLabel($0, now: now, spoken: spoken) }
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
