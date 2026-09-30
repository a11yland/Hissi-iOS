import Foundation
import BackgroundTasks

// Runs the favorites refresh while the app is suspended so the widget,
// complications and cache stay reasonably fresh between foreground sessions.
// The identifier must be listed in Info.plist under
// BGTaskSchedulerPermittedIdentifiers, or submit(_:) throws .notPermitted.
enum BackgroundRefreshManager {
    static let taskIdentifier = "com.a11yland.Hissi.refresh"

    // Register the launch handler before app launch completes (from App.init()).
    static func register() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: taskIdentifier,
            using: nil
        ) { task in
            handle(task: task as! BGAppRefreshTask)
        }
    }

    // Request the next background refresh. earliestBeginDate is a lower-bound
    // hint; the system picks the actual launch time. Call on entering background.
    //
    // While the live status (Live Activity) runs the app asks sooner — the
    // activity is on the Lock Screen and every background run is a chance to
    // update it.
    // Read from the App-Group flag, not from ActivityKit: this runs outside the
    // main actor, and a stale hint costs nothing but an early request.
    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Date(
            timeIntervalSinceNow: RefreshInterval.interval(liveStatusRunning: LiveStatusFlag.isRunning)
        )
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            print("Could not schedule background refresh: \(error)")
        }
    }

    private static func handle(task: BGAppRefreshTask) {
        // Schedule the next refresh before doing work.
        schedule()

        let work = Task {
            let elevators = RefreshFanOut.cachedFavorites()
            guard !elevators.isEmpty else {
                task.setTaskCompleted(success: true)
                return
            }

            let (updated, _) = await ElevatorRefresher.refreshAll(elevators)
            guard !Task.isCancelled else {
                task.setTaskCompleted(success: false)
                return
            }
            // Updating a Live Activity from the background is allowed (only
            // *starting* one needs the foreground), and without a push server
            // these runs are what keeps the live status alive between app
            // sessions. The pre-refresh state seeds the alert baseline — this
            // may be a freshly launched process that has none in memory.
            await RefreshFanOut.distribute(updated, previous: elevators)
            task.setTaskCompleted(success: true)
        }

        task.expirationHandler = {
            work.cancel()
            task.setTaskCompleted(success: false)
        }
    }
}
