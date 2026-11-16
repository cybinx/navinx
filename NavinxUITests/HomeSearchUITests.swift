import XCTest

/// Walks Home and Search against a real server, saving a screenshot at each step. It plays music, so
/// it writes now-playing and play counts as that login: use the test account `api` (`CLAUDE.md`).
/// Skipped without `TEST_RUNNER_NAVINX_LIVE`; see `README.md`.
final class HomeSearchUITests: XCTestCase {
    private struct Login: Decodable { let url: String; let username: String; let password: String }

    private var shots: URL?
    private var prefix = ""

    @MainActor
    func testHomeAndSearch() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        guard let path = env["NAVINX_LIVE"] else { throw XCTSkip("No login file (TEST_RUNNER_NAVINX_LIVE)") }
        let login = try JSONDecoder().decode(Login.self, from: Data(contentsOf: URL(filePath: path)))
        if let dir = env["NAVINX_SHOTS"] {
            shots = URL(filePath: dir)
            try? FileManager.default.createDirectory(at: shots!, withIntermediateDirectories: true)
        }
        prefix = env["NAVINX_SHOT_PREFIX"] ?? ""

        let app = XCUIApplication()
        app.launchArguments = ["-UITestReset"]
        app.launch()
        signIn(app, login)

        // Home: the top grid and its rows.
        XCTAssert(app.staticTexts["Liked Songs"].waitForExistence(timeout: 20))
        XCTAssert(app.buttons["settingsGear"].exists)
        XCTAssert(app.buttons["homeHistory"].exists)
        answerSavePassword(app)
        XCTAssert(app.staticTexts["Jump back in"].waitForExistence(timeout: 15))
        sleep(4)
        shot("01-home")
        app.swipeUp()
        sleep(2)
        shot("02-home-scrolled")
        app.swipeUp()
        sleep(2)
        shot("03-home-scrolled-more")
        app.swipeUp()
        sleep(2)
        shot("04-home-end")
        app.swipeDown()
        app.swipeDown()
        app.swipeDown()
        sleep(1)

        // Home's chips.
        chip(app, "Made For You").tap()
        XCTAssert(app.staticTexts["Made For You"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Jump back in"].exists)
        sleep(2)
        shot("05-home-made-for-you")
        // The test account has no playlists, so this chip shows an empty page (as Flutter's does).
        chip(app, "Playlists").tap()
        sleep(2)
        shot("06-home-playlists")
        XCTAssertFalse(app.staticTexts["Jump back in"].exists)
        chip(app, "Music").tap()
        sleep(2)
        shot("07-home-music")
        chip(app, "All").tap()

        // A quick-access tile opens its page, and so does History.
        app.buttons["homeHistory"].tap()
        XCTAssert(app.staticTexts["Listening History"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tapIfThere()
        sleep(1)

        // Search: the prompt, on an empty field with no recent searches (D210).
        try searchTab(app).tap()
        XCTAssert(app.staticTexts["Search your library"].waitForExistence(timeout: 5))
        XCTAssert(app.staticTexts["Songs, albums, artists and playlists"].exists)
        XCTAssertFalse(app.staticTexts["Browse all"].exists)
        sleep(1)
        shot("08-search-prompt")
        let field = app.searchFields.firstMatch
        XCTAssert(field.waitForExistence(timeout: 5))

        // A typed search, live.
        retype("Cochise", in: field, app)
        XCTAssert(app.staticTexts["Top result"].waitForExistence(timeout: 15))
        dismissKeyboard(app)
        sleep(3)
        shot("09-search-results")
        app.swipeUp()
        sleep(2)
        shot("10-search-results-scrolled")
        app.swipeDown()
        sleep(1)

        // The filters.
        chip(app, "Songs").tap()
        XCTAssert(app.staticTexts["Songs"].waitForExistence(timeout: 5))
        sleep(1)
        shot("11-search-songs")
        chip(app, "Albums").tap()
        sleep(2)
        shot("12-search-albums")
        chip(app, "All").tap()
        sleep(1)

        // A typed search with no results, and the recent searches left behind.
        retype("zzqqxxnothing", in: field, app)
        XCTAssert(app.staticTexts["No results found for \"zzqqxxnothing\""].waitForExistence(timeout: 10))
        sleep(1)
        shot("13-search-no-results")
        retype("", in: field, app)
        dismissKeyboard(app)
        XCTAssert(app.staticTexts["Recent Searches"].waitForExistence(timeout: 5))
        sleep(1)
        shot("14-search-recents")

        // A song from Search starts radio: more songs join the queue.
        retype("Cochise", in: field, app)
        XCTAssert(app.staticTexts["Top result"].waitForExistence(timeout: 15))
        dismissKeyboard(app)
        chip(app, "Songs").tap()
        sleep(1)
        let options = app.buttons.matching(NSPredicate(format: "label == 'Song options'")).firstMatch
        XCTAssert(options.waitForExistence(timeout: 5))
        let row = options.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .withOffset(CGVector(dx: -200, dy: 0))
        row.tap()
        sleep(5)
        shot("15-search-playing")

        // Next moves on to a song radio added: the song was queued alone.
        let title = app.staticTexts["playerBarTitle"]
        XCTAssert(title.waitForExistence(timeout: 5))
        let first = title.label
        let next = app.buttons.matching(NSPredicate(format: "label == 'Next'")).allElementsBoundByIndex.first { $0.isHittable }
        XCTAssertNotNil(next)
        next?.tap()
        sleep(4)
        XCTAssertNotEqual(title.label, first, "radio added nothing to play next")
        shot("16-search-radio-next")
    }

    /// The tab bar's Search button, once it can be tapped (a tab bar button can resolve to a copy
    /// with no position, and "Save Password?" can be in the way).
    @MainActor
    private func searchTab(_ app: XCUIApplication) throws -> XCUIElement {
        for _ in 0..<20 {
            answerSavePassword(app)
            let buttons = app.buttons.matching(NSPredicate(format: "label == 'Search'")).allElementsBoundByIndex
            if let tab = buttons.first(where: { $0.isHittable }) { return tab }
            sleep(1)
        }
        return try XCTUnwrap(nil as XCUIElement?, "No hittable Search tab")
    }

    /// Replaces what's in the search field.
    @MainActor
    private func retype(_ text: String, in field: XCUIElement, _ app: XCUIApplication) {
        field.tap()
        let clear = app.buttons.matching(NSPredicate(format: "label == 'Clear text'")).allElementsBoundByIndex
        clear.first { $0.isHittable }?.tap()
        if !text.isEmpty { field.typeText(text) }
    }

    /// Dragging the results away closes the keyboard without emptying the field.
    @MainActor
    private func dismissKeyboard(_ app: XCUIApplication) {
        guard app.keyboards.firstMatch.exists else { return }
        app.keyboards.buttons["Search"].firstMatch.tapIfThere()
        app.keyboards.buttons["search"].firstMatch.tapIfThere()
        sleep(1)
    }

    @MainActor
    private func signIn(_ app: XCUIApplication, _ login: Login) {
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
        answerSavePassword(app, wait: 8)
    }

    /// iOS offers to save the password after a login, sometimes late; answer "Not Now".
    @MainActor
    private func answerSavePassword(_ app: XCUIApplication, wait: TimeInterval = 1) {
        let notNow = app.buttons["Not Now"]
        if notNow.waitForExistence(timeout: wait) { notNow.tap() }
    }

    @MainActor
    private func chip(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        answerSavePassword(app)
        let query = app.buttons.matching(NSPredicate(format: "label == %@", title))
        return query.allElementsBoundByIndex.first { $0.isHittable } ?? query.firstMatch
    }

    private func shot(_ name: String) {
        guard let shots else { return }
        let file = shots.appending(path: "\(prefix)\(name).png")
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: file)
    }
}

private extension XCUIElement {
    func tapIfThere() {
        if exists, isHittable { tap() }
    }
}
