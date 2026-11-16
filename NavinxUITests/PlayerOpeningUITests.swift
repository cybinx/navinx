import XCTest

/// Opens and closes now playing (C15, D76) against a real server: a tap on the mini-player, the chevron, a
/// swipe down, a swipe down on the queue page (which scrolls and leaves it open), a song change while it's
/// open, and from the folded bar's inline accessory. **This writes to the server as the login given:** now-playing and play counts.
/// Use the test account `api` (`CLAUDE.md`). Skipped without `TEST_RUNNER_NAVINX_LIVE`; see `README.md`.
///
/// Environment: `NAVINX_LIVE` (login file), `NAVINX_SHOTS` (screenshot folder), `NAVINX_MARKS` (a file
/// that gets a line with the time at each step, to line a `simctl io recordVideo` recording up with the
/// steps), `NAVINX_SCEN` (a comma list of the steps to run, to film one of them).
final class PlayerOpeningUITests: XCTestCase {
    private struct Login: Decodable { let url: String; let username: String; let password: String }

    private var app: XCUIApplication!
    private var login: Login!
    private var shots: URL?

    private var title: XCUIElement { app.staticTexts["playerBarTitle"] }
    private var bigTitle: XCUIElement { app.descendants(matching: .any)["nowPlayingTitle"].firstMatch }
    /// By identifier: the page behind the player has a Back button of its own in XCUITest's tree.
    private var closeButton: XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier == 'nowPlayingClose' AND label == 'Close'")).firstMatch
    }
    private var backButton: XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier == 'nowPlayingClose' AND label == 'Back'")).firstMatch
    }

    private var steps: Set<String> {
        let list = ProcessInfo.processInfo.environment["NAVINX_SCEN"] ?? "open,chevron,swipe,queue,next"
        return Set(list.split(separator: ",").map(String.init))
    }

    /// Tap, chevron, flick down, a short pull that lets go, the queue page, a song change while open.
    @MainActor
    func testOpenAndClose() throws {
        try launch(play: true)
        XCTAssert(app.selectTab("Home"))
        sleep(2)
        let song = title.label

        // A tap on the mini-player opens it. (That the backdrop is there on the first frame can't be seen from
        // here, since XCUITest waits for the animation to finish; `NowPlayingCoversTests` covers the cache and a
        // screen recording the frames.)
        if steps.contains("open") || steps.contains("chevron") {
            mark("open tap")
            title.tap()
            XCTAssert(bigTitle.waitForExistence(timeout: 5), "a tap on the mini-player didn't open now playing")
            XCTAssertEqual(bigTitle.label, song)
            sleep(3)
            shot("open")
            // The chevron closes it onto the mini-player.
            mark("chevron tap")
            closeButton.tap()
            XCTAssert(bigTitle.waitForNonExistence(timeout: 5), "the chevron didn't close now playing")
            XCTAssert(title.waitForExistence(timeout: 5))
            XCTAssertEqual(title.label, song)
            sleep(3)
            shot("closed-by-chevron")
        }

        // A flick down closes it.
        if steps.contains("swipe") {
            mark("swipe open")
            title.tap()
            XCTAssert(bigTitle.waitForExistence(timeout: 5))
            sleep(3)
            mark("swipe flick")
            at(0.5, 0.3).press(forDuration: 0.02, thenDragTo: at(0.5, 0.85), withVelocity: .fast, thenHoldForDuration: 0)
            XCTAssert(bigTitle.waitForNonExistence(timeout: 5), "a swipe down didn't close now playing")
            XCTAssert(title.waitForExistence(timeout: 5))
            sleep(3)
            shot("closed-by-swipe")
        }

        // The queue page: a swipe down there scrolls and leaves it open; ✕ goes back to the player, then
        // the chevron closes it.
        if steps.contains("queue") {
            mark("queue open")
            title.tap()
            XCTAssert(bigTitle.waitForExistence(timeout: 5))
            sleep(3)
            app.buttons["nowPlayingQueue"].tap()
            XCTAssert(backButton.waitForExistence(timeout: 5), "the queue page didn't open")
            sleep(2)
            mark("queue swipe")
            at(0.5, 0.25).press(forDuration: 0.02, thenDragTo: at(0.5, 0.85), withVelocity: .fast, thenHoldForDuration: 0)
            sleep(3)
            XCTAssert(bigTitle.exists || backButton.exists, "a swipe down on the queue closed now playing")
            XCTAssert(backButton.exists, "the queue page should still be showing")
            shot("queue-after-swipe")
            mark("queue back")
            backButton.tap()
            XCTAssert(closeButton.waitForExistence(timeout: 5), "✕ didn't go back to the player")
            sleep(1)
            mark("queue close")
            closeButton.tap()
            XCTAssert(bigTitle.waitForNonExistence(timeout: 5))
            sleep(3)
        }

        // A song change while it's open: the mini-player under it shows the new song when it closes.
        if steps.contains("next") {
            mark("next open")
            title.tap()
            XCTAssert(bigTitle.waitForExistence(timeout: 5))
            sleep(3)
            mark("next tap")
            app.buttons["nowPlayingNext"].tap()
            sleep(3)
            app.buttons["nowPlayingNext"].tap()
            sleep(3)
            let changed = bigTitle.label
            XCTAssertNotEqual(changed, song)
            mark("next close")
            closeButton.tap()
            XCTAssert(bigTitle.waitForNonExistence(timeout: 5))
            XCTAssert(title.waitForExistence(timeout: 5))
            XCTAssertEqual(title.label, changed)
            sleep(3)
            shot("closed-after-next")
        }
        pauseIfPlaying()
    }

    /// With the tab bar folded the accessory is the inline one (C14): now playing opens from it and
    /// closes onto it, and the bar is still folded afterwards.
    @MainActor
    func testFromTheFoldedBar() throws {
        try launch(play: true)
        XCTAssert(app.selectTab("Home"))
        sleep(2)
        let song = title.label
        for _ in 0..<3 {
            app.swipeUp(velocity: .fast)
            usleep(400_000)
        }
        XCTAssert(app.waitForTabBar(minimised: true), "the bar didn't fold")
        sleep(2)
        shot("inline")
        mark("inline open")
        title.tap()
        XCTAssert(bigTitle.waitForExistence(timeout: 5), "the inline accessory didn't open now playing")
        XCTAssertEqual(bigTitle.label, song)
        sleep(3)
        mark("inline chevron")
        closeButton.tap()
        XCTAssert(bigTitle.waitForNonExistence(timeout: 5))
        sleep(3)
        XCTAssert(app.isTabBarMinimised, "closing now playing unfolded the bar")
        XCTAssertEqual(title.label, song)
        shot("inline-closed")
        // And a swipe down closes it onto the inline accessory too.
        mark("inline open 2")
        title.tap()
        XCTAssert(bigTitle.waitForExistence(timeout: 5))
        sleep(3)
        mark("inline flick")
        at(0.5, 0.3).press(forDuration: 0.02, thenDragTo: at(0.5, 0.85), withVelocity: .fast, thenHoldForDuration: 0)
        XCTAssert(bigTitle.waitForNonExistence(timeout: 5), "a swipe down didn't close it")
        sleep(3)
        XCTAssert(app.isTabBarMinimised)
        pauseIfPlaying()
    }

    // MARK: steps

    @MainActor
    private func launch(play: Bool) throws {
        continueAfterFailure = true
        let env = ProcessInfo.processInfo.environment
        guard let path = env["NAVINX_LIVE"] else { throw XCTSkip("No login file (TEST_RUNNER_NAVINX_LIVE)") }
        login = try JSONDecoder().decode(Login.self, from: Data(contentsOf: URL(filePath: path)))
        if let dir = env["NAVINX_SHOTS"] {
            shots = URL(filePath: dir)
            try? FileManager.default.createDirectory(at: shots!, withIntermediateDirectories: true)
        }
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
            sleep(2)
        }
        XCTAssert(app.buttons["Library"].firstMatch.waitForExistence(timeout: 20))
        XCTAssert(app.selectTab("Library"))
        let layout = app.buttons["libraryLayout"]
        if layout.waitForExistence(timeout: 5), layout.label == "Switch to List" { layout.tap() }
        guard play else { return }
        // The album with the most songs, "me", through Search: the Library lists no albums since D210.
        XCTAssert(app.openAlbumFromSearch("me"), "this test needs the album \"me\"")
        sleep(1)
        app.pagePlayButton.tap()
        let pause = app.buttons.matching(NSPredicate(format: "identifier == 'playerBarPlayPause' AND label == 'Pause'")).firstMatch
        XCTAssert(pause.waitForExistence(timeout: 15), "the album didn't start")
        XCTAssert(title.waitForExistence(timeout: 10))
        sleep(2)
        mark("song \(title.label)")
    }

    @MainActor
    private func pauseIfPlaying() {
        let playPause = app.buttons["playerBarPlayPause"].firstMatch
        if playPause.exists, playPause.label == "Pause" { playPause.tap() }
    }

    private func at(_ x: Double, _ y: Double) -> XCUICoordinate {
        app.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y))
    }

    private func mark(_ step: String) {
        guard let path = ProcessInfo.processInfo.environment["NAVINX_MARKS"] else { return }
        let line = "\(Date.now.timeIntervalSince1970) \(step)\n"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            FileManager.default.createFile(atPath: path, contents: Data(line.utf8))
        }
    }

    @MainActor
    private func shot(_ name: String) {
        save(XCUIScreen.main.screenshot(), name)
    }

    private func save(_ screenshot: XCUIScreenshot, _ name: String) {
        guard let shots else { return }
        try? screenshot.pngRepresentation.write(to: shots.appending(path: "\(name).png"))
    }
}
