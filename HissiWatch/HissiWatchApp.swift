import SwiftUI

@main
struct HissiWatchApp: App {
    init() {
        #if DEBUG
        // Screenshot runs: the favorites the phone would push, without
        // depending on a paired phone (WatchSync ignores pushes meanwhile).
        if DemoMode.seedsFavorites {
            ElevatorCache.save(DemoFixtures.favorites(from: DemoFixtures.catalog()))
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            WatchContentView()
        }
    }
}
