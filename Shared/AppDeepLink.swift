import Foundation

// URLs a widget or complication hands to its containing app. A complication
// tap can't run anything itself — WidgetKit opens the app and delivers the
// widgetURL to `onOpenURL`, so the URL is the whole contract between the
// two extensions and their apps. No scheme registration is needed for that
// route; the scheme is private vocabulary, not a public entry point.
nonisolated enum AppDeepLink: Equatable {
    case nearby

    private static let scheme = "hissi"

    var url: URL {
        switch self {
        case .nearby: URL(string: "\(Self.scheme)://nearby")!
        }
    }

    init?(_ url: URL) {
        guard url.scheme == Self.scheme else { return nil }
        switch url.host {
        case "nearby": self = .nearby
        default: return nil
        }
    }
}
