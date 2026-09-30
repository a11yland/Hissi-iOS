import Foundation

// Region and network classification behind the grouped search results. Pure
// string classifiers, nonisolated (the targets default to MainActor
// isolation); unit-tested in HissiCore.

// Berlin vs Brandenburg. accessibility.cloud's originalPlaceInfoId carries the
// AGS ("de:11000:…" = Berlin, "de:12xxx:…" = a Brandenburg district); records
// without one (BVG puts the station name there) fall back to the seed's
// region, then to the name heuristic.
nonisolated enum TransitRegion: String, Codable, CaseIterable {
    case berlin, brandenburg

    var label: String {
        switch self {
        case .berlin:      "Berlin"
        case .brandenburg: "Brandenburg"
        }
    }

    static func from(originalPlaceInfoId id: String?) -> TransitRegion? {
        guard let id else { return nil }
        if id.hasPrefix("de:11") { return .berlin }
        if id.hasPrefix("de:12") { return .brandenburg }
        return nil
    }

    // U-Bahn exists only in Berlin; VBB suffixes Berlin stations with
    // "(Berlin)", DB prefixes them with "Berlin".
    static func inferred(from stationName: String) -> TransitRegion {
        let name = stationName.trimmingCharacters(in: .whitespaces)
        if name.contains("(Berlin)") || name.hasPrefix("Berlin")
            || name.hasPrefix("U ") || name.hasPrefix("S+U") {
            return .berlin
        }
        return .brandenburg
    }
}

// Which network an individual elevator serves. Declared in display order —
// the raw value doubles as the sort key for the subgroups within a station.
nonisolated enum TransitNetwork: Int, Codable, CaseIterable, Comparable {
    case uBahn, sBahn, regional
    // Street/mezzanine elevators at S+U stations serve every network; forcing
    // them into one would be wrong, so they get their own bucket.
    case access

    var label: String {
        switch self {
        case .uBahn:    "U-Bahn"
        case .sBahn:    "S-Bahn"
        case .regional: String(localized: "Regionalverkehr")
        case .access:   String(localized: "Zugang")
        }
    }

    static func < (lhs: TransitNetwork, rhs: TransitNetwork) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    // transit.accessibility.cloud transport-mode entities, served on the stop
    // place as modes.servicedTransportModes (CMS ids, verified live
    // 2026-08-03: 1 = S-Bahn, 2 = U-Bahn, 3 = Regional- und Fernbahn).
    init?(transportModeId: Int) {
        switch transportModeId {
        case 1: self = .sBahn
        case 2: self = .uBahn
        case 3: self = .regional
        default: return nil
        }
    }

    // The source feed settles most records; at S+U stations the BVG feed also
    // carries the S-Bahn platform elevators (e.g. Pankow), so the description
    // has to tell U from S there. `stationModes` are the networks the whole
    // station serves (from the stop place's transport modes): they settle
    // DB records at unprefixed S-Bahn stations (Waßmannsdorf, Hoppegarten, …)
    // and unmarked elevators at single-network stations. Seed-only records
    // carry no modes — there the old name/description fallbacks remain.
    static func classify(
        description: String,
        stationName: String,
        sourceName: String,
        stationModes: Set<TransitNetwork> = []
    ) -> TransitNetwork {
        if sourceName.contains("S-Bahn") { return .sBahn }        // VBB Anlagen (S-Bahn)
        if sourceName.contains("DB Regio") { return .regional }   // VBB-Anlagen (DB Regio)
        if sourceName == "DB FaSta" {
            if stationName.hasPrefix("S ") || stationModes == [.sBahn] { return .sBahn }
            return .regional
        }
        // BVG / brokenlifts.
        if description.range(of: #"U-?\s?Bahnsteig|Bahnsteig U\d|\bU\d\b"#, options: .regularExpression) != nil {
            return .uBahn
        }
        if description.range(of: #"S-?\s?Bahnsteig|Bahnsteig S|S-Bahn"#, options: .regularExpression) != nil {
            return .sBahn
        }
        if stationName.hasPrefix("U ") { return .uBahn }
        if stationName.hasPrefix("S ") { return .sBahn }
        if sourceName.hasPrefix("BVG") && !stationName.hasPrefix("S+U") { return .uBahn }
        // A station serving exactly one network: its unmarked elevators serve
        // that network too. Multi-network stations keep the "Zugang" bucket.
        if stationModes.count == 1, let only = stationModes.first { return only }
        return .access
    }
}
