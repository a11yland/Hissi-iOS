import SwiftUI

// "Über Hissi", behind the toolbar logo: what the app does (the same
// feature rows the welcome sheet draws from) and where the data comes from
// — accessibility.cloud, a project of Sozialhelden e.V. The attribution is
// also required by accessibility.cloud's terms (see AttributionFooter); here
// it gets the room to say who is behind it.
struct AboutSheet: View {
    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        return build.isEmpty ? short : "\(short) (\(build))"
    }

    var body: some View {
        OnboardingScaffold(buttonTitle: "Schließen") {
            // Headline: the icon left, name and version beside it — one
            // VoiceOver element, "Hissi, Version 8.0 (12)".
            HStack(spacing: 16) {
                Image("Logo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: "Hissi")
                        .font(.largeTitle.bold())
                    Text("Version \(version)")
                        .font(.subheadline)
                        .foregroundStyle(Color.hissiTextSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)

            VStack(alignment: .leading, spacing: 24) {
                ForEach(AppFeature.all) { feature in
                    FeatureRow(feature: feature)
                }
            }
            .padding(.top, 8)

            VStack(alignment: .leading, spacing: 8) {
                Text("Daten")
                    .font(.headline)
                Text("Die Aufzugsdaten kommen von accessibility.cloud, ins Leben gerufen vom Sozialhelden e.V. – dem gemeinnützigen Verein hinter Wheelmap, der sich für Barrierefreiheit im Alltag einsetzt.")
                    .font(.subheadline)
                    .foregroundStyle(Color.hissiTextSecondary)
                HStack(spacing: 16) {
                    Link("accessibility.cloud", destination: AttributionLinks.accessibilityCloud)
                    Link("Sozialhelden e.V.", destination: AttributionLinks.sozialhelden)
                }
                .font(.subheadline.weight(.semibold))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 24)
        }
    }
}

// The two organisations the data attribution points to — one place for the
// URLs, used by the footer and the about sheet.
enum AttributionLinks {
    static let accessibilityCloud = URL(string: "https://transit.accessibility.cloud")!
    static let sozialhelden = URL(string: "https://sozialhelden.de")!
}

#Preview("Über Hissi") {
    AboutSheet()
}
