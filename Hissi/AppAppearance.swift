import SwiftUI

// User-chosen appearance override for the current session. `.system` (the
// default) follows the iOS setting; the in-app toggle switches to an explicit
// light/dark scheme. Held in @State, so it resets to .system on each cold start.
enum AppAppearance {
    case system, light, dark

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light:  .light
        case .dark:   .dark
        }
    }
}
