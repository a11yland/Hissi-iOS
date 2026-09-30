import SwiftUI

// The Hissi palette ("Creme-Lila"): the named colour sets in
// Shared/Colors.xcassets, each a light/dark pair, compiled into every target.
// Light is lilac on cream, dark is pale lilac on a very dark purple; status
// colours follow the mark — the ping green for "läuft", amber for "unbekannt",
// red for "gestört" — with a darker text variant where the symbol colour
// alone would fall short of 4.5:1 on cream. Contrast is checked in
// PaletteTests against the same grounds.
//
// Xcode generates these symbols from the catalog; the SwiftPM test package
// (macOS, catalog excluded) gets the same names spelled out.
#if SWIFT_PACKAGE
extension Color {
    static let hissiBackground = Color("HissiBackground")
    static let hissiSurface = Color("HissiSurface")
    static let hissiSeparator = Color("HissiSeparator")
    static let hissiTextSecondary = Color("HissiTextSecondary")
    // The filled button and its label. Light: the same lilac as the tint.
    static let hissiButton = Color("HissiButton")
    static let hissiOnButton = Color("HissiOnButton")

    static let hissiStatusOK = Color("HissiStatusOK")
    static let hissiStatusOKText = Color("HissiStatusOKText")
    static let hissiStatusUnknown = Color("HissiStatusUnknown")
    static let hissiStatusUnknownText = Color("HissiStatusUnknownText")
    static let hissiStatusDown = Color("HissiStatusDown")
    static let hissiStatusDownText = Color("HissiStatusDownText")

    // The mark's frame and ping colours on light/dark ground (LogoMark).
    static let hissiMarkFrame = Color("HissiMarkFrame")
    static let hissiMarkAccent = Color("HissiMarkAccent")
}
#endif

extension ElevatorStatus {
    // For the status symbol; `textColor` for the status word beside it.
    var symbolColor: Color {
        switch self {
        case .working: .hissiStatusOK
        case .broken:  .hissiStatusDown
        case .unknown: .hissiStatusUnknown
        }
    }

    var textColor: Color {
        switch self {
        case .working: .hissiStatusOKText
        case .broken:  .hissiStatusDownText
        case .unknown: .hissiStatusUnknownText
        }
    }
}

#if os(iOS)
extension View {
    // A List on the app's cream/dark ground instead of the system's grouped
    // canvas; pair with `hissiRows()` on its sections.
    func hissiList() -> some View {
        scrollContentBackground(.hidden)
            .background(Color.hissiBackground.ignoresSafeArea())
    }

    // Rows as cards on the surface colour, separators in the palette's line
    // colour. Applied to a Section it reaches every row in it.
    func hissiRows() -> some View {
        listRowBackground(Color.hissiSurface)
            .listRowSeparatorTint(Color.hissiSeparator)
    }
}
#endif
