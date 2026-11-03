import SwiftUI

// A block's answer when it has nothing to list — "no station nearby", "no
// recent searches": a symbol and one sentence on the row surface, so it
// reads as a result rather than as a footnote. One VoiceOver element.
struct NoticeCard: View {
    let text: LocalizedStringKey
    let systemImage: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.subheadline)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color.hissiSurface, in: RoundedRectangle(cornerRadius: 12))
            .accessibilityElement(children: .combine)
    }
}
