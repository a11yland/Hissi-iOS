import SwiftUI

// "Über Hissi", behind the toolbar logo. Not an onboarding moment but a
// reference screen, so it is a sectioned list rather than the welcome's
// scaffold: nothing sits below the fold behind a pinned button, and the
// data attribution — required by accessibility.cloud's terms and by the
// Aufzugsstatus API's CC BY 4.0 licence, and since the favorites footer
// dropped its links the one place that carries it —
// has a section of its own instead of a paragraph the close button hides.
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
                    Text("Die Aufzugsdaten für Berlin und Brandenburg stammen von accessibility.cloud, einem Projekt des gemeinnützigen Sozialhelden e.V. Bahnhöfe im übrigen Deutschland liefert die Aufzugsstatus-API von plötzlich querschnitt (DB InfraGO und weitere Betreiber, CC BY 4.0).")
                        .font(.subheadline)
                        .foregroundStyle(Color.hissiTextSecondary)
                    LinkRow(title: "accessibility.cloud", destination: AttributionLinks.accessibilityCloud)
                    LinkRow(title: "Sozialhelden e.V.", destination: AttributionLinks.sozialhelden)
                    LinkRow(title: "Aufzugsstatus-API", destination: AttributionLinks.aufzugsstatus)
                }
                .hissiRows()

                Section("Datenschutz") {
                    Text("Hissi braucht kein Konto und sammelt keine Daten. Favoriten liegen auf deinem Gerät und in deiner iCloud. Dein genauer Standort verlässt das Gerät nicht; nur wenn in Fußweite keine VBB-Station liegt, fragt die App den bundesweiten Dienst mit einer auf etwa einen Kilometer vergröberten Position.")
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
                Text("Aufzugstatus für Berlin, Brandenburg und Bahnhöfe deutschlandweit")
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

// The sources the data attribution points to — one place for the URLs.
// accessibility.cloud's terms ask for the attribution, the Aufzugsstatus
// API's CC BY 4.0 licence requires it.
enum AttributionLinks {
    static let accessibilityCloud = URL(string: "https://transit.accessibility.cloud")!
    static let sozialhelden = URL(string: "https://sozialhelden.de")!
    static let aufzugsstatus = URL(string: "https://aufzuege.ploetzlich-querschnitt.de/api/")!
}

#Preview("Über Hissi") {
    AboutSheet()
}
