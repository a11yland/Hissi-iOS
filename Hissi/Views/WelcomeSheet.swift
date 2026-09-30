import SwiftUI

// First-launch welcome and per-release "Was ist neu", both in the familiar
// Apple onboarding shape: title, a handful of feature rows, one filled
// button. Seen-state is stamped in onDisappear so swipe-down counts too.

extension WelcomeGate.Sheet: Identifiable {
    var id: String {
        switch self {
        case .welcome:                 "welcome"
        case .whatsNew(let version):   "whatsNew-\(version)"
        }
    }
}

struct WelcomeSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        OnboardingScaffold(buttonTitle: "Los geht's") {
            Image("Logo")
                .resizable()
                .scaledToFit()
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .accessibilityHidden(true)

            Text("Willkommen bei Hissi")
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 24) {
                ForEach(AppFeature.welcome) { feature in
                    FeatureRow(feature: feature)
                }
            }
            .padding(.top, 8)
        }
        .onDisappear { OnboardingState.markWelcomeSeen() }
    }
}

// What the app does, in the words the welcome and the about sheet use. The
// welcome keeps to three (first launch is not the moment for a feature
// list); "Über Hissi" shows all of them.
struct AppFeature: Identifiable {
    let symbol: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    var id: String { symbol }

    static let search = AppFeature(
        symbol: "magnifyingglass",
        title: "Stationen finden",
        detail: "Suche nach einer Station und sieh alle Aufzüge dort mit Live-Status."
    )
    static let nearby = AppFeature(
        symbol: "location.fill",
        title: "In der Nähe",
        detail: "Stationen in Fußweite mit dem Status ihrer Aufzüge – auch auf der Uhr und als Widget."
    )
    static let favorites = AppFeature(
        symbol: "star.fill",
        title: "Favoriten im Blick",
        detail: "Markiere Aufzüge als Favoriten und prüfe sie alle mit einem Blick."
    )
    static let liveStatus = AppFeature(
        symbol: "bell.badge",
        title: "Live-Status",
        detail: "Deine Favoriten auf dem Sperrbildschirm – meldet sich, wenn ein Aufzug ausfällt oder wieder läuft."
    )
    static let glanceable = AppFeature(
        symbol: "applewatch",
        title: "Widget & Watch",
        detail: "Der Status deiner Favoriten auf dem Homescreen und am Handgelenk."
    )
    static let siri = AppFeature(
        symbol: "mic.fill",
        title: "Siri und Kurzbefehle",
        detail: "Frag Siri nach dem Status – für alle Favoriten oder für einen bestimmten Aufzug."
    )

    static let welcome: [AppFeature] = [search, favorites, glanceable]
    static let all: [AppFeature] = [search, nearby, favorites, liveStatus, glanceable, siri]
}

struct WhatsNewSheet: View {
    let version: String

    var body: some View {
        OnboardingScaffold(buttonTitle: "Weiter") {
            Text("Was ist neu")
                .font(.largeTitle.bold())
            Text(verbatim: version)
                .font(.subheadline)
                .foregroundStyle(Color.hissiTextSecondary)

            VStack(alignment: .leading, spacing: 24) {
                notes
            }
            .padding(.top, 8)
        }
        .onDisappear { OnboardingState.markWhatsNewSeen(version) }
    }

    // Curated per release; versions listed here must appear in
    // WelcomeGate.curatedVersions, or the sheet never shows. 1.0 has none —
    // the welcome says what the app does.
    @ViewBuilder
    private var notes: some View {
        switch version {
        default:
            EmptyView()
        }
    }
}

// Shared shape: scrollable centered content, filled action button pinned to
// the bottom within thumb reach. Internal: the about sheet uses it too.
struct OnboardingScaffold<Content: View>: View {
    let buttonTitle: LocalizedStringKey
    @ViewBuilder let content: Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 12) {
                    content
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.top, 48)
                .padding(.bottom, 24)
            }

            Button {
                dismiss()
            } label: {
                Text(buttonTitle)
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                    .prominentButtonLabel()
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
        .presentationDragIndicator(.visible)
        .presentationBackground(Color.hissiBackground)
    }
}

struct FeatureRow: View {
    let symbol: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey

    init(symbol: String, title: LocalizedStringKey, detail: LocalizedStringKey) {
        self.symbol = symbol
        self.title = title
        self.detail = detail
    }

    init(feature: AppFeature) {
        self.init(symbol: feature.symbol, title: feature.title, detail: feature.detail)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 36)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(Color.hissiTextSecondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview("Welcome") {
    WelcomeSheet()
}

#Preview("Was ist neu") {
    WhatsNewSheet(version: "1.0")
}
