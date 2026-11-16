import XCTest

// The App Store screenshots, one test per motif — reproducible per release,
// device and language. Run via scripts/screenshots.sh, which prepares the
// simulator (clean status bar, Alexanderplatz as location, language) and
// passes SCREENSHOT_DIR; without that variable the shots only land in the
// test result bundle as attachments.
//
// Every test launches the app fresh in demo mode (DemoMode: fixed catalog
// and statuses, the DemoFixtures favorites, no onboarding sheet), so a
// failing motif leaves the others standing and nothing has to be undone
// between them. App elements are found by accessibility identifier, so the
// test runs in every language; only system UI (alerts, SpringBoard) goes
// through the label table below. Tests run in name order — the widgets one
// relies on the location permission granted by the nearby one before it.
final class ScreenshotTests: XCTestCase {
    private var app: XCUIApplication!
    private let outputDirectory = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"]
        .map { URL(fileURLWithPath: $0, isDirectory: true) }
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    // MARK: - Motifs

    func test01Favorites() {
        launch()
        waitForFavorites()
        snap("01-favorites")
    }

    func test02LockScreen() throws {
        try requireLiveActivities()
        launch()
        waitForFavorites()
        toolbarButton("liveStatusButton").tap()
        // A failed earlier attempt (the script retries) can leave one running.
        let running = app.descendants(matching: .any)["liveStatusRunning"]
        if !running.waitForExistence(timeout: 2) {
            tap(app.buttons["liveStatusStartTrip"], "live status start")
        }
        require(running, "running live status")
        let locked = lockScreenShot("02-lock-screen")
        // A running activity would sit in the Dynamic Island of every
        // later shot.
        if locked { springboard.swipeUp() }
        app.activate()
        if !app.buttons["liveStatusEnd"].exists { toolbarButton("liveStatusButton").tap() }
        tap(app.buttons["liveStatusEnd"], "live status end")
        sleep(1)
        if !locked { throw XCTSkip("the Lock Screen can't be scripted on this simulator") }
    }

    func test03Detail() {
        launch()
        waitForFavorites()
        tap(app.buttons["elevatorRow.broken"], "broken favorite")
        require(app.buttons["detailMap"], "detail map", timeout: 20)
        // Map tiles and the Look Around preview need a moment.
        sleep(4)
        snap("04-detail")
    }

    func test04Nearby() {
        launch(["-HissiDemoOpen", "nearby"])
        allowLocation()
        require(app.descendants(matching: .any)["nearbyHeader"], "nearby stations", timeout: 30)
        require(app.buttons.matching(identifier: "nearbyStation.broken").firstMatch, "nearby rows")
        dismissKeyboard()
        snap("05-nearby")
    }

    func test05Widgets() throws {
        try requireHomeScreen()
        launch()
        waitForFavorites()
        pressHome()
        // Both in the medium size; added in reverse, each new widget lands
        // at the top.
        try addWidget(named: System.nearbyWidget, swipes: 1)
        try addWidget(named: System.statusWidget, swipes: 1)
        allowSystemPrompt()
        tap(springboard.buttons.matching(NSPredicate(format: "label IN %@", System.done)).firstMatch, "home screen done")
        // The widgets fetch on their own; give the timelines a moment.
        sleep(6)
        snap("03-widgets")
    }

    func test06Search() {
        launch()
        waitForFavorites()
        search("Alexanderplatz")
        let banner = app.descendants(matching: .any)["statusRefreshBanner"]
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: banner)
        _ = XCTWaiter.wait(for: [gone], timeout: 30)
        require(app.buttons.matching(identifier: "elevatorRow.working").firstMatch, "search results")
        snap("06-search")
    }

    func test07LargeText() {
        launch(["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"])
        waitForFavorites()
        snap("07-large-text")
    }

    // MARK: - Device capabilities

    private var isPhone: Bool {
        #if targetEnvironment(macCatalyst)
        false
        #else
        UIDevice.current.userInterfaceIdiom == .phone
        #endif
    }

    // The Lock Screen and the widget gallery are scripted on the iPhone
    // only: the Mac has neither, the iPad's Lock Screen comes out black.
    private func requireLiveActivities() throws {
        guard isPhone else { throw XCTSkip("Lock Screen shot is iPhone-only") }
    }

    private func requireHomeScreen() throws {
        guard isPhone else { throw XCTSkip("home screen shot is iPhone-only") }
    }

    // MARK: - System UI labels (de/en)

    private enum System {
        static let allowLocation = ["Beim Verwenden der App erlauben", "Allow While Using App"]
        static let allow = ["Erlauben", "Allow"]
        static let edit = ["Bearbeiten", "Edit"]
        static let addWidget = ["Widget hinzufügen", "Add Widget"]
        static let done = ["Fertig", "Done"]
        static let statusWidget = ["Aufzug-Status", "Elevator status"]
        static let nearbyWidget = ["In der Nähe", "Nearby"]
    }

    // MARK: - Steps

    private func launch(_ arguments: [String] = []) {
        app.launchArguments = ["-HissiDemoData", "YES", "-HissiDemoFavorites", "YES"] + arguments
        app.launch()
    }

    private func waitForFavorites() {
        require(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "elevatorRow.")).firstMatch, "favorites")
        // Let the on-appear refresh land (instant in demo mode) and the
        // list settle.
        sleep(1)
    }

    // A toolbar button — or, where a narrow bar moved it into the overflow
    // menu, the same action from there.
    private func toolbarButton(_ identifier: String) -> XCUIElement {
        let button = app.buttons[identifier]
        if button.waitForExistence(timeout: 3), button.isHittable { return button }
        let overflow = app.buttons["TopOverflowBarButtonItem"]
        if overflow.exists { overflow.tap() }
        return button
    }

    private func search(_ term: String) {
        let field = app.searchFields.firstMatch
        // iPhone Duo's outer display collapses the field into a search
        // button in the side bar; the field appears once it is tapped.
        if !field.waitForExistence(timeout: 5) {
            app.buttons.matching(NSPredicate(format: "label IN %@", ["Suchen", "Search", "Station finden", "Find Station"])).firstMatch.tap()
        }
        tap(field, "search field")
        // Focus, not the keyboard: the iPad simulator may have a hardware
        // keyboard attached, in which case none is drawn.
        let focused = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasKeyboardFocus == true"), object: field)
        if XCTWaiter.wait(for: [focused], timeout: 5) != .completed { field.tap() }
        field.typeText(term + "\n")
    }

    // The keyboard would cover half the shot; a drag towards it dismisses
    // it interactively (the return key is disabled on an empty query).
    private func dismissKeyboard() {
        guard app.keyboards.firstMatch.waitForExistence(timeout: 2) else { return }
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9))
        from.press(forDuration: 0.1, thenDragTo: to)
        sleep(1)
        if app.keyboards.firstMatch.exists {
            // Fallback: a swipe on the scroll view itself.
            let scroll = app.collectionViews.count > 0 ? app.collectionViews.firstMatch : app.scrollViews.firstMatch
            if scroll.exists { scroll.swipeDown(); sleep(1) }
        }
    }

    // The location prompt comes from SpringBoard (absent once granted).
    private func allowLocation() {
        let alert = springboard.alerts.firstMatch
        guard alert.waitForExistence(timeout: 8) else { return }
        let allow = alert.buttons.matching(NSPredicate(format: "label IN %@", System.allowLocation)).firstMatch
        if allow.exists { allow.tap() } else { alert.buttons.element(boundBy: alert.buttons.count - 1).tap() }
    }

    // Home screen edit mode → widget gallery → Hissi → the kind's first
    // page (small) → `swipes` sizes further → add.
    private func addWidget(named names: [String], swipes: Int) throws {
        // A location prompt for the previous widget may still be up.
        allowSystemPrompt()
        // The location prompt can drop the gallery back to its search
        // results — then it is still open, already searched for Hissi.
        let hissi = springboard.cells.matching(NSPredicate(format: "label CONTAINS %@", "Hissi")).firstMatch
        if !hissi.exists {
            let editButton = springboard.buttons.matching(NSPredicate(format: "label IN %@", System.edit)).firstMatch
            if !editButton.waitForExistence(timeout: 2) {
                springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)).press(forDuration: 1.5)
            }
            // iPhone Duo's simulator offers no editable home screen.
            guard editButton.waitForExistence(timeout: 10) else {
                throw XCTSkip("the home screen can't be edited on this simulator")
            }
            editButton.tap()
            tap(springboard.buttons.matching(NSPredicate(format: "label IN %@", System.addWidget)).firstMatch, "add widget menu")
            let searchField = springboard.searchFields.firstMatch
            tap(searchField, "widget search")
            searchField.typeText("Hissi")
        }
        tap(hissi, "Hissi in the widget gallery")
        let title = springboard.staticTexts.matching(NSPredicate(format: "label IN %@", names)).firstMatch
        let pager = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.45))
        let previous = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.45))
        // The nearby widget's preview already asks for the location.
        allowSystemPrompt()
        for _ in 0..<8 where !(title.exists && title.isHittable) {
            if hissi.exists, hissi.isHittable { hissi.tap(); sleep(1); continue }
            pager.press(forDuration: 0.05, thenDragTo: previous)
            sleep(1)
            allowSystemPrompt(timeout: 1)
        }
        require(title, "widget \(names[0])")
        for _ in 0..<swipes {
            pager.press(forDuration: 0.05, thenDragTo: previous)
            sleep(1)
            allowSystemPrompt(timeout: 1)
        }
        // The button's label leads with an icon glyph (" Add Widget").
        let add = springboard.buttons.matching(NSPredicate(
            format: "label ENDSWITH %@ OR label ENDSWITH %@", System.addWidget[0], System.addWidget[1]
        )).firstMatch
        // A location prompt landing at the same moment swallows the tap;
        // the button stays up until the add went through.
        tap(add, "add widget button")
        allowSystemPrompt()
        for _ in 0..<2 where add.exists && add.isHittable {
            add.tap()
            allowSystemPrompt()
        }
        sleep(1)
    }

    // The home button — absent on the Mac, where the tests that need it
    // are skipped anyway.
    private func pressHome() {
        #if !targetEnvironment(macCatalyst)
        XCUIDevice.shared.press(.home)
        #endif
    }

    // "Erlauben" on a SpringBoard prompt, if one shows up.
    private func allowSystemPrompt(timeout: TimeInterval = 5) {
        let allow = springboard.buttons.matching(NSPredicate(format: "label IN %@", System.allow)).firstMatch
        if allow.waitForExistence(timeout: timeout) { allow.tap(); sleep(1) }
    }

    // The Lock Screen with the running Live Activity. Locking goes through a
    // private selector that exists on the simulator; false where the shot
    // can't be taken (no selector, or the lock leaves the app in front, as
    // on iPhone Duo's simulator).
    @discardableResult
    private func lockScreenShot(_ name: String) -> Bool {
        let lock = Selector(("pressLockButton"))
        guard XCUIDevice.shared.responds(to: lock) else { return false }
        XCUIDevice.shared.perform(lock)
        sleep(2)
        // Wakes the display onto the Lock Screen.
        pressHome()
        let activity = springboard.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Hissi:")).firstMatch
        // The activity can take a while to land on the Lock Screen.
        if !activity.waitForExistence(timeout: 30) {
            if app.buttons["liveStatusEnd"].isHittable { return false }
            require(activity, "Live Activity on the Lock Screen")
        }
        // The first Live Activity of an app asks for permission below it;
        // the display dims meanwhile. A second home press would unlock, so
        // lock again and wake once more.
        allowSystemPrompt()
        XCUIDevice.shared.perform(lock)
        sleep(2)
        pressHome()
        require(activity, "Live Activity after waking")
        // The wallpaper fades in after the activity.
        sleep(4)
        snap(name)
        pressHome()
        return true
    }

    // MARK: - Capture

    private func tap(_ element: XCUIElement, _ what: String, timeout: TimeInterval = 10) {
        require(element, what, timeout: timeout)
        element.tap()
    }

    // Waits for an element the flow depends on; on a miss it leaves the
    // element hierarchy and a screenshot next to the output, then fails.
    private func require(_ element: XCUIElement, _ what: String, timeout: TimeInterval = 10) {
        if element.waitForExistence(timeout: timeout) { return }
        if let outputDirectory {
            try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            for (host, hierarchy) in [("app", app.debugDescription), ("springboard", springboard.debugDescription)] {
                try? hierarchy.write(
                    to: outputDirectory.appendingPathComponent("failure-\(what)-\(host).txt"), atomically: true, encoding: .utf8
                )
            }
        }
        snap("failure-\(what)")
        XCTFail("\(what) did not appear within \(Int(timeout)) s")
    }

    private func snap(_ name: String) {
        #if targetEnvironment(macCatalyst)
        // The Mac shot is the window alone; the script centres it on a
        // canvas of the App Store size.
        let screenshot = app.windows.firstMatch.screenshot()
        #else
        let screenshot = XCUIScreen.main.screenshot()
        #endif
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let outputDirectory else { return }
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        try? screenshot.pngRepresentation.write(to: outputDirectory.appendingPathComponent("\(name).png"))
    }
}
