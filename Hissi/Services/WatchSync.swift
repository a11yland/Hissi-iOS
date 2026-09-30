// WatchConnectivity is unavailable on Mac Catalyst — a Mac pairs no watch.
#if !targetEnvironment(macCatalyst)
import Foundation
import WatchConnectivity

@MainActor
final class WatchSync: NSObject {
    static let shared = WatchSync()
    static let payloadKey = "elevators"

    private var session: WCSession?
    private var pending: [MonitoredElevator]?

    func start() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        self.session = session
    }

    func push(_ elevators: [MonitoredElevator]) {
        guard let session, session.activationState == .activated else {
            pending = elevators
            return
        }
        send(elevators, on: session)
    }

    private func send(_ elevators: [MonitoredElevator], on session: WCSession) {
        guard let data = try? JSONEncoder().encode(elevators) else { return }
        try? session.updateApplicationContext([Self.payloadKey: data])
    }
}

extension WatchSync: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        guard state == .activated else { return }
        Task { @MainActor in
            if let pending = self.pending {
                self.send(pending, on: session)
                self.pending = nil
            }
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        // iOS allows pairing with a different watch — reactivate to pick that up.
        WCSession.default.activate()
    }
}

#else

import Foundation

@MainActor
final class WatchSync: NSObject {
    static let shared = WatchSync()
    func start() {}
    func push(_ elevators: [MonitoredElevator]) {}
}

#endif
