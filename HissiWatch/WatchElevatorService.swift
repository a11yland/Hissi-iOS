import Foundation
import Combine

@MainActor
class WatchElevatorService: ObservableObject {
    @Published var elevators: [MonitoredElevator] = []

    func refresh() async {
        // Favorites live on the phone and arrive via WatchConnectivity. The
        // self-fetch only has the watch's mirrored cache to work from.
        let (updated, _) = await ElevatorRefresher.refreshAll(ElevatorCache.load())
        elevators = updated
    }
}
