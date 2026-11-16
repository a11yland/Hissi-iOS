import XCTest

// The watch app's App Store screenshots: favorites list, detail pager and
// the nearby screen. Run via scripts/screenshots.sh with an Apple Watch
// simulator name; SCREENSHOT_DIR is where the PNGs go. Demo mode (DemoMode)
// puts the DemoFixtures favorites straight into the watch's cache and
// serves the fixed catalog, so the run needs no paired phone and no
// network. App elements are found by accessibility identifier, so it runs
// in every language.
final class WatchScreenshotTests: XCTestCase {
    private var app: XCUIApplication!
    private let outputDirectory = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"]
        .map { URL(fileURLWithPath: $0, isDirectory: true) }

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-HissiDemoData", "YES", "-HissiDemoFavorites", "YES"]
        app.launch()
    }

    func testStoreScreenshots() throws {
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "elevatorRow."))
        require(rows.firstMatch, "watch list")
        sleep(1)
        snap("01-list")

        app.buttons["elevatorRow.broken"].tap()
        sleep(2)
        snap("02-detail")
        goBack()

        app.buttons["nearbyEntry"].tap()
        let locate = app.buttons["useLocation"]
        if locate.waitForExistence(timeout: 5) {
            locate.tap()
            allowLocation()
        }
        let station = app.buttons.matching(identifier: "nearbyStation.broken").firstMatch
        require(station, "nearby stations", timeout: 30)
        sleep(1)
        snap("03-nearby")

        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "nearbyStation.")).firstMatch.tap()
        sleep(2)
        snap("04-nearby-station")
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
        let labels = NSPredicate(
            format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@ OR label CONTAINS[c] %@ OR label CONTAINS[c] %@",
            "Erlauben", "Verwenden", "Allow", "While Using"
        )
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
        if let outputDirectory {
            try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            try? app.debugDescription.write(
                to: outputDirectory.appendingPathComponent("failure-\(what).txt"), atomically: true, encoding: .utf8
            )
        }
        snap("failure-\(what)")
        XCTFail("\(what) did not appear within \(Int(timeout)) s")
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
