import SwiftUI

// "Über Hissi", behind the toolbar logo. Not an onboarding moment but a
// reference screen, so it is a sectioned list rather than the welcome's
// scaffold: nothing sits below the fold behind a pinned button, and the
// data attribution — required by accessibility.cloud's terms, see
// AttributionFooter — has a section of its own instead of a paragraph the
// close button hides.
struct AboutSheet: View {
    @Environment(\.dismiss) private var dismiss

    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        return build.isEmpty ? short : "\(short) (\(build))"
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    header
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                }

                Section("Funktionen") {
                    ForEach(AppFeature.all) { feature in
                        FeatureRow(feature: feature)
                            .padding(.vertical, 4)
                    }
                }
                .hissiRows()

                Section("Daten") {
                    Text("Die Aufzugsdaten stammen von accessibility.cloud, einem Projekt des gemeinnützigen Sozialhelden e.V.")
                        .font(.subheadline)
                        .foregroundStyle(Color.hissiTextSecondary)
                    LinkRow(title: "accessibility.cloud", destination: AttributionLinks.accessibilityCloud)
                    LinkRow(title: "Sozialhelden e.V.", destination: AttributionLinks.sozialhelden)
                }
                .hissiRows()

                Section("Datenschutz") {
                    Text("Hissi braucht kein Konto und sammelt keine Daten. Favoriten liegen auf deinem Gerät und in deiner iCloud, dein Standort verlässt das Gerät nicht.")
                        .font(.subheadline)
                        .foregroundStyle(Color.hissiTextSecondary)
                }
                .hissiRows()

                Section {
                    LabeledContent("Version", value: version)
                }
                .hissiRows()
            }
            .hissiList()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
        }
        .presentationDragIndicator(.visible)
        .presentationBackground(Color.hissiBackground)
    }

    // Icon, name and tagline — the sheet's title, one VoiceOver element and
    // a heading, so the navigation bar can stay empty.
    private var header: some View {
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
                Text("Aufzugstatus für Berlin und Brandenburg")
                    .font(.subheadline)
                    .foregroundStyle(Color.hissiTextSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

// A list row that opens a web page: title left, an outward arrow right so
// the row says it leaves the app.
private struct LinkRow: View {
    let title: LocalizedStringKey
    let destination: URL

    var body: some View {
        Link(destination: destination) {
            HStack {
                Text(title)
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.hissiTextSecondary)
                    .accessibilityHidden(true)
            }
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
