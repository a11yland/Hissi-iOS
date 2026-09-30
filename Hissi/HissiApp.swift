//
//  HissiApp.swift
//  Hissi
//

import AppIntents
import SwiftUI

@main
struct HissiApp: App {
    init() {
        WatchSync.shared.start()
        BackgroundRefreshManager.register()
        // The parameterized App Shortcut ("⟨Aufzug⟩ in Hissi prüfen") only
        // works once the system has fetched the favorites at least once, so
        // publish them on every launch — not just when they change.
        HissiShortcuts.updateAppShortcutParameters()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
