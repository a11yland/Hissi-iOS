import SwiftUI

// .borderedProminent paints its label white on the tint. The dark tint is a
// pale lilac (#D4BBFC — AAA as text on dark grounds, see Shared/Colors.xcassets),
// and white on it is 1.7:1; the palette names the label colour for the filled
// button instead (HissiOnButton: cream on the light lilac, dark purple on the
// pale one — both AAA, checked in PaletteTests).
private struct ProminentButtonLabel: ViewModifier {
    func body(content: Content) -> some View {
        content.foregroundStyle(Color.hissiOnButton)
    }
}

extension View {
    // Apply to the label of a .borderedProminent button.
    func prominentButtonLabel() -> some View { modifier(ProminentButtonLabel()) }
}
