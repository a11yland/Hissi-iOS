import SwiftUI

// The app's fixed colours that carry text, and the WCAG arithmetic that keeps
// them honest. The tint itself lives in Shared/Colors.xcassets (AccentColor:
// #503C74 light, #D4BBFC dark — AAA, 7:1, as text on every ground it is shown
// on; the design's lighter #69548D would be 5.9:1, so the tint is the palette's
// button lilac instead); the unit tests read that colorset and check it against
// the same grounds as the constants here (PaletteTests).
//
// Hex strings rather than Colors so the test package (macOS, no UIKit) can do
// the maths on the same values the views use.
nonisolated enum Palette {
    // Network badges: a white letter on the network's colour. Brand-adjacent
    // darkenings of U-Bahn blue, S-Bahn green and DB red — the originals
    // (system blue/green/red) put white text at 4.0 / 2.2 / 3.5:1.
    static let uBahnBadge = "#0040A0"
    static let sBahnBadge = "#006400"
    static let regionalBadge = "#B00000"
    static let accessBadge = "#555555"

    // Grounds the tint is drawn on as text (HissiBackground, HissiSurface and
    // the design's second surface tone). Light: cream; dark: deep purple.
    static let lightGrounds = ["#FBF3E4", "#FFFBF4", "#F3E8D6"]
    static let darkGrounds = ["#120E17", "#221B2B", "#2E2539"]

    // WCAG 2.2 SC 1.4.6 (AAA) for normal text.
    static let enhancedTextContrast = 7.0
}

nonisolated enum WCAGContrast {
    // Relative luminance per WCAG 2.x, sRGB.
    static func luminance(hex: String) -> Double {
        let (r, g, b) = rgb(hex: hex)
        func channel(_ c: Double) -> Double {
            c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
    }

    static func ratio(_ a: String, _ b: String) -> Double {
        let la = luminance(hex: a), lb = luminance(hex: b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    // `alpha` of `fg` over `bg`, as the bordered button style fills with its
    // tint at low opacity.
    static func blend(_ fg: String, over bg: String, alpha: Double) -> String {
        let f = rgb(hex: fg), b = rgb(hex: bg)
        func mix(_ x: Double, _ y: Double) -> Int { Int((alpha * x + (1 - alpha) * y) * 255 + 0.5) }
        return String(format: "#%02X%02X%02X", mix(f.0, b.0), mix(f.1, b.1), mix(f.2, b.2))
    }

    static func rgb(hex: String) -> (Double, Double, Double) {
        var value: UInt64 = 0
        Scanner(string: String(hex.dropFirst())).scanHexInt64(&value)
        return (
            Double((value >> 16) & 0xFF) / 255,
            Double((value >> 8) & 0xFF) / 255,
            Double(value & 0xFF) / 255
        )
    }
}

extension Color {
    init(hex: String) {
        let (r, g, b) = WCAGContrast.rgb(hex: hex)
        self.init(red: r, green: g, blue: b)
    }
}
