#if !targetEnvironment(macCatalyst)
import ActivityKit
import Combine
import Foundation

// Owns the one Live Activity the app can have: the "Live-Status" over all
// favorites. The rules it applies are pure and live in Shared/LiveStatus.swift;
// this class is only the ActivityKit plumbing plus the state the UI binds to.
//
// Update path: every refresh the app performs — foreground poll, pull-to-
// refresh, background task — calls refresh(with:). There is no push server, so
// these are the only moments the activity can learn anything. What that costs
// in freshness is made visible instead of hidden: each update carries a
// staleDate, and the Live Activity marks itself as possibly outdated once it
// passes (same honesty as FR9/D3, never a stale status presented as current).
@MainActor
final class LiveActivityController: ObservableObject {
    static let shared = LiveActivityController()

    // Nil while no live status is running — the favorites UI binds to this.
    @Published private(set) var mode: LiveStatusMode?

    private var activity: Activity<LiveStatusAttributes>?
    // The favorites as of the last update: the alert rule compares per elevator,
    // and the capped ContentState rows are not enough to do that.
    private var lastElevators: [MonitoredElevator]?
    private var stateObserver: Task<Void, Never>?

    private init() {
        adoptRunningActivity()
    }

    var isRunning: Bool { mode != nil }

    // The user can switch Live Activities off per app in Settings; then there is
    // nothing to offer and the start UI stays hidden.
    var areActivitiesEnabled: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    // A Live Activity outlives the app process — after a cold start the running
    // one has to be picked back up, or the app would offer to start a second.
    func adoptRunningActivity() {
        guard activity == nil else { return }
        guard let running = Activity<LiveStatusAttributes>.activities.first else {
            LiveStatusFlag.isRunning = false
            return
        }
        adopt(running)
    }

    // MARK: - Lifecycle

    // Starting requires the foreground: without a push server there is no
    // push-to-start, so a live status is always something the user asked for.
    func start(_ mode: LiveStatusMode, with elevators: [MonitoredElevator]) {
        guard areActivitiesEnabled, activity == nil, !elevators.isEmpty else { return }
        let state = LiveStatusState(elevators)
        do {
            let started = try Activity<LiveStatusAttributes>.request(
                attributes: LiveStatusAttributes(startedAt: Date(), mode: mode),
                content: content(for: state),
                pushType: nil
            )
            lastElevators = elevators
            adopt(started)
        } catch {
            print("Could not start live activity: \(error)")
        }
    }

    // Called after every refresh, from the app and from the background task.
    // `previous` seeds the alert baseline when this process has none of its
    // own: a background task can relaunch the app in a fresh process, and the
    // transition that happened across that gap must still alert — it is the
    // one moment the activity exists for. In-memory wins once it exists.
    func refresh(with elevators: [MonitoredElevator], previous: [MonitoredElevator]? = nil) async {
        guard let activity, let mode else { return }
        // The observer task cannot run while the app is suspended, so an
        // activity the system ended on its own (multi-hour limit) can still
        // sit here — with the App-Group flag true, keeping the background
        // cadence tight for nothing. Notice the corpse instead of updating it.
        guard activity.activityState == .active || activity.activityState == .stale else {
            clear()
            return
        }
        let state = LiveStatusState(elevators)
        let alert = LiveStatusAlert.transition(from: lastElevators ?? previous, to: elevators)
        lastElevators = elevators

        // A trip's end time can pass while the app is suspended, so the check
        // happens on the next update rather than on a timer — the countdown on
        // the activity has run out by then either way.
        guard !LiveStatusRules.shouldEnd(mode: mode, state: state, now: Date()) else {
            // ActivityKit's end() cannot alert, and the transition that ends
            // an untilRepaired activity — "wieder in Betrieb" — is exactly the
            // news it was started for: deliver it as one last alerting update
            // before the activity goes away.
            if let alert {
                await activity.update(
                    content(for: state),
                    alertConfiguration: alertConfiguration(alert)
                )
            }
            await end(finalState: state)
            return
        }

        await activity.update(
            content(for: state),
            alertConfiguration: alert.map { alertConfiguration($0) }
        )
    }

    // finalState nil = the user stopped it themselves; there is nothing
    // left to say, so it goes away immediately.
    func end(finalState: LiveStatusState? = nil) async {
        guard let activity else { return }
        let final = finalState.map { content(for: $0) }
        await activity.end(
            final,
            // One that ended on its own ends *because* something happened
            // ("wieder in Betrieb") — leave that on the Lock Screen for a moment.
            dismissalPolicy: final == nil ? .immediate : .after(.now + 120)
        )
        clear()
    }

    // MARK: - Internals

    private func adopt(_ activity: Activity<LiveStatusAttributes>) {
        self.activity = activity
        mode = activity.attributes.mode
        LiveStatusFlag.isRunning = true
        stateObserver?.cancel()
        // The activity can also end without us: the button on the Lock Screen
        // (EndLiveStatusIntent), a swipe, or the system's own time limit.
        // Inherits the main actor from this method, so clear() needs no hop.
        stateObserver = Task { [weak self] in
            for await state in activity.activityStateUpdates
            where state == .ended || state == .dismissed {
                self?.clear()
                return
            }
        }
    }

    private func clear() {
        activity = nil
        mode = nil
        lastElevators = nil
        stateObserver = nil
        LiveStatusFlag.isRunning = false
    }

    private func content(for state: LiveStatusState) -> ActivityContent<LiveStatusState> {
        ActivityContent(
            state: state,
            // Two refresh cycles without an update and the activity says so
            // itself, rather than presenting an old status as current.
            staleDate: state.checkedAt.addingTimeInterval(RefreshInterval.liveStatusSeconds * 2),
            relevanceScore: Double(state.summary.relevanceScore)
        )
    }

    private func alertConfiguration(_ alert: LiveStatusAlert) -> AlertConfiguration {
        // The app has no notification permission and no server — this is its
        // only way to actively reach the user, which is why it fires on real
        // transitions only (see LiveStatusAlert.transition).
        AlertConfiguration(
            title: "\(alert.title)",
            body: "\(alert.body)",
            sound: .default
        )
    }
}

#else

import Combine
import Foundation

// Mac Catalyst has no ActivityKit. Same interface, nothing behind it, so the
// favorites UI (LiveStatusSection hides itself off areActivitiesEnabled), the
// refresh loop and the fan-out compile unchanged — the live status simply is
// not offered on the Mac.
@MainActor
final class LiveActivityController: ObservableObject {
    static let shared = LiveActivityController()

    @Published private(set) var mode: LiveStatusMode?
    var isRunning: Bool { false }
    var areActivitiesEnabled: Bool { false }

    private init() {}

    func adoptRunningActivity() {}
    func start(_ mode: LiveStatusMode, with elevators: [MonitoredElevator]) {}
    func refresh(with elevators: [MonitoredElevator], previous: [MonitoredElevator]? = nil) async {}
    func end(finalState: LiveStatusState? = nil) async {}
}

#endif
