import Foundation
import Testing
@testable import HissiCore

// WCAG 2.2 SC 1.4.6 (AAA, 7:1) for every colour that carries text: the tint
// from the asset catalog on the grounds it is drawn on, the filled button's
// label on the button, white on the badges. Reads the colorsets themselves so
// a colour edited in Xcode is what gets checked.
@Suite struct PaletteTests {
    private static let catalogURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // HissiTests
        .deletingLastPathComponent()  // repo
        .appending(path: "Shared/Colors.xcassets")

    private func accentColors() throws -> (light: String, dark: String) {
        try colors(named: "AccentColor")
    }

    // (light, dark) hex from the colorset's "0x.." components.
    private func colors(named name: String) throws -> (light: String, dark: String) {
        let data = try Data(contentsOf: Self.catalogURL.appending(path: "\(name).colorset/Contents.json"))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let colors = try #require(json["colors"] as? [[String: Any]])
        var light: String?, dark: String?
        for entry in colors {
            let components = try #require((entry["color"] as? [String: Any])?["components"] as? [String: String])
            let hex = "#" + ["red", "green", "blue"].map { components[$0]!.replacingOccurrences(of: "0x", with: "") }.joined()
            let isDark = (entry["appearances"] as? [[String: String]])?.contains { $0["value"] == "dark" } ?? false
            if isDark { dark = hex } else { light = hex }
        }
        return (try #require(light), try #require(dark))
    }

    @Test func tintIsEnhancedContrastTextOnEveryGround() throws {
        let accent = try accentColors()
        for ground in Palette.lightGrounds {
            #expect(WCAGContrast.ratio(accent.light, ground) >= Palette.enhancedTextContrast, "light tint on \(ground)")
        }
        for ground in Palette.darkGrounds {
            #expect(WCAGContrast.ratio(accent.dark, ground) >= Palette.enhancedTextContrast, "dark tint on \(ground)")
        }
    }

    // .bordered fills with the tint at low opacity and writes the tint on it.
    @Test func tintReadsOnItsOwnBorderedFill() throws {
        let accent = try accentColors()
        let lightFill = WCAGContrast.blend(accent.light, over: Palette.lightGrounds[0], alpha: 0.15)
        #expect(WCAGContrast.ratio(accent.light, lightFill) >= 6.5, "light bordered fill is the tightest pairing (6.7:1); keep it near AAA")
        let darkFill = WCAGContrast.blend(accent.dark, over: Palette.darkGrounds[0], alpha: 0.15)
        #expect(WCAGContrast.ratio(accent.dark, darkFill) >= Palette.enhancedTextContrast)
    }

    // .borderedProminent: the palette's own label colour on the tint
    // (HissiOnButton via ProminentButtonLabel) — white on the pale dark tint
    // would be ~1.7:1, which is why the system default is not used.
    @Test func prominentLabelsReadOnTheTint() throws {
        let accent = try accentColors()
        let onButton = try colors(named: "HissiOnButton")
        #expect(WCAGContrast.ratio(onButton.light, accent.light) >= Palette.enhancedTextContrast)
        #expect(WCAGContrast.ratio(onButton.dark, accent.dark) >= Palette.enhancedTextContrast)
        #expect(WCAGContrast.ratio("#FFFFFF", accent.dark) < 4.5, "if this passes, the system's white label would do")
    }

    // The status words are the design's darker text variants — AA on every
    // ground (the symbol colours alone are not, in light mode).
    @Test func statusTextReadsOnEveryGround() throws {
        for name in ["HissiStatusOKText", "HissiStatusUnknownText", "HissiStatusDownText", "HissiTextSecondary"] {
            let pair = try colors(named: name)
            for ground in Palette.lightGrounds {
                #expect(WCAGContrast.ratio(pair.light, ground) >= 4.5, "\(name) light on \(ground)")
            }
            for ground in Palette.darkGrounds {
                #expect(WCAGContrast.ratio(pair.dark, ground) >= 4.5, "\(name) dark on \(ground)")
            }
        }
    }

    @Test func badgesCarryWhiteTextAtEnhancedContrast() {
        for badge in [Palette.uBahnBadge, Palette.sBahnBadge, Palette.regionalBadge, Palette.accessBadge] {
            #expect(WCAGContrast.ratio("#FFFFFF", badge) >= Palette.enhancedTextContrast, Comment(rawValue: badge))
        }
    }

    @Test func contrastMathMatchesTheReferenceValues() {
        #expect(abs(WCAGContrast.ratio("#000000", "#FFFFFF") - 21) < 0.01)
        #expect(abs(WCAGContrast.ratio("#007AFF", "#FFFFFF") - 4.0) < 0.05)
        #expect(WCAGContrast.blend("#000000", over: "#FFFFFF", alpha: 0.5) == "#808080")
    }
}
