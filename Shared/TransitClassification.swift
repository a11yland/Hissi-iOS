import Foundation

// Region and network classification behind the grouped search results. Pure
// string classifiers, nonisolated (the targets default to MainActor
// isolation); unit-tested in HissiCore.

// The federal state a station lies in — the top level of the grouped search
// results. A stop place's DHID carries the AGS ("de:11000:…" = Berlin,
// "de:09…" = Bayern); the generator stamps every seed record with its
// station's state (from the DHID, or from the coordinate for the stations it
// assigned), and records without either fall back to the name heuristic.
// Declared in display order: the home network first, then alphabetical. The
// raw values are the seed's `region` values — never rename them, the
// persisted catalog encodes them too.
nonisolated enum TransitRegion: String, Codable, CaseIterable {
    case berlin
    case brandenburg
    case badenWuerttemberg = "baden-wuerttemberg"
    case bayern
    case bremen
    case hamburg
    case hessen
    case mecklenburgVorpommern = "mecklenburg-vorpommern"
    case niedersachsen
    case nordrheinWestfalen = "nordrhein-westfalen"
    case rheinlandPfalz = "rheinland-pfalz"
    case saarland
    case sachsen
    case sachsenAnhalt = "sachsen-anhalt"
    case schleswigHolstein = "schleswig-holstein"
    case thueringen

    var label: String {
        switch self {
        case .berlin:                "Berlin"
        case .brandenburg:           "Brandenburg"
        case .badenWuerttemberg:     "Baden-Württemberg"
        case .bayern:                String(localized: "Bayern")
        case .bremen:                "Bremen"
        case .hamburg:               "Hamburg"
        case .hessen:                String(localized: "Hessen")
        case .mecklenburgVorpommern: String(localized: "Mecklenburg-Vorpommern")
        case .niedersachsen:         String(localized: "Niedersachsen")
        case .nordrheinWestfalen:    String(localized: "Nordrhein-Westfalen")
        case .rheinlandPfalz:        String(localized: "Rheinland-Pfalz")
        case .saarland:              "Saarland"
        case .sachsen:               String(localized: "Sachsen")
        case .sachsenAnhalt:         String(localized: "Sachsen-Anhalt")
        case .schleswigHolstein:     "Schleswig-Holstein"
        case .thueringen:            String(localized: "Thüringen")
        }
    }

    // The AGS state key ("de:11…") of a DHID.
    static func from(originalPlaceInfoId id: String?) -> TransitRegion? {
        guard let id, id.hasPrefix("de:"), id.count >= 5 else { return nil }
        let key = id.dropFirst(3).prefix(2)
        return byStateKey[String(key)]
    }

    private static let byStateKey: [String: TransitRegion] = [
        "01": .schleswigHolstein, "02": .hamburg, "03": .niedersachsen, "04": .bremen,
        "05": .nordrheinWestfalen, "06": .hessen, "07": .rheinlandPfalz,
        "08": .badenWuerttemberg, "09": .bayern, "10": .saarland, "11": .berlin,
        "12": .brandenburg, "13": .mecklenburgVorpommern, "14": .sachsen,
        "15": .sachsenAnhalt, "16": .thueringen,
    ]

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
        organizationName: String = "",
        stationModes: Set<TransitNetwork> = []
    ) -> TransitNetwork {
        if sourceName.contains("S-Bahn") { return .sBahn }        // VBB Anlagen (S-Bahn)
        if sourceName.contains("DB Regio") { return .regional }   // VBB-Anlagen (DB Regio)
        // DB elevators: the FaSta feed, or — for the ~300 the platform
        // carries without a feed — the operator.
        if sourceName == "DB FaSta" || organizationName == "DB InfraGO" {
            // DB marks S-Bahn platforms in the text ("Gl. 3/4 (S-Bahn)",
            // "S-Bahnsteig Gl. 22", "Westliches Bahnsteig.ende S-Bahn") — the only hint at stations that serve
            // both, and at the assigned stations, which carry no modes.
            if stationName.hasPrefix("S ") || stationModes == [.sBahn]
                || description.range(of: #"S-?\s?Bahnsteig|\bS-Bahn\b"#, options: .regularExpression) != nil {
                return .sBahn
            }
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
