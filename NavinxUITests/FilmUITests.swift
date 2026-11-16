import XCTest

/// Steps for filming C26's animations with `simctl io <udid> recordVideo` alongside (D86): now playing's
/// open and close on a phone, and the Duo's melt. Each step writes the time to `NAVINX_MARKS`, so the
/// frames can be found in the film. They take no pictures and check little: they're for looking at.
/// They don't sign in: run them on a simulator the other suites have signed in as `api` (no
/// `-UITestReset`), with a song in the mini-player. Skipped without `TEST_RUNNER_NAVINX_FILM`.
final class FilmUITests: XCTestCase {
    private var app: XCUIApplication!

    /// Open with a tap, close with the chevron; open, a short drag that springs back, a long drag that
    /// closes; then the same from the folded bar's inline accessory.
    @MainActor
    func testNowPlayingOpenAndClose() throws {
        try launch([])
        let title = app.staticTexts["playerBarTitle"].firstMatch
        XCTAssert(title.waitForExistence(timeout: 20), "no mini-player")
        let close = app.buttons["nowPlayingClose"]
        sleep(2)

        mark("open by tap")
        title.tap()
        XCTAssert(close.waitForExistence(timeout: 5))
        sleep(2)
        mark("close by chevron")
        close.tap()
        sleep(2)

        mark("open again")
        title.tap()
        XCTAssert(close.waitForExistence(timeout: 5))
        sleep(2)
        mark("half drag, let go")
        drag(from: 0.35, points: 220, speed: 400, hold: 0.4)
        sleep(2)
        XCTAssert(close.exists, "a short drag closed now playing")
        mark("long drag closes")
        drag(from: 0.35, points: 420, speed: 500, hold: 0.2)
        sleep(2)
        XCTAssertFalse(close.exists, "a long drag didn't close now playing")

        mark("flick closes")
        title.tap()
        XCTAssert(close.waitForExistence(timeout: 5))
        sleep(2)
        app.swipeDown(velocity: .fast)
        sleep(2)
        XCTAssertFalse(close.exists, "a flick didn't close now playing")
        mark("end")
    }

    /// The Duo's cover display: a drag that folds the mini-player into the circle, a tap that brings it
    /// back, a fold and the page's top bringing it back; then landscape's small capsule.
    @MainActor
    func testDuoMelt() throws {
        try launch([])
        let title = app.staticTexts["playerBarTitle"].firstMatch
        XCTAssert(title.waitForExistence(timeout: 20), "no mini-player")
        sleep(2)
        mark("fold by drag")
        drag(from: 0.75, points: -300, speed: 300, hold: 0.3)
        let circle = app.buttons["duoPlayerBarCircle"]
        XCTAssert(circle.waitForExistence(timeout: 5), "the drag didn't fold the mini-player")
        sleep(2)
        mark("unfold by tap")
        circle.tap()
        sleep(2)
        mark("fold by flick")
        app.swipeUp(velocity: .fast)
        sleep(2)
        mark("unfold at the top")
        for _ in 0..<4 { app.swipeDown(velocity: .fast) }
        sleep(2)

        try launch(["-UITestOrientation", "left"])
        XCTAssert(app.staticTexts["playerBarTitle"].firstMatch.waitForExistence(timeout: 20))
        sleep(3)
        mark("landscape fold")
        app.windows.firstMatch.swipeUp()
        sleep(2)
        mark("landscape unfold by tap")
        app.descendants(matching: .any)["duoPlayerBarCompact"].firstMatch.tap()
        sleep(2)
        mark("end")
        try launch(["-UITestOrientation", "portrait"])
    }

    /// C30 bug 1: the bar's return at the top of Home, timed. Each way of getting back to the top, after a
    /// fold: a slow drag, a quicker one with no hold, a flick, a quick down and up, a pull past the top;
    /// and a scroll up short of the top, which must leave it folded. The marks give each step's start and
    /// whether the bar came back; the app's own log (`chrome`) and the film give the timing.
    @MainActor
    func testUnfoldTiming() throws {
        try launch([])
        let title = app.staticTexts["playerBarTitle"].firstMatch
        XCTAssert(title.waitForExistence(timeout: 20), "no mini-player")
        XCTAssert(app.selectTab("Home"))
        sleep(2)
        func fold() {
            drag(from: 0.8, points: -300, speed: 200, hold: 0.3)
            XCTAssert(waitForBar(folded: true, timeout: 4), "the bar didn't fold")
            sleep(1)
        }
        func check(_ step: String, open: Bool = true) {
            let ok = waitForBar(folded: !open, timeout: 3)
            mark("\(step) result: \(app.isTabBarMinimised ? "FOLDED" : "open")")
            XCTAssert(ok, "\(step): expected the bar \(open ? "open" : "folded")")
            sleep(1)
        }
        for round in 1...2 {
            fold(); mark("slow drag to the top \(round)")
            drag(from: 0.25, points: 330, speed: 60, hold: 0.3); check("slow drag \(round)")
            fold(); mark("drag to the top, no hold \(round)")
            drag(from: 0.25, points: 330, speed: 300, hold: 0); check("drag no hold \(round)")
            fold(); mark("flick to the top \(round)")
            app.swipeDown(velocity: .fast); check("flick \(round)")
            mark("quick down and up \(round)")
            drag(from: 0.8, points: -200, speed: 1200, hold: 0)
            drag(from: 0.25, points: 400, speed: 1200, hold: 0); check("quick down and up \(round)")
            fold(); mark("pull past the top \(round)")
            drag(from: 0.25, points: 240, speed: 60, hold: 0.3)
            drag(from: 0.25, points: 160, speed: 60, hold: 0.3); check("pull past \(round)")
            fold(); mark("up short of the top \(round)")
            drag(from: 0.25, points: 120, speed: 60, hold: 0.3); check("short of the top \(round)", open: false)
            for _ in 0..<4 { app.swipeDown(velocity: .fast) }
            sleep(2)
        }
        mark("end")
    }

    /// C30 bugs 3 and 4 on whatever device runs it, signed in already (the Duo's inner display and its side
    /// rail): Settings and its Add Server have no mini-player and no tabs; both come back on leaving.
    /// Pictures to `NAVINX_SHOTS`.
    @MainActor
    func testSettingsChromeHere() throws {
        try launch([])
        let title = app.staticTexts["playerBarTitle"].firstMatch
        XCTAssert(title.waitForExistence(timeout: 20), "no mini-player")
        XCTAssert(app.selectTab("Home"))
        sleep(2)
        shot("chrome-home")
        app.buttons["settingsGear"].firstMatch.tap()
        XCTAssert(app.buttons["settingsTab-Server"].waitForExistence(timeout: 8), "Settings didn't open")
        sleep(2)
        shot("chrome-settings")
        XCTAssertFalse(title.exists, "Settings: the mini-player should be gone")
        XCTAssertNil(app.hittableTab("New"), "Settings: the tabs should be gone")
        app.buttons["settingsTab-Server"].tap()
        let add = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Add Server'")).firstMatch
        if add.waitForExistence(timeout: 5), add.isEnabled {
            add.tap()
            sleep(2)
            shot("chrome-add-server")
            XCTAssertFalse(title.exists, "Add Server: the mini-player should be gone")
            XCTAssertNil(app.hittableTab("New"), "Add Server: the tabs should be gone")
            app.buttons["BackButton"].firstMatch.tap()
            sleep(2)
        }
        app.buttons["BackButton"].firstMatch.tap()
        sleep(2)
        shot("chrome-home-again")
        XCTAssert(title.waitForExistence(timeout: 4), "back on Home: the mini-player should be back")
        XCTAssertNotNil(app.hittableTab("New"), "back on Home: the tabs should be back")
    }

    private func shot(_ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["NAVINX_SHOTS"] else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(filePath: dir).appending(path: "\(name).png"))
    }

    @MainActor
    private func waitForBar(folded: Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)
        repeat {
            if app.isTabBarMinimised == folded { return true }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date.now < deadline
        return app.isTabBarMinimised == folded
    }

    @MainActor
    private func launch(_ arguments: [String]) throws {
        guard ProcessInfo.processInfo.environment["NAVINX_FILM"] != nil else {
            throw XCTSkip("Only for filming (TEST_RUNNER_NAVINX_FILM)")
        }
        continueAfterFailure = true
        if app != nil, app.state != .notRunning { app.terminate() }
        app = XCUIApplication()
        app.launchArguments = arguments
        app.launch()
    }

    /// A drag down (or up, with negative points) from a height on the screen, at a speed, then a hold.
    @MainActor
    private func drag(from y: CGFloat, points: CGFloat, speed: Double, hold: TimeInterval) {
        let start = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: y))
        start.press(
            forDuration: 0.05,
            thenDragTo: start.withOffset(CGVector(dx: 0, dy: points)),
            withVelocity: XCUIGestureVelocity(speed),
            thenHoldForDuration: hold
        )
    }

    private func mark(_ step: String) {
        let line = "\(Date.now.timeIntervalSince1970) \(step)\n"
        print("FILM: \(line)", terminator: "")
        guard let path = ProcessInfo.processInfo.environment["NAVINX_MARKS"] else { return }
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            FileManager.default.createFile(atPath: path, contents: Data(line.utf8))
        }
    }
}
