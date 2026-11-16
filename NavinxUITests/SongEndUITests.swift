import XCTest

/// Lets a song play to its end and checks the app is still there (the user's report of 2026-11-07: "the
/// app crashes when a song finishes", which the simulator didn't reproduce: `docs/log/C15.md`). Each test
/// seeks to a couple of seconds before the end with the scrubber and waits. The builder also tried the last
/// song of a queue, Repeat One, the kept song, a restored one and a song ending on Home, the album, the
/// queue and the lyrics pages: all passed once and aren't kept. **This writes to the server as the login given:**
/// now-playing and play counts (a scrobble when a song completes). Use the test account `api`
/// (`CLAUDE.md`). Skipped without `TEST_RUNNER_NAVINX_LIVE`; see `README.md`.
final class SongEndUITests: XCTestCase {
    private struct Login: Decodable { let url: String; let username: String; let password: String }

    private var app: XCUIApplication!
    private var title: XCUIElement { app.staticTexts["playerBarTitle"] }
    private var bigTitle: XCUIElement { app.descendants(matching: .any)["nowPlayingTitle"].firstMatch }
    private var playPause: XCUIElement { app.buttons["playerBarPlayPause"].firstMatch }
    private var time: XCUIElement { app.descendants(matching: .any)["playerBarTime"] }

    /// A middle song ends and the next one carries on, with no gap in the queue.
    @MainActor
    func testAMiddleSongEnds() throws {
        try launchAndPlayAlbum("me")
        let first = title.label
        openNowPlaying()
        seekToTheEnd()
        XCTAssert(waitForTitle(notEqualTo: first, timeout: 30), "the next song didn't start")
        XCTAssertEqual(playPause.label, "Pause", "the queue stopped after a song ended")
        assertAlive()
        close()
    }

    /// A queue of one song ends: it goes back to its start, paused (D25).
    @MainActor
    func testAOneSongQueueEnds() throws {
        try launchAndPlayAlbum("Pow Wow")
        let song = title.label
        openNowPlaying()
        seekToTheEnd()
        XCTAssert(app.buttons["nowPlayingPlayPause"].waitForLabel("Play", timeout: 30), "the queue didn't end")
        assertAlive()
        XCTAssertEqual(bigTitle.label, song)
        XCTAssert(app.staticTexts["nowPlayingElapsed"].label.hasPrefix("00:0"), "it should be back at its start")
        // Play starts it over.
        app.buttons["nowPlayingPlayPause"].tap()
        XCTAssert(app.buttons["nowPlayingPlayPause"].waitForLabel("Pause", timeout: 10))
        close()
        pause()
    }

    /// A song ends while the app is in the background.
    @MainActor
    func testASongEndsInTheBackground() throws {
        try launchAndPlayAlbum("me")
        openNowPlaying()
        seekToTheEnd(leaving: 0.97)
        XCUIDevice.shared.press(.home)
        sleep(15)
        app.activate()
        XCTAssert(app.wait(for: .runningForeground, timeout: 10), "the app isn't running after a song ended in the background")
        assertAlive()
        close()
        pause()
    }

    // MARK: steps

    @MainActor
    private func launch() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        guard let path = env["NAVINX_LIVE"] else { throw XCTSkip("No login file (TEST_RUNNER_NAVINX_LIVE)") }
        let login = try JSONDecoder().decode(Login.self, from: Data(contentsOf: URL(filePath: path)))
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
    }

    @MainActor
    private func launchAndPlayAlbum(_ name: String) throws {
        try launch()
        XCTAssert(app.selectTab("Library"))
        let layout = app.buttons["libraryLayout"]
        if layout.waitForExistence(timeout: 5), layout.label == "Switch to List" { layout.tap() }
        // Through Search: the Library lists no albums since D210.
        XCTAssert(app.openAlbumFromSearch(name), "this test needs the album \"\(name)\"")
        sleep(1)
        app.pagePlayButton.tap()
        let pause = app.buttons.matching(NSPredicate(format: "identifier == 'playerBarPlayPause' AND label == 'Pause'")).firstMatch
        XCTAssert(pause.waitForExistence(timeout: 15), "the album didn't start")
        XCTAssert(title.waitForExistence(timeout: 10))
        sleep(2)
    }

    @MainActor
    private func openNowPlaying() {
        title.tap()
        XCTAssert(bigTitle.waitForExistence(timeout: 5), "now playing didn't open")
        sleep(2)
    }

    @MainActor
    private func close() {
        let chevron = app.buttons.matching(NSPredicate(format: "identifier == 'nowPlayingClose' AND label == 'Close'")).firstMatch
        if chevron.exists { chevron.tap() }
        _ = bigTitle.waitForNonExistence(timeout: 5)
    }

    @MainActor
    private func pause() {
        if playPause.exists, playPause.label == "Pause" { playPause.tap() }
    }

    /// The scrubber, tapped near its end so the song runs out within a few seconds.
    @MainActor
    private func seekToTheEnd(leaving fraction: Double = 0.985) {
        let slider = app.sliders["Seek"]
        XCTAssert(slider.waitForExistence(timeout: 5), "no scrubber")
        slider.coordinate(withNormalizedOffset: CGVector(dx: fraction, dy: 0.5)).tap()
    }

    @MainActor
    private func assertAlive() {
        XCTAssertEqual(app.state, .runningForeground, "the app is gone after a song ended")
        XCTAssert(app.buttons["Library"].exists || bigTitle.exists, "the app's screen is gone")
    }

    @MainActor
    private func waitForTitle(notEqualTo old: String, timeout: TimeInterval) -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            if app.state != .runningForeground { return false }
            if title.exists, title.label != old { return true }
            if bigTitle.exists, bigTitle.label != old { return true }
            Thread.sleep(forTimeInterval: 0.3)
        }
        return false
    }
}

private extension XCUIElement {
    func waitForLabel(_ label: String, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            if self.label == label { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return false
    }
}
