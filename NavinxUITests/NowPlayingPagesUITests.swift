import XCTest

/// The lyrics and queue pages and the menus (C8), against a real server, saving a screenshot at each
/// step. **This writes to the server as the login given:** play counts, a favourite and a rating on
/// and off again, and a song added to a playlist called "C8 temporary", if one exists (the test
/// doesn't create or delete it). Skipped without `TEST_RUNNER_NAVINX_LIVE`; see `README.md`.
final class NowPlayingPagesUITests: XCTestCase {
    private struct Login: Decodable { let url: String; let username: String; let password: String }

    private var shots: URL?
    private var prefix = ""
    private var app: XCUIApplication!

    private var title: XCUIElement { app.staticTexts["playerBarTitle"] }
    private var bigTitle: XCUIElement { app.descendants(matching: .any)["nowPlayingTitle"].firstMatch }
    private var toast: XCUIElement { app.descendants(matching: .any)["toast"] }
    /// By identifier: the page behind the player has a Back button of its own in XCUITest's tree.
    private var backButton: XCUIElement { app.buttons.matching(NSPredicate(format: "identifier == 'nowPlayingClose' AND label == 'Back'")).firstMatch }
    private var closeButton: XCUIElement { app.buttons.matching(NSPredicate(format: "identifier == 'nowPlayingClose' AND label == 'Close'")).firstMatch }

    @MainActor
    func testPagesAndMenus() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        guard let path = env["NAVINX_LIVE"] else { throw XCTSkip("No login file (TEST_RUNNER_NAVINX_LIVE)") }
        let login = try JSONDecoder().decode(Login.self, from: Data(contentsOf: URL(filePath: path)))
        if let dir = env["NAVINX_SHOTS"] {
            shots = URL(filePath: dir)
            try? FileManager.default.createDirectory(at: shots!, withIntermediateDirectories: true)
        }
        prefix = env["NAVINX_SHOT_PREFIX"] ?? "pages-"
        let isDuo = env["NAVINX_DUO"] != nil

        app = XCUIApplication()
        // LRCLIB already allowed (D179), so a song with no lyrics doesn't stop the walk with the question.
        app.launchArguments = ["-UITestReset", "-lrclib_fallback", "YES"]
        app.launch()
        signIn(login)
        playAlbum()

        // A plain tap still opens the player, with the menu's long press on the same view.
        title.tap()
        XCTAssert(bigTitle.waitForExistence(timeout: 5), "a tap on the mini-player didn't open now playing")
        sleep(1)
        closeButton.tap()
        XCTAssert(bigTitle.waitForNonExistence(timeout: 5))
        sleep(1)

        // A long press on the mini-player: the song options, under the song's header.
        title.press(forDuration: 1.2)
        XCTAssert(app.buttons["Play Next"].waitForExistence(timeout: 5), "no menu from the mini-player")
        for item in ["Add to Queue", "Add to Playlist", "Go to Album", "Go to Artist", "Download"] {
            XCTAssert(app.buttons[item].exists, "the menu has no \(item)")
        }
        shot("01-player-bar-menu")
        dismissMenu()
        XCTAssert(app.buttons["Play Next"].waitForNonExistence(timeout: 3), "the menu didn't close")

        title.tap()
        XCTAssert(bigTitle.waitForExistence(timeout: 5), "now playing didn't open after the menu closed")
        sleep(1)
        shot("02-player")

        queuePage()
        queueReorder()
        lyricsPages()
        openMoreSheet()
        openAddSheet()
        coverAndSliders()
        songOptionsFromQueue()
        landscape()
        if !isDuo { rowsInLists() }
    }

    /// C18 (D87): the ⋯ menu's Playback Speed submenu, a speed picked, and "Preserve pitch" off.
    /// Writes only a now-playing and perhaps a play count.
    @MainActor
    func testPlaybackSpeed() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        guard let path = env["NAVINX_LIVE"] else { throw XCTSkip("No login file (TEST_RUNNER_NAVINX_LIVE)") }
        let login = try JSONDecoder().decode(Login.self, from: Data(contentsOf: URL(filePath: path)))
        if let dir = env["NAVINX_SHOTS"] {
            shots = URL(filePath: dir)
            try? FileManager.default.createDirectory(at: shots!, withIntermediateDirectories: true)
        }
        prefix = (env["NAVINX_SHOT_PREFIX"] ?? "") + "speed-"

        app = XCUIApplication()
        app.launchArguments = ["-UITestReset"]
        app.launch()
        signIn(login)
        playAlbum()
        title.tap()
        XCTAssert(bigTitle.waitForExistence(timeout: 5))
        sleep(1)

        let speed = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Playback Speed'")).firstMatch
        app.buttons["nowPlayingMore"].tap()
        XCTAssert(speed.waitForExistence(timeout: 3), "the ⋯ menu has no Playback Speed")
        XCTAssertEqual(speed.label, "Playback Speed", "at 1× the row has no subtitle")
        shot("01-more-sheet")
        speed.tap()
        XCTAssert(app.buttons["1.5×"].waitForExistence(timeout: 3), "no speed choices")
        for choice in ["0.5×", "0.75×", "1×", "1.25×", "1.75×", "2×"] {
            XCTAssert(app.buttons[choice].exists, "no \(choice)")
        }
        let pitch = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Preserve pitch'")).firstMatch
        XCTAssert(pitch.exists, "no Preserve pitch")
        shot("02-choices")
        app.buttons["1.5×"].tap()
        sleep(1)

        app.buttons["nowPlayingMore"].tap()
        XCTAssert(speed.waitForExistence(timeout: 3))
        XCTAssert(speed.label.contains("1.5×"), "the speed isn't under the title: \(speed.label)")
        shot("03-more-sheet-at-1.5")
        speed.tap()
        XCTAssert(pitch.waitForExistence(timeout: 3))
        pitch.tap()
        sleep(1)
        app.buttons["nowPlayingMore"].tap()
        XCTAssert(speed.waitForExistence(timeout: 3))
        speed.tap()
        XCTAssert(pitch.waitForExistence(timeout: 3))
        shot("04-pitch-off")
        app.buttons["1×"].tap()
        sleep(1)
        app.buttons["nowPlayingPlayPause"].tap()
    }

    /// C22 (D91): Display's "Show Star Ratings" switch, then now playing's stars on the album's first
    /// song (its own song: `testPagesAndMenus` rates the second). Writes one rating of 4 and clears it
    /// again (D85), read back each time through the song menu.
    @MainActor
    func testStarRatings() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        guard let path = env["NAVINX_LIVE"] else { throw XCTSkip("No login file (TEST_RUNNER_NAVINX_LIVE)") }
        let login = try JSONDecoder().decode(Login.self, from: Data(contentsOf: URL(filePath: path)))
        if let dir = env["NAVINX_SHOTS"] {
            shots = URL(filePath: dir)
            try? FileManager.default.createDirectory(at: shots!, withIntermediateDirectories: true)
        }
        prefix = (env["NAVINX_SHOT_PREFIX"] ?? "") + "stars-"

        app = XCUIApplication()
        app.launchArguments = ["-UITestReset"]
        app.launch()
        signIn(login)

        // Off by default (Flutter), first in NOW PLAYING.
        let display = app.buttons["settingsTab-Display"]
        for _ in 0..<3 where !display.exists {
            app.buttons["librarySettingsGear"].tap()
            _ = display.waitForExistence(timeout: 4)
        }
        XCTAssert(display.exists, "the Library's gear didn't open Settings")
        display.tap()
        let toggle = app.switches["showsRatingStars"]
        XCTAssert(toggle.waitForExistence(timeout: 5), "no Show Star Ratings row")
        XCTAssertEqual(toggle.value as? String, "0", "the stars should be off by default")
        XCTAssertLessThan(toggle.frame.minY, app.switches["Live Lyrics Under Artwork"].frame.minY)
        shot("01-display")
        toggle.tap()
        XCTAssertEqual(toggle.value as? String, "1")
        app.navigationBars.buttons.firstMatch.tap()
        sleep(1)

        playAlbum()
        title.tap()
        XCTAssert(bigTitle.waitForExistence(timeout: 5))
        sleep(1)
        let stars = app.descendants(matching: .any)["nowPlayingStars"].firstMatch
        XCTAssert(stars.waitForExistence(timeout: 3), "no stars in now playing")
        // The test needs its song unrated: clear one left over from a stopped run first.
        if stars.value as? String != "0 of 5" {
            let current = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'star' AND selected == true"))
                .allElementsBoundByIndex.last
            current?.tap()
            sleep(3)
        }
        XCTAssertEqual(stars.value as? String, "0 of 5")
        XCTAssertLessThan(bigTitle.frame.maxY, stars.frame.minY, "the stars aren't under the title")
        shot("02-unrated")

        app.buttons["star4"].tap()
        XCTAssert(waitFor { stars.value as? String == "4 of 5" }, "star 4 didn't fill")
        XCTAssert(app.buttons["star4"].isSelected)
        XCTAssertFalse(app.buttons["star5"].isSelected)
        sleep(2)
        XCTAssertFalse(toast.exists, "the server didn't take the rating")
        shot("03-four-stars")
        // The song menu (the mini-player's long press) says the same (`latest`, the bug C22 fixed).
        songMenu()
        XCTAssert(app.buttons["Rate Song (4 stars)"].waitForExistence(timeout: 3), "the menu doesn't know the rating")
        shot("04-menu")
        dismissMenu()
        title.tap()
        XCTAssert(bigTitle.waitForExistence(timeout: 5))
        sleep(1)

        // A tap on the current rating clears it.
        app.buttons["star4"].tap()
        XCTAssert(waitFor { stars.value as? String == "0 of 5" }, "star 4 again didn't clear the rating")
        sleep(2)
        XCTAssertFalse(toast.exists, "the server didn't take the clearing")
        shot("05-cleared")
        songMenu()
        XCTAssert(menuItem("Rate Song").waitForExistence(timeout: 3), "the menu still has a rating")
        dismissMenu()
        app.buttons.matching(NSPredicate(format: "identifier == 'playerBarPlayPause' AND label == 'Pause'")).firstMatch.tap()
    }

    /// C22's pictures, with no rating written: the stars in landscape, and Display's row in dark mode.
    @MainActor
    func testStarRatingsLayout() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        guard let path = env["NAVINX_LIVE"] else { throw XCTSkip("No login file (TEST_RUNNER_NAVINX_LIVE)") }
        let login = try JSONDecoder().decode(Login.self, from: Data(contentsOf: URL(filePath: path)))
        if let dir = env["NAVINX_SHOTS"] {
            shots = URL(filePath: dir)
            try? FileManager.default.createDirectory(at: shots!, withIntermediateDirectories: true)
        }
        prefix = (env["NAVINX_SHOT_PREFIX"] ?? "") + "stars-layout-"
        if env["NAVINX_DUO"] != nil { return try starsOnTheDuo() }

        app = XCUIApplication()
        app.launchArguments = ["-UITestReset", "-player_show_star_ratings", "YES", "-app_theme_mode", "dark"]
        app.launch()
        signIn(login)
        playAlbum()
        title.tap()
        XCTAssert(bigTitle.waitForExistence(timeout: 5))
        sleep(1)
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(2)
        let stars = app.descendants(matching: .any)["nowPlayingStars"].firstMatch
        XCTAssert(stars.waitForExistence(timeout: 3), "no stars in landscape")
        XCTAssert(app.buttons["star5"].isHittable)
        shot("01-landscape")
        XCUIDevice.shared.orientation = .portrait
        sleep(2)
        app.buttons["nowPlayingPlayPause"].tap()
        closeButton.tap()
        XCTAssert(bigTitle.waitForNonExistence(timeout: 5))
        sleep(1)
        // Back from the album to the Library, where the gear is.
        app.navigationBars.buttons.firstMatch.tap()
        sleep(1)
        let display = app.buttons["settingsTab-Display"]
        for _ in 0..<3 where !display.exists {
            app.buttons["librarySettingsGear"].tap()
            _ = display.waitForExistence(timeout: 4)
        }
        display.tap()
        XCTAssert(app.switches["showsRatingStars"].waitForExistence(timeout: 5))
        sleep(1)
        shot("02-display-dark")
    }

    /// On the Duo, signed in already (a run of this test without `NAVINX_DUO` does it): the stars
    /// open, then half open (faked); on the inner display now playing is beside the app either way (C30
    /// bug 17). In the simulator's open posture the app is on the inner display: take the pictures with
    /// `simctl io <udid> screenshot --display=3`.
    @MainActor
    private func starsOnTheDuo() throws {
        for (name, hinge) in [("duo-open", "open"), ("duo-half-open", "partial")] {
            if app != nil, app.state != .notRunning { app.terminate() }
            app = XCUIApplication()
            app.launchArguments = ["-player_show_star_ratings", "YES", "-UITestHinge", hinge]
            app.launch()
            let bar = app.staticTexts["playerBarTitle"]
            XCTAssert(bar.waitForExistence(timeout: 10), "not signed in on the Duo")
            bar.tap()
            XCTAssert(app.buttons["nowPlayingClose"].waitForExistence(timeout: 5), "now playing didn't open (\(hinge))")
            // XCUIScreen's picture of the Duo is black: `simctl io --display=1` takes it meanwhile.
            sleep(8)
            let stars = app.buttons["star1"]
            if !stars.exists, let shots {
                try? app.debugDescription.write(to: shots.appending(path: "\(prefix)\(name).txt"), atomically: true, encoding: .utf8)
            }
            XCTAssert(stars.exists, "no stars on the Duo (\(hinge))")
        }
    }

    /// Closes now playing and opens the current song's menu with a long press on the mini-player.
    @MainActor
    private func songMenu() {
        closeButton.tap()
        XCTAssert(bigTitle.waitForNonExistence(timeout: 5))
        sleep(1)
        title.press(forDuration: 1.2)
        XCTAssert(app.buttons["Play Next"].waitForExistence(timeout: 5), "no menu from the mini-player")
    }

    @MainActor
    private func waitFor(_ timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            if condition() { return true }
            usleep(200_000)
        }
        return condition()
    }

    /// Flutter's lyrics settings, whose switches are C11's: the pill, centred lines and blur.
    @MainActor
    func testLyricsSettings() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        guard let path = env["NAVINX_LIVE"] else { throw XCTSkip("No login file (TEST_RUNNER_NAVINX_LIVE)") }
        let login = try JSONDecoder().decode(Login.self, from: Data(contentsOf: URL(filePath: path)))
        if let dir = env["NAVINX_SHOTS"] {
            shots = URL(filePath: dir)
            try? FileManager.default.createDirectory(at: shots!, withIntermediateDirectories: true)
        }
        prefix = (env["NAVINX_SHOT_PREFIX"] ?? "") + "settings-"

        app = XCUIApplication()
        app.launchArguments = [
            "-UITestReset",
            "-player_show_live_lyric_under_artwork", "YES",
            "-lyrics_alignment", "center",
            "-lyrics_blur_unfocused", "YES",
        ]
        app.launch()
        signIn(login)
        playAlbum()
        title.tap()
        XCTAssert(bigTitle.waitForExistence(timeout: 5))
        sleep(1)
        // The one song on `api` with lyrics (D44): untimed, so the pill shows its last line, as Flutter's would.
        goToSong(named: "Do Sum")
        let pill = app.buttons["currentLineCapsule"].firstMatch
        XCTAssert(pill.waitForExistence(timeout: 25), "no lyric pill under the cover")
        sleep(1)
        shot("01-pill")
        pill.tap()
        XCTAssert(backButton.waitForExistence(timeout: 3), "the pill didn't open the lyrics")
        sleep(2)
        shot("02-centred-blurred")
    }

    // MARK: The queue

    @MainActor
    private func queuePage() {
        let queue = app.buttons["nowPlayingQueue"]
        XCTAssert(queue.waitForExistence(timeout: 3))
        queue.tap()
        XCTAssert(app.staticTexts["Up Next"].waitForExistence(timeout: 3), "the queue page didn't show")
        XCTAssert(backButton.waitForExistence(timeout: 3), "no ✕ on the queue page")
        sleep(1)
        shot("03-queue")

        // A row plays its song, and the playing row moves.
        let before = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'queueRow' AND value == 'Playing'")).firstMatch.label
        let rows = visibleRows()
        XCTAssertGreaterThan(rows.count, 3)
        rows[3].coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.5)).tap()
        sleep(2)
        let after = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'queueRow' AND value == 'Playing'")).firstMatch.label
        XCTAssertNotEqual(before, after, "tapping a row didn't change the song")
        shot("04-queue-after-tap")

        // A pull down here scrolls the list; only the player's page closes.
        let queueList = app.descendants(matching: .any)["queueList"].firstMatch
        queueList.swipeDown(velocity: .fast)
        sleep(1)
        XCTAssert(backButton.exists, "a pull down on the queue closed the player")

        // ✕ goes back to the player, and swiping there brings the queue back.
        backButton.tap()
        XCTAssert(closeButton.waitForExistence(timeout: 3), "✕ didn't go back to the player")
        sleep(1)
        XCTAssert(bigTitle.isHittable)
    }

    @MainActor
    private func queueReorder() {
        app.buttons["nowPlayingQueue"].tap()
        XCTAssert(backButton.waitForExistence(timeout: 3))
        sleep(1)
        let handles = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Reorder'"))
            .allElementsBoundByIndex.filter { $0.isHittable }
        XCTAssertGreaterThan(handles.count, 3, "no reorder handles")
        let order = { self.visibleRows().map(\.label) }
        let before = order()
        handles[1].press(forDuration: 0.3, thenDragTo: handles[3], withVelocity: .slow, thenHoldForDuration: 0.3)
        sleep(1)
        XCTAssertNotEqual(before, order(), "dragging a handle didn't move the row")
        shot("05-queue-reordered")
        backButton.tap()
        sleep(1)
    }

    // MARK: Lyrics

    @MainActor
    private func lyricsPages() {
        // Swiped to from the player's page, on the title, away from the cover and the sliders. (On the
        // Duo the screen's edge is the system's strip, outside the app.)
        let titleRow = bigTitle.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5))
        titleRow.withOffset(CGVector(dx: 320, dy: 0)).press(
            forDuration: 0.05,
            thenDragTo: titleRow.withOffset(CGVector(dx: -20, dy: 0)),
            withVelocity: .fast,
            thenHoldForDuration: 0
        )
        let list = app.descendants(matching: .any)["lyricsList"].firstMatch
        let none = app.descendants(matching: .any)["noLyrics"].firstMatch
        XCTAssert(backButton.waitForExistence(timeout: 3), "the swipe didn't leave the player's page")
        XCTAssert(list.waitForExistence(timeout: 25) || none.exists, "lyrics never finished loading")
        sleep(1)
        shot(list.exists ? "06-lyrics" : "06-no-lyrics")

        backButton.tap()
        sleep(1)

        // Songs with their own lyrics from the server have no timings ("Do Sum"): a tap stays put.
        goToSong(named: "Do Sum")
        app.buttons["nowPlayingLyrics"].tap()
        XCTAssert(list.waitForExistence(timeout: 15), "no lyrics for the song that has them")
        sleep(1)
        shot("07-lyrics-unsynced")
        let time = app.sliders["Seek"]
        _ = time
        backButton.tap()
        sleep(1)

        // A song LRCLIB doesn't have (D44): no lyrics, rather than another song's.
        goToSong(named: "Brand New Jeep")
        app.buttons["nowPlayingLyrics"].tap()
        XCTAssert(none.waitForExistence(timeout: 25), "a song with no lyrics anywhere should say so")
        XCTAssertFalse(list.exists)
        shot("08-no-lyrics-found")
        backButton.tap()
        sleep(1)
    }

    /// Through the queue page, whichever the song's row is.
    @MainActor
    private func goToSong(named name: String) {
        app.buttons["nowPlayingQueue"].tap()
        XCTAssert(backButton.waitForExistence(timeout: 3))
        sleep(1)
        let list = app.descendants(matching: .any)["queueList"].firstMatch
        let row = app.staticTexts[name].firstMatch
        for _ in 0..<8 where !(row.exists && row.isHittable) {
            list.swipeUp(velocity: .slow)
        }
        for _ in 0..<8 where !(row.exists && row.isHittable) {
            list.swipeDown(velocity: .slow)
        }
        XCTAssert(row.isHittable, "\(name) isn't in the queue")
        row.tap()
        sleep(1)
        backButton.tap()
        sleep(1)
        XCTAssertEqual(bigTitle.label, name)
    }

    // MARK: The menus

    @MainActor
    private func openMoreSheet() {
        app.buttons["nowPlayingMore"].tap()
        let timer = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Sleep Timer'")).firstMatch
        XCTAssert(timer.waitForExistence(timeout: 3), "the ⋯ menu has no sleep timer")
        shot("09-more-sheet")
        timer.tap()
        XCTAssert(app.buttons["5 min"].waitForExistence(timeout: 3), "no sleep timer choices")
        for choice in ["Off", "10 min", "15 min", "30 min", "End of Song"] {
            XCTAssert(app.buttons[choice].exists, "no \(choice)")
        }
        shot("10-sleep-timer-choices")
        app.buttons["5 min"].tap()
        sleep(2)
        // While playing, the time left ticks in the open menu, and XCUITest then takes minutes per
        // step waiting for the screen to settle (seen working: it ticks with the submenu open).
        app.buttons["nowPlayingPlayPause"].tap()
        app.buttons["nowPlayingMore"].tap()
        XCTAssert(timer.waitForExistence(timeout: 3))
        // XCUITest can wait a minute for this animated screen to settle, so any time left will do.
        let hasTimeLeft = timer.label.range(of: #"Sleep Timer, \d:\d\d"#, options: .regularExpression) != nil
        XCTAssert(hasTimeLeft, "the time left isn't showing: \(timer.label)")
        shot("11-sleep-timer-running")
        timer.tap()
        XCTAssert(app.buttons["Off"].waitForExistence(timeout: 3))
        app.buttons["Off"].tap()
        sleep(1)
        app.buttons["nowPlayingPlayPause"].tap()
    }

    @MainActor
    private func openAddSheet() {
        let addToButton = app.buttons["nowPlayingAddTo"]
        addToButton.tap()
        XCTAssert(app.buttons["Add to Playlist"].waitForExistence(timeout: 3), "the + menu didn't open")
        XCTAssertFalse(app.buttons["Add to Library"].exists, "Add to Library should be gone (D41)")
        shot("12-add-sheet")

        // A favourite on and off again; the heart follows.
        menuItem("Add to Favorites").tap()
        XCTAssert(menuItem("Remove from favorites").waitForExistence(timeout: 5), "the heart didn't change")
        sleep(3)
        addToButton.tap()
        XCTAssert(menuItem("Remove from Favorites").waitForExistence(timeout: 3))
        menuItem("Remove from Favorites").tap()
        XCTAssert(menuItem("Add to favorites").waitForExistence(timeout: 5))
        sleep(3)

        // Add to Playlist: a sheet, then a duplicate on the second try.
        addToButton.tap()
        XCTAssert(app.buttons["Add to Playlist"].waitForExistence(timeout: 3))
        app.buttons["Add to Playlist"].tap()
        XCTAssert(app.staticTexts["Select Playlist"].waitForExistence(timeout: 5), "no playlist sheet")
        let row = app.buttons["playlistChooserRow"].firstMatch
        guard row.waitForExistence(timeout: 5) else {
            shot("13-no-playlists")
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()
            sleep(1)
            return
        }
        shot("13-playlist-chooser")
        row.tap()
        // The duplicate warning below shows this took (the playlist must start without this song).
        _ = toast.waitForExistence(timeout: 3)
        shot("14-added-to-playlist")
        sleep(3)
        addToButton.tap()
        XCTAssert(app.buttons["Add to Playlist"].waitForExistence(timeout: 3))
        app.buttons["Add to Playlist"].tap()
        XCTAssert(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssert(app.alerts["Already in playlist"].waitForExistence(timeout: 8), "no duplicate warning")
        shot("15-already-in-playlist")
        app.alerts.buttons["Cancel"].tap()
        sleep(1)
    }

    /// The pages' sideways scroll mustn't take over from what already moves sideways.
    @MainActor
    private func coverAndSliders() {
        let songTitle = bigTitle.label
        let cover = app.descendants(matching: .any)["nowPlayingCover"].firstMatch
        cover.swipeLeft(velocity: .fast)
        let changed = NSPredicate { _, _ in self.bigTitle.label != songTitle }
        wait(for: [XCTNSPredicateExpectation(predicate: changed, object: nil)], timeout: 8)
        XCTAssert(closeButton.exists, "a swipe on the cover changed the page")
        cover.swipeRight(velocity: .fast)
        sleep(2)
        XCTAssert(closeButton.exists, "a swipe on the cover changed the page")

        let seek = app.sliders["Seek"].firstMatch
        XCTAssert(seek.exists)
        let before = seek.value as? String
        seek.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: seek.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5)))
        sleep(1)
        XCTAssert(closeButton.exists, "dragging the scrubber changed the page")
        XCTAssertNotEqual(before, seek.value as? String, "dragging the scrubber didn't seek")
        shot("16-after-scrubber-drag")
    }

    @MainActor
    private func songOptionsFromQueue() {
        app.buttons["nowPlayingQueue"].tap()
        XCTAssert(backButton.waitForExistence(timeout: 3))
        sleep(1)
        let options = app.buttons.matching(NSPredicate(format: "label == 'Song options'"))
            .allElementsBoundByIndex.filter { $0.isHittable }
        XCTAssertGreaterThan(options.count, 1, "no ⋯ on the queue's rows")
        options[1].tap()
        XCTAssert(app.buttons["Play Next"].waitForExistence(timeout: 3), "the row's ⋯ didn't open")
        shot("17-queue-row-menu")

        // Rate, then take it off again; the row's menu remembers in between.
        let rate = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Rate Song'")).firstMatch
        rate.tap()
        let three = app.buttons["★★★☆☆"]
        XCTAssert(three.waitForExistence(timeout: 3), "no stars")
        shot("18-rate-song")
        three.tap()
        // Its 2-second message can be gone before the tap returns; the next menu shows it took.
        sleep(3)
        options[1].tap()
        let rated = app.buttons["Rate Song (3 stars)"]
        XCTAssert(rated.waitForExistence(timeout: 3), "the menu forgot the rating")
        rated.tap()
        XCTAssert(app.buttons["Remove Rating"].waitForExistence(timeout: 3))
        app.buttons["Remove Rating"].tap()
        sleep(3)
        options[1].tap()
        XCTAssert(app.buttons["Rate Song"].waitForExistence(timeout: 3), "the rating didn't come off")
        dismissMenu()

        // A row's long press has the same menu.
        visibleRows()[2].press(forDuration: 1.2)
        XCTAssert(app.buttons["Play Next"].waitForExistence(timeout: 5), "no menu on a long press")
        shot("19-queue-long-press")
        dismissMenu()
        sleep(1)

        // Add to Queue and Play Next: the queue grows.
        options[1].tap()
        XCTAssert(app.buttons["Play Next"].waitForExistence(timeout: 3))
        app.buttons["Play Next"].tap()
        sleep(1)
        shot("20-after-play-next")

        // Go to Album closes the player and opens the page underneath.
        options[1].tap()
        XCTAssert(app.buttons["Go to Album"].waitForExistence(timeout: 3))
        app.buttons["Go to Album"].tap()
        XCTAssert(bigTitle.waitForNonExistence(timeout: 5), "Go to Album didn't close the player")
        sleep(2)
        shot("21-went-to-album")
        title.tap()
        XCTAssert(bigTitle.waitForExistence(timeout: 5))
        sleep(1)

        // Go to Artist does the same. Arriving scrolls to the current song, so "Up Next" can be gone.
        app.buttons["nowPlayingQueue"].tap()
        XCTAssert(backButton.waitForExistence(timeout: 3))
        sleep(1)
        app.buttons.matching(NSPredicate(format: "label == 'Song options'"))
            .allElementsBoundByIndex.first { $0.isHittable }?.tap()
        XCTAssert(app.buttons["Go to Artist"].waitForExistence(timeout: 3))
        app.buttons["Go to Artist"].tap()
        XCTAssert(bigTitle.waitForNonExistence(timeout: 5), "Go to Artist didn't close the player")
        sleep(2)
        shot("21b-went-to-artist")
        title.tap()
        XCTAssert(bigTitle.waitForExistence(timeout: 5))
        sleep(1)
    }

    @MainActor
    private func landscape() {
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(2)
        shot("22-landscape-player")
        app.buttons["nowPlayingQueue"].tap()
        sleep(2)
        shot("23-landscape-queue")
        backButton.tap()
        sleep(1)
        app.buttons["nowPlayingLyrics"].tap()
        sleep(2)
        shot("24-landscape-lyrics")
        // A page fills the screen: the queue's rows mustn't show at the lyrics page's edge.
        let window = app.windows.firstMatch.frame
        let peeking = app.descendants(matching: .any).matching(identifier: "queueRow").allElementsBoundByIndex
            .filter { window.intersects($0.frame) && $0.frame.minX < window.maxX }
        XCTAssert(peeking.isEmpty, "\(peeking.count) queue rows are showing on the lyrics page")
        backButton.tap()
        sleep(1)
        XCUIDevice.shared.orientation = .portrait
        sleep(2)
        XCTAssert(closeButton.waitForExistence(timeout: 3))
        closeButton.tap()
        XCTAssert(bigTitle.waitForNonExistence(timeout: 5), "the chevron didn't close it")
        sleep(1)
    }

    /// The same menus from a list's rows.
    @MainActor
    private func rowsInLists() {
        let options = app.buttons.matching(NSPredicate(format: "label == 'Song options'"))
            .allElementsBoundByIndex.filter { $0.isHittable }
        XCTAssertGreaterThan(options.count, 0, "no ⋯ on the album's rows")
        options[0].tap()
        XCTAssert(app.buttons["Play Next"].waitForExistence(timeout: 3), "a song row's ⋯ didn't open")
        shot("25-song-row-menu")
        dismissMenu()
        sleep(1)
    }

    // MARK: Getting there

    @MainActor
    private func signIn(_ login: Login) {
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
            sleep(2)
        }
        XCTAssert(app.buttons["Library"].firstMatch.waitForExistence(timeout: 15))
        let liked = app.staticTexts["Playlist • Favorites"]
        for _ in 0..<3 where !liked.exists {
            if notNow.exists {
                notNow.tap()
                sleep(2)
            }
            app.buttons.matching(NSPredicate(format: "label == 'Library'")).allElementsBoundByIndex
                .first { $0.isHittable }?.tap()
            _ = liked.waitForExistence(timeout: 4)
        }
        XCTAssert(liked.exists, "the Library tab didn't open")
        let layout = app.buttons["libraryLayout"]
        XCTAssert(layout.waitForExistence(timeout: 5))
        if layout.label == "Switch to List" { layout.tap() }
        if notNow.waitForExistence(timeout: 8) {
            notNow.tap()
            sleep(2)
        }
    }

    @MainActor
    private func playAlbum() {
        // The album with the most songs, "me", through Search: the Library lists no albums since D210.
        XCTAssert(app.openAlbumFromSearch("me"), "this test needs the album \"me\"")
        sleep(1)
        app.pagePlayButton.tap()
        // The bar always has a song (D81): it's the Pause button that says the album started.
        let pause = app.buttons.matching(NSPredicate(format: "identifier == 'playerBarPlayPause' AND label == 'Pause'")).firstMatch
        XCTAssert(pause.waitForExistence(timeout: 10), "the album didn't start")
        sleep(2)
    }

    @MainActor
    private func visibleRows() -> [XCUIElement] {
        app.descendants(matching: .any).matching(identifier: "queueRow").allElementsBoundByIndex
            .filter { $0.exists && $0.isHittable }
    }

    /// Exactly this label: the heart's is the same but for its case, and `buttons[…]` finds both.
    @MainActor
    private func menuItem(_ label: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    @MainActor
    private func dismissMenu() {
        // The dimmed margin: a tap in the status bar doesn't close a menu.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0.42)).tap()
        sleep(1)
    }

    @MainActor
    private func shot(_ name: String) {
        guard let shots else { return }
        let png = XCUIScreen.main.screenshot().pngRepresentation
        try? png.write(to: shots.appending(path: "\(prefix)\(name).png"))
    }
}
