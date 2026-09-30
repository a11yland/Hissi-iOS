import Foundation
import WatchConnectivity
import WidgetKit

@MainActor
final class WatchSync: NSObject, ObservableObject {
    static let payloadKey = "elevators"

    @Published private(set) var received: [MonitoredElevator]?

    override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        // applicationContext is replayed on activation — surface any cached payload.
        decode(session.receivedApplicationContext)
    }

    private func decode(_ context: [String: Any]) {
        guard
            let data = context[Self.payloadKey] as? Data,
            let elevators = try? JSONDecoder().decode([MonitoredElevator].self, from: data)
        else { return }
        received = elevators
        // Persist into the watch's App Group so the complications (which can't
        // read the phone's favorites) have data, then refresh them.
        ElevatorCache.save(elevators)
        WidgetCenter.shared.reloadAllTimelines()
    }
}

extension WatchSync: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        let context = session.receivedApplicationContext
        Task { @MainActor in self.decode(context) }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor in self.decode(applicationContext) }
    }
}
