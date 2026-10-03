import XCTest

// Drives the app through its screens and saves one screenshot per screen —
// the App Store screenshots, reproducible per release and device. Run via
// scripts/screenshots.sh, which prepares the simulator (clean status bar,
// Berlin location, language) and passes SCREENSHOT_DIR; without that
// variable the shots only land in the test result bundle as attachments.
//
// The queries are the app's German labels: the store's primary language,
// and the one `-testLanguage de` launches the app in.
final class ScreenshotTests: XCTestCase {
    private var app: XCUIApplication!
    private let outputDirectory = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"]
        .map { URL(fileURLWithPath: $0, isDirectory: true) }

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    func testStoreScreenshots() throws {
        // First launch: the welcome sheet.
        let start = app.buttons["Los geht's"]
        if start.waitForExistence(timeout: 10) {
            snap("01-welcome")
            start.tap()
        }

        // Search: results with live statuses, then star a few across stations.
        search("Alexanderplatz")
        waitForLiveStatuses()
        snap("02-search")
        favoriteFirst(2)
        openFirstResult()
        snap("03-detail")
        goBack()
        cancelSearch()

        search("Pankow")
        waitForLiveStatuses()
        favoriteFirst(1)
        cancelSearch()

        search("Hauptbahnhof")
        waitForLiveStatuses()
        favoriteFirst(1)
        cancelSearch()

        // Favorites list, light and dark.
        require(app.staticTexts["Live-Status starten"], "favorites list")
        sleep(2)
        snap("04-favorites")
        toggleAppearance()
        snap("05-favorites-dark")
        toggleAppearance()

        // Nearby: opens the search with the nearby block; the location prompt
        // comes from SpringBoard.
        app.buttons["Stationen in der Nähe anzeigen"].firstMatch.tap()
        allowLocation()
        let nearbyHeader = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "zu Fuß")).firstMatch
        require(nearbyHeader, "nearby stations", timeout: 30)
        sleep(4)
        // The keyboard would cover half the shot; a drag towards it dismisses
        // it interactively (the return key is disabled on an empty query).
        if app.keyboards.firstMatch.exists {
            let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
            let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
            from.press(forDuration: 0.1, thenDragTo: to)
            sleep(1)
        }
        snap("06-nearby")
        cancelSearch()

        // Live status: start it, show the running section.
        let tripButton = app.buttons["Für die Fahrt (2 Std.)"]
        if tripButton.waitForExistence(timeout: 5) {
            tripButton.tap()
            if app.staticTexts["Live-Status läuft"].waitForExistence(timeout: 10) {
                sleep(1)
                snap("07-live-status")
                lockScreenShot("08-lock-screen")
            }
        }

        // About.
        app.activate()
        let about = app.buttons["Über Hissi"]
        require(about, "favorites toolbar")
        about.tap()
        require(app.buttons["Fertig"], "about sheet")
        sleep(1)
        snap("09-about")
        app.buttons["Fertig"].tap()
    }

    // MARK: - Steps

    private func search(_ term: String) {
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        let clear = field.buttons["Text löschen"]
        if clear.exists { clear.tap() }
        // Focus, not the keyboard: the iPad simulator may have a hardware
        // keyboard attached, in which case none is drawn.
        func focused() -> Bool {
            let expectation = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "hasKeyboardFocus == true"), object: field
            )
            return XCTWaiter.wait(for: [expectation], timeout: 5) == .completed
        }
        if !focused() {
            field.tap()
            if !focused() { fail("search field focus for \(term)") }
        }
        field.typeText(term + "\n")
    }

    // Phase 2 of the search replaces the instant snapshot with live statuses;
    // the banner marks the wait. A cold catalog build takes ~30 s.
    private func waitForLiveStatuses() {
        let banner = app.staticTexts["Status wird aktualisiert …"]
        _ = banner.waitForExistence(timeout: 3)
        let gone = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: gone, object: banner)
        _ = XCTWaiter.wait(for: [expectation], timeout: 120)
        require(app.cells.firstMatch, "search results")
        sleep(1)
    }

    private func favoriteFirst(_ count: Int) {
        let stars = app.buttons.matching(identifier: "Zu Favoriten hinzufügen")
        for _ in 0..<count where stars.firstMatch.exists {
            stars.firstMatch.tap()
        }
    }

    private func openFirstResult() {
        // The first cells are the station and network headers; an elevator
        // row is the NavigationLink button whose combined label carries the
        // status. Rows scrolled under the header report a frame but take no
        // tap, so the first hittable one.
        let rows = app.buttons.matching(NSPredicate(
            format: "(label CONTAINS %@ OR label CONTAINS %@) AND NOT (label CONTAINS %@)", "Betrieb", "nbekannt", "Favoriten"
        ))
        let row = rows.allElementsBoundByIndex.first { $0.isHittable } ?? rows.firstMatch
        row.tap()
        // The map snippet is one button labelled "Kartenausschnitt <station>".
        let map = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Kartenausschnitt")).firstMatch
        require(map, "detail map", timeout: 20)
        // Map tiles and the Look Around preview need a moment.
        sleep(5)
    }

    private func goBack() {
        let back = app.navigationBars.buttons["BackButton"]
        (back.exists ? back : app.navigationBars.buttons.firstMatch).tap()
        sleep(1)
    }

    private func cancelSearch() {
        // iPhone: the bottom search bar closes via its X ("Schließen");
        // iPad: the field sits in the navigation bar with "Abbrechen".
        // iPad: the navigation-bar field offers no cancel button, and neither
        // Escape nor clearing leaves the search — a relaunch does (favorites
        // are persisted, the welcome is already seen).
        let close = app.buttons.matching(NSPredicate(format: "label IN %@", ["Schließen", "Abbrechen"])).firstMatch
        if close.waitForExistence(timeout: 3) {
            close.tap()
        } else {
            app.terminate()
            app.launch()
        }
        require(app.navigationBars["Favoriten"], "favorites after closing the search")
        sleep(1)
    }

    private func toggleAppearance() {
        let toDark = app.buttons["Zu dunklem Erscheinungsbild wechseln"]
        let toLight = app.buttons["Zu hellem Erscheinungsbild wechseln"]
        (toDark.exists ? toDark : toLight).tap()
        sleep(1)
    }

    private func allowLocation() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch
        guard alert.waitForExistence(timeout: 8) else { return }
        let allow = alert.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@", "Verwenden", "While Using")).firstMatch
        if allow.exists { allow.tap() } else { alert.buttons.element(boundBy: alert.buttons.count - 1).tap() }
    }

    // Best effort: the Lock Screen with the running Live Activity. Locking
    // goes through a private selector that exists on the simulator; on
    // anything else the step is skipped.
    private func lockScreenShot(_ name: String) {
        let lock = Selector(("pressLockButton"))
        guard XCUIDevice.shared.responds(to: lock) else { return }
        XCUIDevice.shared.perform(lock)
        sleep(3)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        // The first Live Activity of an app asks for permission on the Lock Screen.
        let allow = springboard.buttons.matching(NSPredicate(format: "label IN %@", ["Erlauben", "Allow"])).firstMatch
        if allow.waitForExistence(timeout: 3) { allow.tap(); sleep(2) }
        snap(name)
        XCUIDevice.shared.perform(lock)
        sleep(1)
        springboard.swipeUp()
        sleep(2)
        app.activate()
        sleep(2)
    }

    // MARK: - Capture

    // Waits for an element the flow depends on; on a miss it leaves the
    // element hierarchy and a screenshot next to the output, then fails.
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
