import XCTest

/// Settings (C11), against a real server, saving a screenshot at each step: every tab's rows, the
/// menus next to their rows, the switches taking effect, the theme and accent, the alerts, and
/// both gears. The theme is the app's own setting, so the walk takes its light and dark shots by
/// choosing it.
///
/// **It signs in as the login given; use the test account `api`** (D55). It changes only this
/// app's own settings and puts them back; only `testAccentColours` writes to the server
/// (it plays a song: now-playing and a play count). Skipped without `TEST_RUNNER_NAVINX_LIVE`.
final class SettingsUITests: XCTestCase {
    private struct Login: Decodable { let url: String; let username: String; let password: String }

    private var app: XCUIApplication!
    private var login: Login!
    private var shots: URL?
    private var prefix = ""

    override func setUpWithError() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        guard let path = env["NAVINX_LIVE"] else { throw XCTSkip("No login file (TEST_RUNNER_NAVINX_LIVE)") }
        login = try JSONDecoder().decode(Login.self, from: Data(contentsOf: URL(filePath: path)))
        if let dir = env["NAVINX_SHOTS"] {
            shots = URL(filePath: dir)
            try? FileManager.default.createDirectory(at: shots!, withIntermediateDirectories: true)
        }
        prefix = env["NAVINX_SHOT_PREFIX"] ?? "c11-"
    }

    @MainActor
    func testSettings() throws {
        app = XCUIApplication()
        app.launchArguments = ["-UITestReset"]
        app.launch()
        signIn()

        // Home's gear opens Settings on Playback (D14).
        tab("Home")
        openSettings(gear: "settingsGear")
        for name in ["Playback", "Storage", "Server", "Display", "About"] {
            XCTAssert(app.buttons["settingsTab-\(name)"].exists, "no \(name) tab")
        }
        XCTAssertFalse(app.buttons["settingsTab-Support"].exists)
        for theme in ["Light", "Dark"] {
            setTheme(theme)
            walkTabs(theme.lowercased())
        }
        setTheme("System")
        app.buttons["settingsTab-Playback"].waitAndTap()

        // Playback: gapless is on; ReplayGain's menu next to its row.
        let gapless = app.switches["Gapless Playback"]
        XCTAssert(gapless.waitForExistence(timeout: 5))
        XCTAssertEqual(gapless.value as? String, "1")
        let anyPreamp = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Preamp: '")).firstMatch
        XCTAssertFalse(anyPreamp.exists, "Off shows no sliders")
        choose("Track", in: "Mode menu", shot: "menu-replaygain")
        XCTAssert(anyPreamp.waitForExistence(timeout: 3), "Track shows the sliders")
        XCTAssert(app.staticTexts["Fallback Gain: -6.0 dB"].exists)
        XCTAssertEqual(app.switches["Prevent Clipping"].value as? String, "1")
        app.sliders["replayGainPreamp"].adjust(toNormalizedSliderPosition: 0.75)
        // Whole steps of 1 dB, upwards (where the drag lands varies by a step or so).
        let preamp = app.staticTexts.matching(NSPredicate(format: "label MATCHES 'Preamp: [1-9][0-9]?\\.0 dB'")).firstMatch
        XCTAssert(preamp.waitForExistence(timeout: 3), "the slider didn't step up in whole dB")
        shot("playback-replaygain")
        // Back to 0 dB, nudging until the drag lands on it.
        for position in [0.5, 0.51, 0.49, 0.52, 0.48] where !app.staticTexts["Preamp: 0.0 dB"].exists {
            app.sliders["replayGainPreamp"].adjust(toNormalizedSliderPosition: position)
            _ = app.staticTexts["Preamp: 0.0 dB"].waitForExistence(timeout: 2)
        }
        XCTAssert(app.staticTexts["Preamp: 0.0 dB"].exists, "the preamp didn't go back to 0")
        choose("Off", in: "Mode menu")
        XCTAssert(anyPreamp.waitForNonExistence(timeout: 3))

        // Transcoding: off; on shows the two qualities and the format, with no Smart switch (D66).
        let transcoding = app.switches["Adjust Streaming Quality"]
        XCTAssertEqual(transcoding.value as? String, "0")
        XCTAssertFalse(app.staticTexts["Wi-Fi Quality"].exists)
        transcoding.tap()
        XCTAssert(app.staticTexts["Wi-Fi Quality"].waitForExistence(timeout: 3), "transcoding on shows the qualities")
        XCTAssert(app.staticTexts["Mobile Quality"].exists)
        XCTAssert(app.staticTexts["Format"].exists)
        XCTAssertFalse(app.staticTexts["Smart Transcoding"].exists)
        app.swipeUp()
        choose("128 kbps", in: "Wi-Fi Quality menu", shot: "menu-wifi-quality")
        XCTAssertEqual(app.buttons["Wi-Fi Quality menu"].value as? String, "128 kbps")
        XCTAssertEqual(app.buttons["Mobile Quality menu"].value as? String, "192 kbps", "Mobile Quality isn't 192 by default")
        choose("AAC", in: "Format menu", shot: "menu-format")
        shot("playback-transcoding")
        choose("MP3", in: "Format menu")
        choose("Original (No Transcoding)", in: "Wi-Fi Quality menu")
        app.switches["Adjust Streaming Quality"].tap()
        XCTAssert(app.staticTexts["Wi-Fi Quality"].waitForNonExistence(timeout: 3))

        // Storage: the artwork cache clears with its message; Playlist Downloads opens.
        app.swipeDown()
        app.buttons["settingsTab-Storage"].waitAndTap()
        XCTAssert(app.staticTexts["Artwork Cache"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["Songs & Streaming Cache"].exists)
        XCTAssertFalse(app.staticTexts["Parallel Downloads"].exists)
        // The cache's own index stays, so the size drops rather than reaching 0 B.
        let artworkSize = app.staticTexts.matching(NSPredicate(format: "label ENDSWITH 'used on disk'")).firstMatch
        let before = artworkSize.label
        app.buttons["Clear image cache"].waitAndTap()
        expectToast("Artwork cache cleared")
        XCTAssert(waitFor { artworkSize.label != before }, "the size stayed at \(before)")
        app.buttons["clearAllCache"].tap()
        expectToast("All cache cleared")
        app.buttons["playlistDownloadsRow"].waitAndTap()
        XCTAssert(app.navigationBars["Playlist Downloads"].waitForExistence(timeout: 5))
        goBack()
        XCTAssert(app.buttons["settingsTab-Storage"].waitForExistence(timeout: 5))

        // Server: the card, the saved server, and the switcher with no Settings row (D14).
        app.buttons["settingsTab-Server"].waitAndTap()
        XCTAssert(app.staticTexts["CONNECTED"].waitForExistence(timeout: 3))
        XCTAssert(app.staticTexts["ACTIVE"].exists)
        XCTAssert(app.staticTexts[login.username].exists)
        app.buttons["settingsSwitchServer"].tap()
        XCTAssert(app.buttons["addServer"].waitForExistence(timeout: 5), "the switcher didn't open")
        XCTAssert(app.staticTexts["Switch Server"].exists)
        // The page's title says "Settings"; the switcher's old row was a button.
        let settingsRow = app.buttons.matching(NSPredicate(format: "label == 'Settings' AND NOT (identifier CONTAINS 'ettingsGear')"))
        XCTAssertEqual(settingsRow.count, 0, "the switcher still has a Settings row")
        sleep(1)
        shot("server-switcher")
        app.swipeDown(velocity: .fast)
        XCTAssert(app.buttons["addServer"].waitForNonExistence(timeout: 5))
        app.buttons["settingsManageServers"].tap()
        XCTAssert(app.buttons["addServer"].waitForExistence(timeout: 5), "Manage didn't open the switcher")
        app.swipeDown(velocity: .fast)
        XCTAssert(app.buttons["addServer"].waitForNonExistence(timeout: 5))
        app.buttons["settingsAddServer"].tap()
        XCTAssert(app.buttons["connectAndSave"].waitForExistence(timeout: 5), "Add Server didn't open")
        goBack()
        app.buttons["settingsLogout"].waitAndTap()
        XCTAssert(app.alerts["Sign Out"].waitForExistence(timeout: 3))
        XCTAssert(app.alerts.staticTexts["Sign out of this server? Its downloads and the app's cached data are removed from this iPhone. The server stays in your saved list."].exists)
        shot("server-logout-question")
        app.alerts.buttons["Cancel"].tap()

        // Display: an accent can be picked (it tints only the tab bar, D72), Home's switch, and
        // Clear asks first.
        app.buttons["settingsTab-Display"].waitAndTap()
        app.buttons["accent-blue"].waitAndTap()
        XCTAssert(app.buttons["accent-blue"].isSelected)
        shot("display-accent-blue")
        app.buttons["accent-purple"].tap()
        XCTAssert(app.buttons["accent-purple"].isSelected)
        let favorites = app.switches["Favorite playlists on Home"]
        XCTAssertEqual(favorites.value as? String, "0")
        favorites.tap()
        XCTAssertEqual(favorites.value as? String, "1")
        favorites.tap()
        XCTAssertEqual(favorites.value as? String, "0")
        app.swipeUp()
        XCTAssert(app.descendants(matching: .any)["listeningData"].waitForExistence(timeout: 3))
        app.buttons["clearListeningHistory"].waitAndTap()
        XCTAssert(app.alerts["Clear Listening History"].waitForExistence(timeout: 3))
        shot("display-clear-question")
        app.alerts.buttons["Cancel"].tap()
        app.swipeDown()

        // About: the version, the platform and the credit.
        app.buttons["settingsTab-About"].waitAndTap()
        XCTAssert(app.staticTexts["aboutVersion"].waitForExistence(timeout: 3))
        XCTAssert(app.staticTexts["aboutPlatform"].label.hasPrefix("iOS "))
        let credit = app.descendants(matching: .any)["aboutMusly"]
        XCTAssert(credit.exists && !app.buttons["aboutMusly"].exists, "the credit is a link again")

        // The pages swipe too.
        // A drag across the page, clear of the screen's edge (which goes back): `swipeRight` on a
        // short element travels only its width.
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.6))
        start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.6)))
        XCTAssert(waitFor { self.app.buttons["settingsTab-Display"].isSelected }, "a swipe didn't move to Display")

        // The Library's gear opens Settings as well.
        goBack()
        tab("Library")
        openSettings(gear: "librarySettingsGear")
        goBack()
    }

    /// Playback's crossfade and fade sections (C19), in Flutter's order and words: the crossfade's
    /// row and slider at Off and at 6 s, the fade's switch showing its 50 ms slider. Writes nothing;
    /// `-UITestReset` puts the three settings back at the next launch.
    @MainActor
    func testCrossfadeAndFade() throws {
        app = XCUIApplication()
        app.launchArguments = ["-UITestReset"]
        app.launch()
        signIn()
        tab("Home")
        openSettings(gear: "settingsGear")
        let crossfade = app.staticTexts["Crossfade"]
        XCTAssert(crossfade.waitForExistence(timeout: 5))
        XCTAssert(app.staticTexts["Off (Instant transition)"].exists)
        XCTAssertEqual(app.staticTexts["crossfadeBadge"].label, "Off")
        // Above Gapless, the fade's section under it.
        let gapless = app.switches["Gapless Playback"]
        let fade = app.switches["Fade on Play and Pause"]
        XCTAssert(crossfade.frame.minY < gapless.frame.minY && gapless.frame.minY < fade.frame.minY)
        XCTAssertEqual(fade.value as? String, "0")
        shot("playback-crossfade-off")
        let slider = app.sliders["crossfadeSlider"]
        // Whole seconds near the middle (where the drag lands varies by a step or so).
        let seconds = app.staticTexts.matching(NSPredicate(format: "label MATCHES '[4-8] seconds crossfade between songs'")).firstMatch
        slider.adjust(toNormalizedSliderPosition: 0.5)
        XCTAssert(seconds.waitForExistence(timeout: 3), "the slider didn't land near 6 s")
        let value = seconds.label.prefix { $0.isNumber }
        XCTAssertEqual(app.staticTexts["crossfadeBadge"].label, "\(value)s")
        fade.tap()
        let duration = app.staticTexts["Fade Duration: 300ms"]
        XCTAssert(duration.waitForExistence(timeout: 3))
        app.sliders["fadeDuration"].adjust(toNormalizedSliderPosition: 0.5)
        let stepped = app.staticTexts.matching(NSPredicate(format: "label MATCHES 'Fade Duration: [0-9]+[05]0ms'")).firstMatch
        XCTAssert(stepped.waitForExistence(timeout: 3), "the fade's slider isn't in 50 ms steps")
        sleep(1)
        shot("playback-crossfade-6-fade-on")
    }

    /// Auto DJ (C21, D90): its section first on Playback, Flutter's words; Similar Songs shows "Songs
    /// to Add"; a one-song album then gets songs under "Autoplay" in the queue, and the queue's ∞
    /// turns it off and takes them out. **Writes to the server as the login given:** now-playing (and
    /// maybe a play count) for the album's song; use `api`. `-UITestReset` puts the mode back.
    @MainActor
    func testRefill() throws {
        app = XCUIApplication()
        app.launchArguments = ["-UITestReset"]
        app.launch()
        signIn()
        tab("Home")
        openSettings(gear: "settingsGear")
        let mode = app.buttons["Auto DJ Mode menu"]
        XCTAssert(mode.waitForExistence(timeout: 5))
        XCTAssert(app.staticTexts["AUTOPLAY"].exists)
        XCTAssert(mode.frame.minY < app.staticTexts["Crossfade"].frame.minY, "Autoplay isn't first")
        XCTAssertFalse(app.sliders["refillCountChoice"].exists)
        shot("refill-01-off")
        mode.tap()
        let similar = app.buttons["Similar Songs"].firstMatch
        XCTAssert(similar.waitForExistence(timeout: 3))
        sleep(1)
        shot("refill-02-menu")
        similar.tap()
        XCTAssert(app.staticTexts["Songs to Add: 5"].waitForExistence(timeout: 3))
        sleep(1)
        shot("refill-03-similar")
        goBack()

        // A one-song album: nothing left after it, so Auto DJ adds straight away.
        // Through Search: the Library lists no albums since D210.
        XCTAssert(app.openAlbumFromSearch("Pow Wow"), "this test needs the album \"Pow Wow\"")
        sleep(1)
        app.pagePlayButton.tap()
        let barTitle = app.staticTexts["playerBarTitle"]
        XCTAssert(barTitle.waitForExistence(timeout: 15))
        sleep(3)
        barTitle.tap()
        let queueButton = app.buttons["nowPlayingQueue"]
        XCTAssert(queueButton.waitForExistence(timeout: 5))
        queueButton.tap()
        XCTAssert(app.staticTexts["Up Next"].waitForExistence(timeout: 3))
        let heading = app.descendants(matching: .any)["autoplayHeading"].firstMatch
        XCTAssert(heading.waitForExistence(timeout: 10), "no Autoplay songs arrived")
        let toggle = app.buttons["refillToggle"]
        XCTAssertEqual(toggle.value as? String, "Similar Songs")
        let rows = app.descendants(matching: .any).matching(identifier: "queueRow")
        XCTAssertGreaterThan(rows.count, 1)
        sleep(1)
        shot("refill-04-queue-autoplay")
        toggle.tap()
        XCTAssert(heading.waitForNonExistence(timeout: 3), "turning Auto DJ off left its songs")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(toggle.value as? String, "Off")
        sleep(1)
        shot("refill-05-queue-off")
    }

    /// Back from Settings, from both gears and from each of Settings' tabs: its strip and title go.
    /// The C11 review's bug (the title drawn on over the page behind for about half a second after
    /// the pop) passed this too, as XCUITest drops the element at once; it shows only in a screen
    /// recording, lined up with `NAVINX_MARKS` (`docs/gotchas.md`). Writes nothing.
    @MainActor
    func testBackLeavesNoSettings() throws {
        app = XCUIApplication()
        app.launchArguments = ["-UITestReset"]
        app.launch()
        signIn()
        let cases: [(tab: String, gear: String, page: String)] =
            [("Home", "settingsGear", "Playback"), ("Library", "librarySettingsGear", "Playback")]
            + ["Storage", "Server", "Display", "About"].map { ("Home", "settingsGear", $0) }
        for item in cases {
            tab(item.tab)
            openSettings(gear: item.gear)
            app.buttons["settingsTab-\(item.page)"].waitAndTap()
            sleep(1)
            mark("back \(item.tab) \(item.page)")
            let back = app.navigationBars.buttons.firstMatch
            back.tap()
            // The pop's own animation takes about 0.35 s; well before a second, Settings is gone.
            let strip = app.buttons["settingsTab-Playback"]
            let title = app.staticTexts.matching(NSPredicate(format: "label == 'Settings'")).firstMatch
            XCTAssert(strip.waitForNonExistence(timeout: 0.7), "Settings' strip is still there after Back (\(item.page))")
            XCTAssertFalse(title.exists, "Settings' title is still there after Back (\(item.page))")
            XCTAssert(app.buttons[item.gear].waitForExistence(timeout: 3))
            sleep(2)
        }
    }

    /// The accent colours what it coloured in C11 (D72): with green chosen, the tab bar's selected
    /// tab, Settings' strip underline and selected Theme, the Library's sort button, an album's
    /// artist and Play, now playing's Shuffle (on) and the Add tab's backdrop are green. Settings'
    /// strip label, the gears' capsules and the filter chips are the primary colour (no red, no
    /// green), and the destructive Logout stays red with no green. Takes the theme from
    /// `TEST_RUNNER_NAVINX_THEME` (`light` or `dark`; else System) and saves a shot of each page
    /// (Settings, Home, the Library, an album playing, now playing, Add). It plays a song (a
    /// now-playing and a play count, D55) and puts the accent and theme back.
    @MainActor
    func testAccentColours() throws {
        app = XCUIApplication()
        app.launchArguments = ["-UITestReset"]
        app.launch()
        signIn()
        var problems: [String] = []
        /// `red: nil` where the red covers can show through (the tab bar's glass, now playing).
        func expect(_ frame: CGRect, _ name: String, green: Bool, red: Bool?) {
            let (greens, reds) = colorCounts(in: frame)
            if green != (greens >= 12) { problems.append("\(name): \(greens) green pixels") }
            if let red, red != (reds >= 12) { problems.append("\(name): \(reds) red pixels") }
        }
        func expect(_ element: XCUIElement, _ name: String, green: Bool, red: Bool?) {
            XCTAssert(element.exists, "\(name) isn't there")
            expect(element.frame, name, green: green, red: red)
        }
        let homeTab = app.tabBars.buttons["Home"].exists ? app.tabBars.buttons["Home"] : app.buttons["Home"].firstMatch
        let theme = ProcessInfo.processInfo.environment["NAVINX_THEME"].map { $0.capitalized } ?? "System"
        let name = "accent-green-\(theme.lowercased())"

        tab("Home")
        openSettings(gear: "settingsGear")
        setTheme(theme)
        app.buttons["accent-green"].waitAndTap()
        XCTAssert(app.buttons["accent-green"].isSelected)
        sleep(1)
        shot("\(name)-settings")
        // The selected tab: its icon and label primary, its underline (the bottom 9 pt) green.
        let selected = app.buttons["settingsTab-Display"].frame
        let (label, underline) = selected.divided(atDistance: selected.height - 9, from: .minYEdge)
        expect(label, "Settings' selected tab's icon and label", green: false, red: false)
        expect(underline, "Settings' selected tab's underline", green: true, red: false)
        expect(app.buttons["theme-\(theme)"], "the selected Theme", green: true, red: false)
        // Settings has no tab bar (C30, D124): the selected tab is checked on Home below.
        XCTAssertFalse(homeTab.exists && homeTab.isHittable, "Settings shows no tab bar (D124)")
        // Destructive stays red: Sign Out's row and its alert's button.
        app.buttons["settingsTab-Server"].waitAndTap()
        expect(app.buttons["settingsLogout"], "the Sign Out row", green: false, red: true)
        app.buttons["settingsLogout"].waitAndTap()
        let logout = app.alerts["Sign Out"]
        XCTAssert(logout.waitForExistence(timeout: 3))
        sleep(1)
        shot("\(name)-alert")
        expect(logout.buttons["Sign Out"], "Sign Out's alert button", green: false, red: true)
        logout.buttons["Cancel"].tap()
        app.buttons["settingsTab-Display"].waitAndTap()
        sleep(1)

        goBack()
        sleep(1)
        shot("\(name)-home")
        expect(homeTab, "the selected tab on Home", green: true, red: nil)
        // The chips, selected and not, and the gears' capsules: primary (D72).
        expect(app.buttons["All"].firstMatch, "Home's All chip", green: false, red: false)
        expect(app.buttons["Made For You"].firstMatch, "Home's Made For You chip", green: false, red: false)
        expect(app.buttons["homeHistory"], "Home's History clock", green: false, red: false)
        expect(app.buttons["settingsGear"], "Home's gear", green: false, red: false)
        tab("Library")
        XCTAssert(app.buttons["librarySettingsGear"].waitForExistence(timeout: 5))
        sleep(1)
        shot("\(name)-library")
        expect(app.buttons["libraryAdd"].firstMatch, "the Library's add", green: false, red: false)
        expect(app.buttons["librarySettingsGear"], "the Library's gear", green: false, red: false)
        expect(app.buttons["librarySort"], "the Library's sort button", green: true, red: false)

        // An album, with a song playing in the mini-player, and now playing.
        openAlbum("me")
        expect(app.pagePlayButton, "the album's Play", green: true, red: false)
        app.staticTexts["Do Sum"].firstMatch.tap()
        let bar = app.staticTexts["playerBarTitle"]
        XCTAssert(bar.waitForExistence(timeout: 10), "the song didn't start")
        // The bar always has a song (D81): wait for this one.
        let started = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'Do Sum'"), object: bar)
        XCTAssertEqual(XCTWaiter().wait(for: [started], timeout: 10), .completed, "the song didn't start")
        sleep(3)
        shot("\(name)-album")
        bar.tap()
        XCTAssert(app.staticTexts["nowPlayingElapsed"].waitForExistence(timeout: 5))
        let shuffle = app.buttons["nowPlayingShuffle"]
        shuffle.waitAndTap()
        sleep(2)
        shot("\(name)-now-playing")
        expect(shuffle, "now playing's Shuffle", green: true, red: nil)
        shuffle.tap()
        app.buttons.matching(NSPredicate(format: "identifier == 'nowPlayingClose' AND label == 'Close'")).firstMatch.waitAndTap()
        XCTAssert(app.staticTexts["nowPlayingElapsed"].waitForNonExistence(timeout: 5))
        app.buttons["playerBarPlayPause"].firstMatch.tap()

        // Back to the default accent (purple, D193) and System.
        tab("Home")
        openSettings(gear: "settingsGear")
        app.buttons["settingsTab-Display"].waitAndTap()
        app.buttons["accent-purple"].waitAndTap()
        XCTAssert(app.buttons["accent-purple"].isSelected)
        setTheme("System")
        goBack()
        XCTAssert(problems.isEmpty, problems.joined(separator: "; "))
    }

    // MARK: Steps

    /// Pixels in a frame (points) close to the green accent (1DB954) and to the app's red (FA243C).
    @MainActor
    private func colorCounts(in frame: CGRect) -> (green: Int, red: Int) {
        guard let image = XCUIScreen.main.screenshot().image.cgImage, !frame.isEmpty else { return (0, 0) }
        let scale = CGFloat(image.width) / app.frame.width
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return (0, 0) }
        let box = CGRect(x: frame.minX * scale, y: frame.minY * scale, width: frame.width * scale, height: frame.height * scale)
            .intersection(CGRect(x: 0, y: 0, width: width, height: height))
        var greens = 0, reds = 0
        for y in Int(box.minY)..<Int(box.maxY) {
            for x in Int(box.minX)..<Int(box.maxX) {
                let i = (y * width + x) * 4
                let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
                if g > r + 70, g > b + 40 { greens += 1 }
                if r > g + 120, r > b + 80 { reds += 1 }
            }
        }
        return (greens, reds)
    }

    @MainActor
    private func openAlbum(_ name: String) {
        // Through Search: the Library lists no albums since D210.
        XCTAssert(app.openAlbumFromSearch(name), "no album called \(name)")
        XCTAssert(app.buttons["Search in album"].waitForExistence(timeout: 10), "the album page didn't load")
        sleep(1)
    }

    /// For lining a screen recording up with the steps: the time of each, in `NAVINX_MARKS`.
    private func mark(_ label: String) {
        guard let path = ProcessInfo.processInfo.environment["NAVINX_MARKS"] else { return }
        let line = "\(Date.now.timeIntervalSince1970) \(label)\n"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            FileManager.default.createFile(atPath: path, contents: Data(line.utf8))
        }
    }

    /// Every tab, scrolled to its top, then the rest of it.
    @MainActor
    private func walkTabs(_ theme: String) {
        for name in ["Playback", "Storage", "Server", "Display", "About"] {
            app.buttons["settingsTab-\(name)"].waitAndTap()
            sleep(1)
            shot("\(theme)-\(name.lowercased())")
            if name == "Display" {
                app.swipeUp()
                sleep(1)
                shot("\(theme)-display-2")
                app.swipeDown()
            }
        }
    }

    @MainActor
    private func setTheme(_ name: String) {
        app.buttons["settingsTab-Display"].waitAndTap()
        let tile = app.buttons["theme-\(name)"]
        tile.waitAndTap()
        XCTAssert(tile.isSelected, "\(name) isn't selected")
        sleep(1)
    }

    /// Opens a row's menu and picks a choice in it.
    @MainActor
    private func choose(_ choice: String, in menu: String, shot name: String? = nil) {
        let button = app.buttons[menu]
        XCTAssert(button.waitForExistence(timeout: 5), "no \(menu)")
        button.tap()
        let item = app.buttons.matching(NSPredicate(format: "label == %@", choice)).allElementsBoundByIndex.last { $0.isHittable }
        XCTAssertNotNil(item, "\(menu) has no \(choice)")
        if let name { shot(name) }
        item?.tap()
        sleep(1)
    }

    // MARK: Helpers

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
        XCTAssert(app.buttons["settingsGear"].waitForExistence(timeout: 20))
        dismissSavePassword(wait: 10)
    }

    /// A gear opens Settings. "Save Password?" can come at any time in the first ~20 seconds after
    /// signing in and take the tap (`docs/gotchas.md`), so it's answered and the gear tapped again.
    @MainActor
    private func openSettings(gear: String) {
        let playback = app.buttons["settingsTab-Playback"]
        for _ in 0..<3 where !playback.exists {
            app.buttons[gear].waitAndTap()
            if playback.waitForExistence(timeout: 4) { break }
            dismissSavePassword(wait: 2)
        }
        XCTAssert(playback.exists, "\(gear) didn't open Settings")
    }

    /// iOS offers to save the password after a login; answer "Not Now", wherever it shows.
    @MainActor
    private func dismissSavePassword(wait: TimeInterval) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for owner in [app!, springboard] {
            let notNow = owner.buttons["Not Now"]
            if notNow.waitForExistence(timeout: owner == springboard ? 1 : wait) {
                notNow.tap()
                sleep(2)
                return
            }
        }
    }

    @MainActor
    private func tab(_ label: String) {
        // The bar can be folded by an earlier scroll (C14): this unfolds it first.
        app.selectTab(label)
        sleep(1)
    }

    @MainActor
    private func goBack() {
        let back = app.navigationBars.buttons.firstMatch
        if back.exists, back.isHittable {
            back.tap()
        } else {
            app.buttons["BackButton"].firstMatch.tap()
        }
        sleep(1)
    }

    @MainActor
    private func expectToast(_ text: String) {
        let message = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'toast' AND label CONTAINS %@", text))
            .firstMatch
        XCTAssert(message.waitForExistence(timeout: 5), "no message: \(text)")
    }

    private func waitFor(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.3)
        }
        return condition()
    }

    @MainActor
    private func shot(_ name: String) {
        guard let shots else { return }
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: shots.appending(path: "\(prefix)\(name).png"))
    }
}

private extension XCUIElement {
    func waitAndTap(timeout: TimeInterval = 5) {
        XCTAssert(waitForExistence(timeout: timeout), "\(self) never appeared")
        tap()
    }
}
