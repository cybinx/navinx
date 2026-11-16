import XCTest

/// Plays real music from a real server, saving a screenshot at each step. **This writes to the
/// server as the login given:** now-playing and play-count updates, and a favourite turned on and
/// off again. Skipped without `TEST_RUNNER_NAVINX_LIVE`; see `README.md`.
final class PlaybackUITests: XCTestCase {
    private struct Login: Decodable { let url: String; let username: String; let password: String }

    private var shots: URL?
    private var prefix = ""

    @MainActor
    func testPlayback() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        guard let path = env["NAVINX_LIVE"] else { throw XCTSkip("No login file (TEST_RUNNER_NAVINX_LIVE)") }
        let login = try JSONDecoder().decode(Login.self, from: Data(contentsOf: URL(filePath: path)))
        if let dir = env["NAVINX_SHOTS"] {
            shots = URL(filePath: dir)
            try? FileManager.default.createDirectory(at: shots!, withIntermediateDirectories: true)
        }
        prefix = env["NAVINX_SHOT_PREFIX"] ?? "play-"

        let app = XCUIApplication()
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
        if notNow.waitForExistence(timeout: 8) {
            notNow.tap()
            // A tap during the sheet's dismissal doesn't land.
            sleep(2)
        }

        XCTAssert(app.buttons["Library"].firstMatch.waitForExistence(timeout: 15))
        // XCUITest can resolve the tab to a copy with no position ("hit point {-1, -1}") and touch
        // nothing, so this takes the copy that's really on screen.
        // Home has a "Liked Songs" tile too, so this looks for the Library row's subtitle.
        let liked = app.staticTexts["Playlist • Favorites"]
        for _ in 0..<3 where !liked.exists {
            // "Save Password?" can come late, and it swallows the tap.
            if notNow.exists {
                notNow.tap()
                sleep(2)
            }
            app.buttons.matching(NSPredicate(format: "label == 'Library'")).allElementsBoundByIndex
                .first { $0.isHittable }?.tap()
            _ = liked.waitForExistence(timeout: 4)
        }
        XCTAssert(liked.exists, "the Library tab didn't open")

        let title = app.staticTexts["playerBarTitle"]
        let time = app.descendants(matching: .any)["playerBarTime"]
        let playPause = app.buttons["playerBarPlayPause"]
        // D81: the mini-player always has a song. With nothing played, one is loaded and paused.
        XCTAssert(title.waitForExistence(timeout: 30), "the bar should show a song even with nothing played")
        XCTAssertEqual(playPause.label, "Play", "the song kept in the bar shouldn't be playing")
        XCTAssert(time.label.hasPrefix("00:00"), "the kept song should be at its start: \(time.label)")

        // The layout is saved between runs. In the grid, covers' discs are "Play" buttons too.
        let layout = app.buttons["libraryLayout"]
        XCTAssert(layout.waitForExistence(timeout: 5))
        if layout.label == "Switch to List" { layout.tap() }

        // "Save Password?" can come late, and it swallows the next tap.
        if notNow.waitForExistence(timeout: 8) {
            notNow.tap()
            sleep(2)
        }

        // The album with the long title, through Search: the Library lists no albums since D210.
        XCTAssert(app.openAlbumFromSearch("IMGEEKED", prefix: true), "the album page didn't load")
        sleep(1)

        // Play.
        app.pagePlayButton.tap()
        XCTAssert(playPause.waitForLabel("Pause", timeout: 15), "Play didn't start the album")
        let firstTitle = title.label
        XCTAssertFalse(firstTitle.isEmpty)
        XCTAssert(seconds(time, reach: 3), "the time isn't moving, so nothing is playing: \(time.label)")
        XCTAssertEqual(playPause.label, "Pause")
        shot("01-playing")

        // Pause holds still.
        playPause.tap()
        XCTAssert(playPause.waitForLabel("Play"))
        sleep(1)
        let pausedAt = time.label
        sleep(2)
        XCTAssertEqual(time.label, pausedAt, "the time moved while paused")
        shot("02-paused")

        // And back.
        playPause.tap()
        XCTAssert(playPause.waitForLabel("Pause"))
        let moved = NSPredicate { _, _ in time.label != pausedAt }
        wait(for: [XCTNSPredicateExpectation(predicate: moved, object: nil)], timeout: 10)

        // A title too long for its space scrolls after 2 seconds.
        title.tap()
        let longTitle = app.staticTexts["nowPlayingTitle"]
        XCTAssert(longTitle.waitForExistence(timeout: 5), "now playing didn't open")
        sleep(1)
        // It stays inside its space: nothing else is pushed off the screen.
        XCTAssert(app.buttons["nowPlayingMore"].isHittable, "a long title pushed the screen sideways")
        XCTAssert(app.buttons["nowPlayingAddTo"].isHittable, "a long title pushed the screen sideways")
        shot("02a-long-title-start")
        sleep(4)
        XCTAssertLessThan(longTitle.frame.minX, 0, "the long title isn't scrolling")
        shot("02a-long-title-scrolled")
        app.buttons["Close"].tap()
        XCTAssert(longTitle.waitForNonExistence(timeout: 5))

        // A one-song album: Next ends the queue, back on its first song, paused at the start (D25).
        if app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '1 song'")).firstMatch.exists {
            app.buttons["Next"].tap()
            XCTAssert(playPause.waitForLabel("Play"), "the queue didn't end")
            XCTAssert(time.label.hasPrefix("00:00"), time.label)
            XCTAssertEqual(title.label, firstTitle)
            shot("02b-queue-ended")
            // And Play starts it over.
            playPause.tap()
            XCTAssert(playPause.waitForLabel("Pause"))
            XCTAssert(seconds(time, reach: 1), "it didn't start over: \(time.label)")
        }

        // On to an album with several songs, by name, like the one above.
        goBack(app)
        let severalSongs = app.staticTexts["me"].firstMatch
        XCTAssert(severalSongs.waitForExistence(timeout: 5), "this test needs the album \"me\"")
        severalSongs.tap()
        XCTAssert(app.buttons["Shuffle"].waitForExistence(timeout: 10), "the album page didn't load")
        sleep(1)
        app.pagePlayButton.tap()
        sleep(2)
        let trackOne = title.label

        // Now playing opens from the mini-player, showing the same song.
        title.tap()
        let bigTitle = app.staticTexts["nowPlayingTitle"]
        XCTAssert(bigTitle.waitForExistence(timeout: 5), "now playing didn't open")
        XCTAssertEqual(bigTitle.label, trackOne)
        let elapsed = app.staticTexts["nowPlayingElapsed"]
        XCTAssert(elapsed.exists)
        let bigPlayPause = app.buttons["nowPlayingPlayPause"]
        XCTAssertEqual(bigPlayPause.label, "Pause")
        XCTAssert(app.descendants(matching: .any)["airPlay"].exists, "no AirPlay button")
        sleep(1)
        shot("03-now-playing")

        // Next and Previous: the queue is the album, in order.
        app.buttons["nowPlayingNext"].tap()
        wait(for: bigTitle, toNotBe: trackOne)
        let secondTitle = bigTitle.label
        shot("03b-next")
        // Straight back: within three seconds of its start, Previous goes to the song before.
        app.buttons["nowPlayingPrevious"].tap()
        wait(for: bigTitle, toBe: trackOne)
        app.buttons["nowPlayingNext"].tap()
        wait(for: bigTitle, toBe: secondTitle)
        XCTAssert(seconds(elapsed, reach: 4), "the next song isn't playing: \(elapsed.label)")
        // Later on, Previous restarts the song instead.
        app.buttons["nowPlayingPrevious"].tap()
        sleep(1)
        XCTAssertEqual(bigTitle.label, secondTitle)
        XCTAssertLessThan(secondsValue(elapsed), 4)

        // The scrubber seeks to where it's touched.
        app.sliders["Seek"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        sleep(1)
        XCTAssertGreaterThan(secondsValue(elapsed), 10, "seeking didn't move: \(elapsed.label)")
        shot("03c-seeked")

        // The volume slider is the system's own (C59), and the simulator draws none: it's for the phone.

        // Pause: the cover shrinks and the time holds.
        bigPlayPause.tap()
        XCTAssert(bigPlayPause.waitForLabel("Play"))
        sleep(1)
        shot("03d-paused")
        bigPlayPause.tap()
        XCTAssert(bigPlayPause.waitForLabel("Pause"))

        // Shuffle and repeat show they're on, then go back as they were.
        let shuffle = app.buttons["nowPlayingShuffle"]
        let wasShuffled = shuffle.value as? String
        shuffle.tap()
        XCTAssertNotEqual(shuffle.value as? String, wasShuffled)
        let repeatButton = app.buttons["nowPlayingRepeat"]
        repeatButton.tap()
        XCTAssertEqual(repeatButton.value as? String, "On")
        sleep(1)
        shot("03e-shuffle-repeat")
        shuffle.tap()
        repeatButton.tap()
        repeatButton.tap()
        XCTAssertEqual(repeatButton.value as? String, "Off")

        // The song's favourite goes on and off again, leaving the server as it was.
        app.buttons["Add to favorites"].tap()
        XCTAssert(app.buttons["Remove from favorites"].waitForExistence(timeout: 5))
        shot("03f-favorite")
        app.buttons["Remove from favorites"].tap()
        XCTAssert(app.buttons["Add to favorites"].waitForExistence(timeout: 5))

        // Sideways on the cover: a swipe left is the next song, a swipe right goes back.
        let afterCover = app.descendants(matching: .any)["nowPlayingCover"]
        XCTAssert(afterCover.exists)
        afterCover.swipeLeft(velocity: .fast)
        wait(for: bigTitle, toNotBe: secondTitle)
        let thirdTitle = bigTitle.label
        afterCover.swipeRight(velocity: .fast)
        wait(for: bigTitle, toBe: secondTitle)
        _ = thirdTitle

        // Landscape has its own layout.
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(2)
        shot("03h-landscape")
        XCTAssert(app.sliders["Seek"].exists)
        XCTAssert(app.buttons["Queue"].isHittable, "landscape cut the bottom row off")
        XCUIDevice.shared.orientation = .portrait
        sleep(2)

        // Pulling down closes it, and it opens again.
        afterCover.swipeDown(velocity: .fast)
        XCTAssert(bigTitle.waitForNonExistence(timeout: 5), "pulling down didn't close it")
        XCTAssert(title.waitForExistence(timeout: 5))
        XCTAssertEqual(title.label, secondTitle)
        shot("03i-closed-by-pull")
        title.tap()
        XCTAssert(bigTitle.waitForExistence(timeout: 5))

        // The artist's name closes it and opens their page in the Library.
        let artistName = app.buttons.matching(NSPredicate(format: "label != '' AND identifier == 'nowPlayingArtist'")).firstMatch
        if artistName.waitForExistence(timeout: 2) {
            artistName.tap()
            XCTAssert(bigTitle.waitForNonExistence(timeout: 5), "the artist's name didn't close it")
            sleep(2)
            shot("03j-artist-page")
            goBack(app)
        }

        // Back to the album, with the chevron closing it this time.
        title.tap()
        XCTAssert(bigTitle.waitForExistence(timeout: 5))
        app.buttons["Close"].tap()
        XCTAssert(bigTitle.waitForNonExistence(timeout: 5), "the chevron didn't close it")

        // It carries on in the background.
        let before = secondsValue(time)
        XCUIDevice.shared.press(.home)
        sleep(8)
        app.activate()
        XCTAssert(title.waitForExistence(timeout: 10))
        XCTAssertGreaterThanOrEqual(secondsValue(time), before + 6, "playback stopped in the background")
        XCTAssertEqual(playPause.label, "Pause")
        shot("04-after-background")

        // Tapping a song plays it; the row shows it's the current one.
        let row = app.staticTexts.matching(NSPredicate(format: "label == %@ AND identifier != 'playerBarTitle'", trackOne)).firstMatch
        XCTAssert(row.waitForExistence(timeout: 5))
        row.tap()
        wait(for: title, toBe: trackOne)
        sleep(1)
        shot("05-tapped-song")

        // A swipe right adds to the queue, with Flutter's message.
        let start = row.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 160, dy: 0)))
        let toast = app.descendants(matching: .any)["toast"]
        XCTAssert(toast.waitForExistence(timeout: 5), "no message after swiping")
        XCTAssertTrue(toast.label.hasSuffix("added to queue"), toast.label)
        shot("06-swiped-to-queue")
        sleep(3)

        // The album's favourite goes on and off again, leaving the server as it was.
        // (On the Duo's side rail the heart is inside the toolbar's overflow ⋯ menu, with the download.)
        let favorite = app.buttons["Add to Favorites"]
        let overflow = app.buttons["BottomOverflowBarButtonItem"]
        if favorite.waitForExistence(timeout: 3) {
            favorite.tap()
            XCTAssert(app.buttons["Remove from Favorites"].waitForExistence(timeout: 5))
            shot("07-favorite")
            app.buttons["Remove from Favorites"].tap()
            XCTAssert(favorite.waitForExistence(timeout: 5))
        } else if overflow.exists {
            overflow.tap()
            XCTAssert(favorite.waitForExistence(timeout: 3), "no favourite in the overflow menu")
            favorite.tap()
            sleep(2)
            overflow.tap()
            XCTAssert(app.buttons["Remove from Favorites"].waitForExistence(timeout: 5))
            shot("07-favorite")
            app.buttons["Remove from Favorites"].tap()
            sleep(1)
        }

        // Shuffle plays something from the album, in shuffle mode.
        app.buttons["Shuffle"].firstMatch.tap()
        sleep(2)
        XCTAssertEqual(playPause.label, "Pause")
        shot("08-shuffle")

        // In the Library's grid, a playlist cover's play disc starts it (D210: playlists are the only
        // covers with a disc there, so this needs the account to have one).
        goBack(app)
        XCTAssert(app.selectTab("Library"))
        XCTAssert(layout.waitForExistence(timeout: 5))
        layout.tap()
        XCTAssert(app.buttons["Switch to List"].waitForExistence(timeout: 3))
        sleep(2)
        shot("09-grid-discs")
        let disc = app.buttons.matching(NSPredicate(format: "label == 'Play' AND identifier != 'playerBarPlayPause'")).firstMatch
        if disc.waitForExistence(timeout: 5) {
            disc.tap()
            sleep(2)
            XCTAssertEqual(playPause.label, "Pause")
            shot("10-played-from-disc")
        }

        // Stop the music before leaving.
        playPause.tap()
        XCTAssert(playPause.waitForLabel("Play"))
        layout.tap()
        XCTAssert(app.buttons["Switch to Grid"].waitForExistence(timeout: 3))
    }

    /// On the iPhone Duo the back button lives in the side rail, not a navigation bar.
    @MainActor
    private func goBack(_ app: XCUIApplication) {
        let inBar = app.navigationBars.buttons.element(boundBy: 0)
        if inBar.exists {
            inBar.tap()
        } else {
            app.buttons["BackButton"].firstMatch.tap()
        }
        sleep(1)
    }

    private func wait(for element: XCUIElement, toBe label: String) {
        let matches = NSPredicate { _, _ in element.label == label }
        wait(for: [XCTNSPredicateExpectation(predicate: matches, object: nil)], timeout: 10)
    }

    private func wait(for element: XCUIElement, toNotBe label: String) {
        let differs = NSPredicate { _, _ in element.label != label }
        wait(for: [XCTNSPredicateExpectation(predicate: differs, object: nil)], timeout: 10)
    }

    /// The time label's elapsed part, `m:ss / m:ss`, in seconds.
    private func secondsValue(_ element: XCUIElement) -> Int {
        let parts = element.label.split(separator: " ").first?.split(separator: ":").compactMap { Int($0) } ?? []
        return parts.count == 2 ? parts[0] * 60 + parts[1] : -1
    }

    /// Whether the elapsed time gets to at least `target` seconds.
    private func seconds(_ element: XCUIElement, reach target: Int, from start: Int = 0) -> Bool {
        let deadline = Date.now.addingTimeInterval(TimeInterval(target) + 25)
        while Date.now < deadline {
            if secondsValue(element) >= start + target { return true }
            Thread.sleep(forTimeInterval: 0.3)
        }
        return false
    }

    @MainActor
    private func shot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        if let shots {
            try? screenshot.pngRepresentation.write(to: shots.appending(path: "\(prefix)\(name).png"))
        }
    }
}

private extension XCUIElement {
    func waitForLabel(_ label: String, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            if self.label == label { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }
}
