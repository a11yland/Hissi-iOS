import Foundation
import WidgetKit

// What every favorites refresh owes the mirrors — no matter who asked: the
// foreground poll, a favorite toggle, the background task or a Shortcut run.
// One place instead of three drifting copies (the Shortcut path had already
// lost the watch push and the Live Activity update).
@MainActor
enum RefreshFanOut {
    // Persist for the widgets, reload their timelines (cheap: a just-written
    // cache answers them without a fetch), push to the watch and feed a
    // running live status — `previous` is its alert baseline.
    static func distribute(
        _ elevators: [MonitoredElevator],
        previous: [MonitoredElevator]? = nil
    ) async {
        ElevatorCache.save(elevators)
        WidgetCenter.shared.reloadAllTimelines()
        WatchSync.shared.push(elevators)
        await LiveActivityController.shared.refresh(with: elevators, previous: previous)
    }

    // Favorites are the membership, the cache the last known status — the
    // starting point for refreshes that begin outside the app's own state
    // (background task, Shortcut run).
    static func cachedFavorites() -> [MonitoredElevator] {
        let cached = ElevatorCache.load()
        return FavoritesStore.load().map { favorite in
            cached.first { $0.id == favorite.id } ?? favorite
        }
    }
}
