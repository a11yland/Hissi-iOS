import XCTest

// The watch app's App Store screenshots: favorites list, detail pager and
// the nearby screen. Run via scripts/screenshots.sh with an Apple Watch
// simulator name — it boots the paired iPhone (which must have been through
// the iPhone screenshot run, so it holds favorites) and launches the phone
// app, whose refresh pushes the favorites to the watch via WatchConnectivity.
// SCREENSHOT_DIR is where the PNGs go; the labels are the app's German ones.
final class WatchScreenshotTests: XCTestCase {
    private var app: XCUIApplication!
    private let outputDirectory = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"]
        .map { URL(fileURLWithPath: $0, isDirectory: true) }

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    func testStoreScreenshots() throws {
        let nearbyEntry = app.descendants(matching: .any)["In der Nähe"].firstMatch
        require(nearbyEntry, "watch list")

        // Favorites arrive from the phone; the first push can take a while
        // after a fresh install. Without any, the list is just the entry.
        let rows = app.descendants(matching: .any).matching(NSPredicate(
            format: "(label CONTAINS %@ OR label CONTAINS %@) AND NOT (label CONTAINS %@)", "Betrieb", "nbekannt", "Nähe"
        ))
        _ = rows.firstMatch.waitForExistence(timeout: 90)
        sleep(2)
        snap("01-list")

        if rows.firstMatch.exists {
            rows.firstMatch.tap()
            sleep(3)
            snap("02-detail")
            goBack()
        }

        // Nearby: the watch locates itself after the button, then builds its
        // catalog once (~30 s) before the rows carry statuses.
        nearbyEntry.tap()
        let locate = app.buttons["Standort verwenden"]
        if locate.waitForExistence(timeout: 5) {
            locate.tap()
            allowLocation()
        }
        // Rows carry the status once the catalog is built; the "bis 1 km zu
        // Fuß" footer sits below the fold and is not in the hierarchy.
        let stationRows = app.descendants(matching: .any).matching(NSPredicate(
            format: "(label CONTAINS %@ OR label CONTAINS %@) AND label CONTAINS %@", "Betrieb", "nbekannt", " m"
        ))
        require(stationRows.firstMatch, "nearby stations", timeout: 150)
        sleep(5)
        snap("03-nearby")

        let station = stationRows.firstMatch
        if station.exists {
            station.tap()
            sleep(3)
            snap("04-nearby-station")
        }
    }

    // MARK: - Steps

    private func goBack() {
        let back = app.navigationBars.buttons.firstMatch
        if back.exists { back.tap() } else { app.swipeRight() }
        sleep(1)
    }

    // The location prompt is a system alert; on the simulator it shows up
    // in the app's own hierarchy, otherwise under the system UI.
    private func allowLocation() {
        let hosts = [app!, XCUIApplication(bundleIdentifier: "com.apple.Carousel")]
        let labels = NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@ OR label CONTAINS[c] %@", "Erlauben", "Verwenden", "Allow")
        for host in hosts {
            let button = host.buttons.matching(labels).firstMatch
            if button.waitForExistence(timeout: 5) {
                button.tap()
                return
            }
        }
    }

    // MARK: - Capture

    private func require(_ element: XCUIElement, _ what: String, timeout: TimeInterval = 10) {
        if element.waitForExistence(timeout: timeout) { return }
        fail("\(what) did not appear within \(Int(timeout)) s")
    }

    private func fail(_ what: String) {
        if let outputDirectory {
            try? app.debugDescription.write(
                to: outputDirectory.appendingPathComponent("failure-\(what).txt"), atomically: true, encoding: .utf8
            )
        }
        snap("failure-\(what)")
        XCTFail(what)
    }

    private func snap(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let outputDirectory else { return }
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        try? screenshot.pngRepresentation.write(to: outputDirectory.appendingPathComponent("\(name).png"))
    }
}
