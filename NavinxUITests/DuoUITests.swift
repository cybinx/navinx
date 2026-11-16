import XCTest

/// The iPhone Duo (C17, D78; C30, D122): the mini-player's fold on scroll (a circle above the side rail, or
/// a small capsule in the cover display's landscape), and now playing beside the app on the inner display,
/// open and half open, with the full-screen player when closed (faked there). Live, as the test account
/// `api`; plays nothing itself (the mini-player's song is the one the app keeps, D81). Run it on the Duo with
/// `TEST_RUNNER_NAVINX_DUO=1`; it skips elsewhere. Needs `TEST_RUNNER_NAVINX_LIVE`, and
/// `TEST_RUNNER_NAVINX_SHOTS` for pictures (on the inner display XCUITest's come out black: take them with
/// `simctl io <udid> screenshot --display=3` alongside). Whichever display the simulator's posture puts the
/// app on is tested: the inner display is 951 pt wide, the cover display 466 (or 678 in landscape).
final class DuoUITests: XCTestCase {
    private struct Login: Decodable { let url: String; let username: String; let password: String }

    private var app: XCUIApplication!
    private var shots: URL?
    private var login: Login!

    @MainActor
    func testPlayerBarFolds() throws {
        try start()
        // Scrolling down folds the mini-player into the cover's circle; a tap brings it back. (The window's
        // swipe: the app's goes by the device's orientation, which the Duo doesn't change.)
        launch(["-UITestReset"])
        signIn()
        let window = app.windows.firstMatch
        let isInner = window.frame.width >= 800
        XCTAssert(app.buttons["duoPlayerBarCircle"].exists == false, "folded at the top")
        window.swipeUp(velocity: .fast)
        window.swipeUp(velocity: .fast)
        let circle = app.buttons["duoPlayerBarCircle"]
        XCTAssert(circle.waitForExistence(timeout: 5), "two flicks down didn't fold the mini-player")
        shot("1-folded")
        // The capsule runs into the circle (C26, C30), so it's gone once the drop has landed.
        XCTAssert(app.staticTexts["playerBarTitle"].waitForNonExistence(timeout: 3), "the capsule goes while the circle shows")
        // (The circle's place above the rail is checked on pictures: XCUITest reports the inner display's
        // frames in another space, `docs/gotchas.md`.)
        circle.tap()
        XCTAssert(app.staticTexts["playerBarTitle"].waitForExistence(timeout: 5), "the circle didn't bring the mini-player back")
        XCTAssertFalse(circle.exists)
        shot("2-unfolded")
        // The top of the page brings it back too.
        window.swipeUp(velocity: .fast)
        window.swipeUp(velocity: .fast)
        XCTAssert(circle.waitForExistence(timeout: 5))
        for _ in 0..<8 { window.swipeDown(velocity: .fast) }
        XCTAssert(app.staticTexts["playerBarTitle"].waitForExistence(timeout: 6), "the top of the page didn't bring it back")

        // Landscape on the cover display: it shrinks to the small capsule, and a tap makes it big again.
        guard !isInner else { return }
        launch(["-UITestOrientation", "left"])
        XCTAssert(app.staticTexts["playerBarTitle"].waitForExistence(timeout: 10))
        sleep(3)
        app.windows.firstMatch.swipeUp()
        app.windows.firstMatch.swipeUp()
        let compact = app.descendants(matching: .any)["duoPlayerBarCompact"]
        XCTAssert(compact.waitForExistence(timeout: 5), "landscape didn't shrink the mini-player")
        shot("3-landscape-shrunk")
        // The capsule's middle (the play button is at its end).
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.40, dy: 0.90)).tap()
        XCTAssert(app.buttons["Next"].firstMatch.waitForExistence(timeout: 5), "the tap didn't make it big again")
        shot("4-landscape-big")
        launch(["-UITestOrientation", "portrait"])
    }

    /// Now playing beside the app (C30 bug 17): on the inner display, open or half open, the player takes
    /// the half right of the hinge and the app keeps the other with its tabs and no mini-player, still
    /// usable; closed (the cover display, faked here on the inner one) it's the full-screen player.
    @MainActor
    func testNowPlayingBesideTheApp() throws {
        try start()
        launch([])
        signInIfAsked()
        let window = app.windows.firstMatch.frame
        let isInner = window.width >= 800
        for hinge in ["open", "partial", "closed"] {
            launch(["-UITestHinge", hinge])
            let bar = app.staticTexts["playerBarTitle"]
            XCTAssert(bar.waitForExistence(timeout: 20), "no mini-player (\(hinge))")
            sleep(2)
            bar.tap()
            let close = app.buttons["nowPlayingClose"]
            XCTAssert(close.waitForExistence(timeout: 5), "now playing didn't open (\(hinge))")
            sleep(1)
            if isInner, hinge != "closed" {
                XCTAssertGreaterThanOrEqual(close.frame.minX, window.midX, "now playing should be right of the hinge (\(hinge))")
                XCTAssertFalse(app.staticTexts["playerBarTitle"].exists, "no mini-player beside now playing (\(hinge))")
                // The app is usable beside it: another tab, the player still open.
                let new = app.hittableTab("New")
                XCTAssertNotNil(new, "the tabs should be beside now playing (\(hinge))")
                if let new {
                    XCTAssertLessThan(new.frame.maxX, window.midX, "the tabs should be left of the hinge")
                    new.tap()
                    sleep(1)
                    XCTAssertNotNil(app.hittableTab("Home"), "the tabs should still be there")
                    XCTAssert(close.exists, "a tab beside it shouldn't close now playing")
                    app.hittableTab("Home")?.tap()
                }
            } else {
                XCTAssertLessThan(close.frame.minX, window.midX, "now playing should fill the screen (\(hinge))")
                XCTAssertNil(app.hittableTab("New"), "the full-screen player covers the tabs (\(hinge))")
            }
            close.tap()
            XCTAssert(close.waitForNonExistence(timeout: 5), "the chevron didn't close now playing (\(hinge))")
            XCTAssert(app.staticTexts["playerBarTitle"].waitForExistence(timeout: 5), "the mini-player should be back (\(hinge))")
        }
    }

    /// Builders C's and A's C30 work on the Duo's rail: Settings hides the rail and the folded circle, and both
    /// come back on leaving (bugs 3 and 4, D124). (The Library's search, bug 8, left with D210.)
    /// On the inner display with the player closed the rail and the strip are as on the cover display.
    @MainActor
    func testSettingsBesideTheRail() throws {
        try start()
        launch([])
        signInIfAsked()
        let window = app.windows.firstMatch
        XCTAssert(app.staticTexts["playerBarTitle"].waitForExistence(timeout: 20), "no mini-player")
        XCTAssert(app.selectTab("Home"))
        sleep(1)
        window.swipeUp(velocity: .fast)
        window.swipeUp(velocity: .fast)
        let circle = app.buttons["duoPlayerBarCircle"]
        XCTAssert(circle.waitForExistence(timeout: 5), "two flicks down didn't fold the mini-player")
        app.buttons["settingsGear"].firstMatch.tap()
        XCTAssert(app.buttons["settingsTab-Server"].waitForExistence(timeout: 8), "Settings didn't open")
        sleep(2)
        XCTAssertFalse(circle.exists, "Settings: the folded circle should be hidden")
        XCTAssertNil(app.hittableTab("New"), "Settings: the rail should be gone")
        app.buttons["BackButton"].firstMatch.tap()
        // Back on Home the mini-player shows again: the circle, or the full capsule (Settings arriving at its
        // top unfolds it, as a push does on a phone: the open item of `ChromeUITests/testBarAcrossPushAndPop`).
        let bar = app.staticTexts["playerBarTitle"]
        XCTAssert(circle.waitForExistence(timeout: 5) || bar.exists, "back on Home: the mini-player should be back")
        XCTAssertNotNil(app.hittableTab("New"), "back on Home: the rail should be back")
        if circle.exists { circle.tap() }
        XCTAssert(bar.waitForExistence(timeout: 5))
    }

    @MainActor
    private func start() throws {
        continueAfterFailure = true
        let env = ProcessInfo.processInfo.environment
        guard env["NAVINX_DUO"] != nil else { throw XCTSkip("Not the iPhone Duo (TEST_RUNNER_NAVINX_DUO)") }
        guard let path = env["NAVINX_LIVE"] else { throw XCTSkip("No login file (TEST_RUNNER_NAVINX_LIVE)") }
        login = try JSONDecoder().decode(Login.self, from: Data(contentsOf: URL(filePath: path)))
        if let dir = env["NAVINX_SHOTS"] {
            shots = URL(filePath: dir)
            try? FileManager.default.createDirectory(at: shots!, withIntermediateDirectories: true)
        }
    }

    @MainActor
    private func launch(_ arguments: [String]) {
        if app != nil, app.state != .notRunning { app.terminate() }
        app = XCUIApplication()
        app.launchArguments = arguments
        app.launch()
    }

    /// Signs in if the app is at the login screen (a simulator another run left signed out).
    @MainActor
    private func signInIfAsked() {
        if app.buttons["connect"].waitForExistence(timeout: 5) { signIn() }
    }

    @MainActor
    private func signIn() {
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
        if notNow.waitForExistence(timeout: 12) { notNow.tap() }
        XCTAssert(app.staticTexts["Liked Songs"].waitForExistence(timeout: 20))
        sleep(4)
        if notNow.exists { notNow.tap() }
    }

    @MainActor
    private func shot(_ name: String) {
        guard let shots else { return }
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: shots.appending(path: "duo-\(name).png"))
    }
}
