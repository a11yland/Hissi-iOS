import Foundation

enum RefreshInterval {
    static let minutes: Int = 30
    static let seconds: TimeInterval = TimeInterval(minutes * 60)

    // While the live status (Live Activity) is running the app polls tighter:
    // the activity is the surface the user is actually looking at, and it lives
    // at most a couple of hours. Still one targeted request per refresh, so the
    // request budget stays bounded (Q4).
    static let liveStatusMinutes: Int = 10
    static let liveStatusSeconds: TimeInterval = TimeInterval(liveStatusMinutes * 60)

    static func interval(liveStatusRunning: Bool) -> TimeInterval {
        liveStatusRunning ? liveStatusSeconds : seconds
    }

    // A timeline reload that lands right after something else wrote the cache
    // (the app's refresh, the watch sync) answers from it instead of fetching
    // again — several widget kinds reload at once, and each would otherwise
    // repeat the same request.
    static let cacheReuseSeconds: TimeInterval = 90
}
