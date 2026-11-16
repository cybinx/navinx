import XCTest

/// The server's own tab and Search's section (C27, D106), flagged and unflagged. Every identifier is
/// the server's id with `hub-` in front; no text of the server's is named here.
///
/// Needs `TEST_RUNNER_NAVINX_LIVE` (a login file outside the repo) and `TEST_RUNNER_NAVINX_HUB`:
/// - `flow`: the login's `url` is the dev front (`Server/panel/dev/front.py --users api`): the whole
///   flow against the fakes (a link checked, previewed, added and done; the second mode's search, a
///   Request pill, a requests sheet; Search's section). Writes nothing to the real server.
/// - `unflagged`: an account without the tab (the dev front with `--users none`, or the real server
///   as `test`): four tabs, and no section in Search.
/// - `shown`: the real server as an allowed account: the third tab appears. **Presses nothing in it**
///   (on the real server a request really downloads).
/// - `accounts`: leaves the simulator ready for review (D110): signs in `TEST_RUNNER_NAVINX_LIVE`, then
///   adds `TEST_RUNNER_NAVINX_SECOND` through Settings → Server → Add Server, which stays active.
/// `TEST_RUNNER_NAVINX_SHOTS` (optional) saves pictures for the agent's own checks.
final class HubUITests: XCTestCase {
    private struct Login: Decodable { let url: String; let username: String; let password: String }

    private var app: XCUIApplication!
    private var shots: URL?
    private var prefix = ""

    @MainActor
    func testHub() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        guard let path = env["NAVINX_LIVE"] else { throw XCTSkip("No login file (TEST_RUNNER_NAVINX_LIVE)") }
        guard let mode = env["NAVINX_HUB"] else { throw XCTSkip("No mode (TEST_RUNNER_NAVINX_HUB)") }
        shots = env["NAVINX_SHOTS"].map { URL(filePath: $0) }
        prefix = env["NAVINX_SHOT_PREFIX"] ?? ""
        try signIn(JSONDecoder().decode(Login.self, from: Data(contentsOf: URL(filePath: path))))

        switch mode {
        case "flow": try flow()
        case "unflagged": try unflagged()
        case "shown":
            let tab = try XCTUnwrap(waitForThirdTab(), "no third tab for an allowed account")
            shot("shown-home")
            XCTAssertFalse(["Home", "New", "Library", "Search"].contains(tab))
        case "accounts":
            let second = try XCTUnwrap(env["NAVINX_SECOND"], "no second login (TEST_RUNNER_NAVINX_SECOND)")
            try addServer(JSONDecoder().decode(Login.self, from: Data(contentsOf: URL(filePath: second))))
        default: XCTFail("unknown mode \(mode)")
        }
    }

    // MARK: Flagged, against the dev front

    @MainActor
    private func flow() throws {
        let tab = try XCTUnwrap(waitForThirdTab(), "no third tab")
        XCTAssert(app.selectTab(tab))
        // The server keeps each account's state, so a run may find the second mode open.
        let link = app.textFields["hub-link"]
        let modes = app.segmentedControls["hub-mode"]
        XCTAssert(modes.waitForExistence(timeout: 10), "no mode switch")
        if !link.waitForExistence(timeout: 3) { modes.buttons.element(boundBy: 0).tap() }
        XCTAssert(link.waitForExistence(timeout: 10), "the first mode's field")
        if app.buttons["hub-another"].exists { app.buttons["hub-another"].tap() }
        if app.buttons["hub-startOver"].exists { app.buttons["hub-startOver"].tap() }
        if app.buttons["hub-cancel"].exists { app.buttons["hub-cancel"].tap() }
        sleep(1)
        XCTAssert(app.buttons["hub-link-paste"].exists, "the system's Paste button")
        XCTAssertFalse(app.buttons["hub-check"].isEnabled, "Check needs a link")
        shot("01-idle")

        link.tap()
        if let old = link.value as? String, old.hasPrefix("http") {
            link.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count))
        }
        link.typeText("https://example.com/watch?v=c27")
        app.buttons["hub-check"].tap()
        let add = app.buttons["hub-add"]
        XCTAssert(add.waitForExistence(timeout: 15), "no preview")
        XCTAssert(app.descendants(matching: .any)["hub-artist"].exists)
        shot("02-preview")
        add.tap()
        XCTAssert(app.descendants(matching: .any)["hub-job"].waitForExistence(timeout: 10), "no progress")
        shot("03-job")
        XCTAssert(app.buttons["hub-another"].waitForExistence(timeout: 20), "never done")
        XCTAssert(app.descendants(matching: .any)["hub-section-session"].exists, "the session list")
        shot("04-done")
        app.buttons["hub-another"].tap()
        XCTAssert(app.buttons["hub-check"].waitForExistence(timeout: 5))
        XCTAssertFalse((app.textFields["hub-link"].value as? String ?? "").contains("c27"), "Add another empties the field")

        // The second mode.
        XCTAssert(modes.waitForExistence(timeout: 5))
        modes.buttons.element(boundBy: 1).tap()
        let query = app.textFields["hub-q"]
        XCTAssert(query.waitForExistence(timeout: 10), "the second mode's field")
        XCTAssert(app.descendants(matching: .any)["hub-section-requests"].waitForExistence(timeout: 15), "no requests")
        shot("05-second-mode")
        query.tap()
        query.typeText("radiohead\n")
        let pills = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'hub-request-'"))
        XCTAssert(pills.firstMatch.waitForExistence(timeout: 15), "no results")
        shot("06-results")
        // The dev front's fake has one album here that can be requested.
        let pill = app.buttons["hub-request-fb-inrainbows"]
        XCTAssert(pill.waitForExistence(timeout: 5), "the fake's requestable album")
        let id = pill.identifier
        let before = pill.label
        pill.tap()
        let after = app.buttons[id]
        let changed = NSPredicate { _, _ in after.exists && after.label != before }
        wait(for: [XCTNSPredicateExpectation(predicate: changed, object: nil)], timeout: 15)
        shot("07-requested")

        // A request's sheet.
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'hub-requestRow-'")).firstMatch
        XCTAssert(row.waitForExistence(timeout: 10))
        for _ in 0..<4 where !row.isHittable { app.swipeUp() }
        row.tap()
        XCTAssert(app.descendants(matching: .any)["hub-details"].waitForExistence(timeout: 10), "no sheet")
        shot("08-sheet")
        // Drag the sheet down by its top edge.
        let details = app.descendants(matching: .any)["hub-details"]
        let top = details.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0)).withOffset(CGVector(dx: 0, dy: -30))
        top.press(forDuration: 0.1, thenDragTo: top.withOffset(CGVector(dx: 0, dy: 700)))
        XCTAssert(details.waitForNonExistence(timeout: 5), "the sheet didn't close")

        // Search's section.
        XCTAssert(app.selectTab("Search"))
        let field = app.searchFields.firstMatch
        XCTAssert(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("radiohead\n")
        let section = app.descendants(matching: .any)["hub-section-find"]
        XCTAssert(section.waitForExistence(timeout: 20), "no section in Search")
        for _ in 0..<6 where !app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'hub-request-'")).firstMatch.isHittable {
            app.swipeUp()
        }
        shot("09-search")
    }

    // MARK: Unflagged

    @MainActor
    private func unflagged() throws {
        // The probe answers within seconds; give it time to (not) add a tab.
        sleep(6)
        XCTAssertEqual(tabLabels, ["Home", "New", "Library", "Search"])
        shot("unflagged-home")
        XCTAssert(app.selectTab("Search"))
        let field = app.searchFields.firstMatch
        XCTAssert(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("radiohead\n")
        sleep(4)
        XCTAssertFalse(app.descendants(matching: .any)["hub-section-find"].exists, "a section for an account without the tab")
        XCTAssertEqual(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'hub-'")).count, 0)
        shot("unflagged-search")
    }

    // MARK: Helpers

    @MainActor
    private func signIn(_ login: Login) throws {
        app = XCUIApplication()
        app.launchArguments = ["-UITestReset"]
        app.launch()
        XCTAssert(app.buttons["connect"].waitForExistence(timeout: 10))
        for (field, text) in [
            (app.textFields["Server URL"], login.url),
            (app.textFields["Username"], login.username),
            (app.secureTextFields["Password"], login.password + "\n"),
        ] {
            XCTAssert(field.waitForExistence(timeout: 5))
            field.tap()
            field.typeText(text)
        }
        let notNow = app.buttons["Not Now"]
        if notNow.waitForExistence(timeout: 12) {
            notNow.tap()
            sleep(1)
        }
    }

    /// Settings → Server → Switch → Add Server, signing `login` in as a second saved server.
    @MainActor
    private func addServer(_ login: Login) throws {
        let gear = app.buttons["settingsGear"]
        XCTAssert(gear.waitForExistence(timeout: 15))
        let serverTab = app.buttons["settingsTab-Server"]
        for _ in 0..<3 where !serverTab.exists {
            if app.buttons["Not Now"].exists { app.buttons["Not Now"].tap() }
            gear.tap()
            _ = serverTab.waitForExistence(timeout: 4)
        }
        serverTab.tap()
        let add = app.buttons["addServer"]
        for _ in 0..<3 where !add.exists {
            if app.buttons["Not Now"].exists { app.buttons["Not Now"].tap() }
            app.buttons["settingsSwitchServer"].tap()
            _ = add.waitForExistence(timeout: 4)
        }
        add.tap()
        XCTAssert(app.buttons["connectAndSave"].waitForExistence(timeout: 5))
        sleep(1)
        for (field, text) in [
            (app.textFields["Server URL *"], login.url),
            (app.textFields["Username *"], login.username),
            (app.secureTextFields["Password *"], login.password + "\n"),
        ] {
            XCTAssert(field.waitForExistence(timeout: 5))
            for _ in 0..<3 {
                field.tap()
                if app.keyboards.firstMatch.waitForExistence(timeout: 3) { break }
                if app.buttons["Not Now"].exists { app.buttons["Not Now"].tap() }
            }
            field.typeText(text)
        }
        XCTAssert(app.descendants(matching: .any)["toast"].waitForExistence(timeout: 20), "the second server didn't connect")
        let notNow = app.buttons["Not Now"]
        if notNow.waitForExistence(timeout: 10) { notNow.tap() }
        sleep(3)
    }

    /// The tabs' labels in order: the tab bar's, or on the iPhone Duo's cover display (whose tabs stand
    /// in a side rail XCUITest doesn't see as a tab bar) the buttons in Home's column, top to bottom.
    @MainActor
    private var tabLabels: [String] {
        let bar = app.tabBarLabels
        if !bar.isEmpty { return bar }
        let home = app.buttons.matching(NSPredicate(format: "label == 'Home'")).allElementsBoundByIndex
            .first { $0.isHittable && $0.frame.width < 140 }
        guard let column = home?.frame else { return [] }
        let rail = app.buttons.allElementsBoundByIndex.filter {
            $0.frame.width > 0 && abs($0.frame.midX - column.midX) < 4 && abs($0.frame.width - column.width) < 4
        }
        return rail.sorted { $0.frame.minY < $1.frame.minY }.map(\.label)
    }

    /// The third tab's label once the server has sent it, else nil.
    @MainActor
    private func waitForThirdTab(timeout: TimeInterval = 20) -> String? {
        let deadline = Date.now.addingTimeInterval(timeout)
        repeat {
            let labels = tabLabels
            if labels.count == 5 { return labels[2] }
            if app.buttons["Not Now"].exists { app.buttons["Not Now"].tap() }
            sleep(1)
        } while Date.now < deadline
        return nil
    }

    private func shot(_ name: String) {
        guard let shots else { return }
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: shots.appending(path: "\(prefix)\(name).png"))
    }
}
