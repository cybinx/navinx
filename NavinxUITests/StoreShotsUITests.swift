import XCTest

/// The App Store's pictures (C51, redone after C61), taken against the demo server as its ordinary
/// account `demo`: Home, an album, now playing, the Library, Search and the lyrics (or the queue,
/// when no demo song has lyrics), numbered in the store's order. Run by `Config/store-shots.sh`,
/// which writes the login file outside the repo, sets the status bar and runs it; see `README.md`.
/// Skipped without `TEST_RUNNER_NAVINX_LIVE`.
///
/// It plays songs (now-playing and play counts on the demo server) and downloads one album to the
/// simulator; nothing else is written. Only the two CC0 albums are opened, so no picture needs a
/// credit except what Home shows on its own. Kept out: the sign-in screen and Settings (both show
/// the server's address), errors, spinners and empty states.
final class StoreShotsUITests: XCTestCase {
    private struct Login: Decodable {
        let url: String
        let username: String
        let password: String
        /// A demo song with lyrics, found by the script, if there is one.
        let lyrics: Lyrics?
        struct Lyrics: Decodable { let song: String }
    }

    /// The demo server's albums (`Server/demo/README.md`): every picture uses the CC0 ones.
    private enum Demo {
        static let playedAlbum = "Tale on the Late"       // Komiku, CC0
        static let playedSong = "Friends, 2018"
        static let downloadedAlbum = "Relaxing Ukulele"   // Monplaisir, CC0
        static let searchWord = "Komiku"
        /// For `testListeningHistory`: one song from each of six albums.
        static let historyAlbums = [
            "Tale on the Late", "Relaxing Ukulele", "The Simple Life (Part 2)",
            "Directionless EP", "Jazz Sampler", "The Run",
        ]
    }

    private var app: XCUIApplication!
    private var login: Login!
    private var shots: URL?

    override func setUpWithError() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        guard let path = env["NAVINX_LIVE"] else { throw XCTSkip("No login file (TEST_RUNNER_NAVINX_LIVE)") }
        login = try JSONDecoder().decode(Login.self, from: Data(contentsOf: URL(filePath: path)))
        if let dir = env["NAVINX_SHOTS"] {
            shots = URL(filePath: dir)
            try? FileManager.default.createDirectory(at: shots!, withIntermediateDirectories: true)
        }
    }

    // MARK: The pictures

    @MainActor
    func testStorePictures() throws {
        start()

        // The album for the Library's Downloaded Songs, fetched while the other pictures are taken.
        openAlbum(Demo.downloadedAlbum)
        button("Download album").waitAndTap()
        settle(2)

        // An album page, one of its songs playing (a short title: a long one scrolls on now playing).
        // Playing first also replaces the queue the server kept from the last session.
        openAlbum(Demo.playedAlbum)
        let song = app.staticTexts.matching(NSPredicate(format: "label == %@", Demo.playedSong))
            .allElementsBoundByIndex.first { $0.isHittable }
        XCTAssertNotNil(song, "no \(Demo.playedSong) on the album page")
        song?.tap()
        let barTitle = app.staticTexts["playerBarTitle"]
        XCTAssert(barTitle.waitForLabel(Demo.playedSong, timeout: 15), "\(Demo.playedSong) didn't play")
        settle(5)
        shot("02-album")

        // Now playing with its cover, playing (the download can pause it).
        openNowPlaying()
        let playPause = app.buttons["nowPlayingPlayPause"]
        if playPause.waitForExistence(timeout: 3), playPause.label == "Play" { playPause.tap() }
        settle(4)
        shot("03-now-playing")
        if login.lyrics == nil {
            // No demo song has lyrics: the queue instead.
            app.buttons["nowPlayingQueue"].waitAndTap(timeout: 3)
            XCTAssert(app.staticTexts["Up Next"].waitForExistence(timeout: 5), "the queue page didn't show")
            settle(3)
            shot("06-queue")
            nowPlayingButton("Back").tap()
            settle(1)
        }
        closeNowPlaying()
        goBack()

        // Search, with results under "Songs": its top result has a cover, where "All"'s is the
        // artist, whose picture the demo server doesn't have.
        XCTAssert(app.selectTab("Search"), "no Search tab")
        let field = app.searchFields.firstMatch
        XCTAssert(field.waitForExistence(timeout: 5))
        field.tap()
        if let old = field.value as? String, !old.isEmpty, old != field.placeholderValue {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count))
        }
        field.typeText(Demo.searchWord + "\n")
        button("Songs").waitAndTap(timeout: 10)
        XCTAssert(app.staticTexts["Top result"].waitForExistence(timeout: 15), "no results for \(Demo.searchWord)")
        settle(4)
        shot("05-search")

        // The Library, once the album is in.
        XCTAssert(app.selectTab("Library"), "no Library tab")
        let downloaded = app.staticTexts["Downloaded Songs"].firstMatch
        XCTAssert(downloaded.waitForExistence(timeout: 10), "no Downloaded Songs row")
        downloaded.tap()
        XCTAssert(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Monplaisir")).firstMatch
                .waitForExistence(timeout: 180),
            "\(Demo.downloadedAlbum) never finished downloading")
        goBack()
        settle(3)
        shot("04-library")

        // Home, with the songs just played.
        XCTAssert(app.selectTab("Home"), "no Home tab")
        app.selectTab("Home")  // a second tap scrolls it to the top
        settle(6)
        shot("01-home")

        // Last, so no other picture shows its song: the lyrics of the song that has them.
        if let lyrics = login.lyrics {
            XCTAssert(app.openSearchResult(lyrics.song, filter: "Songs"), "no song called \(lyrics.song)")
            XCTAssert(app.staticTexts["playerBarTitle"].waitForLabel(lyrics.song, timeout: 15), "\(lyrics.song) didn't play")
            settle(3)
            openNowPlaying()
            app.buttons["nowPlayingLyrics"].waitAndTap()
            let list = app.descendants(matching: .any)["lyricsList"].firstMatch
            XCTAssert(list.waitForExistence(timeout: 25), "no lyrics for \(lyrics.song)")
            settle(2)
            // Unsynced lyrics start low on the page, after the file's tag lines: bring the verse up.
            for (from, to) in [(0.85, 0.35), (0.85, 0.45)] {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: from)).press(
                    forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: to)),
                    withVelocity: .slow, thenHoldForDuration: 0.5)
                settle(1)
            }
            settle(4)
            shot("06-lyrics")
        }
    }

    /// Run once, only if Home looks thin for want of history (`Config/store-shots.sh --history`):
    /// one song from each of six albums, played past half its length so the server counts it.
    @MainActor
    func testListeningHistory() throws {
        guard ProcessInfo.processInfo.environment["NAVINX_STORE_HISTORY"] != nil else {
            throw XCTSkip("Only with TEST_RUNNER_NAVINX_STORE_HISTORY")
        }
        start()
        for album in Demo.historyAlbums {
            openAlbum(album)
            app.pagePlayButton.tap()
            XCTAssert(app.staticTexts["playerBarTitle"].waitForExistence(timeout: 15), "\(album) didn't play")
            // Half of most of these songs; the count is sent when the next one replaces it.
            sleep(150)
            goBack()
        }
        // The last one counts once it is replaced or stopped: pause, then let the app send it.
        app.buttons["playerBarPlayPause"].tapIfThere()
        sleep(5)
    }

    // MARK: Steps

    /// A fresh app, signed in, with LRCLIB left unasked and off.
    @MainActor
    private func start() {
        app = XCUIApplication()
        // The simulator draws no volume slider: a still copy of the phone's stands in (C67).
        app.launchArguments = ["-UITestReset", "-UITestStillVolume", "-lrclib_fallback", "NO"]
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
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for owner in [app!, springboard] where owner.buttons["Not Now"].waitForExistence(timeout: 6) {
            owner.buttons["Not Now"].tap()
            sleep(1)
            break
        }
        XCTAssert(app.buttons["Library"].firstMatch.waitForExistence(timeout: 20), "didn't sign in")
        sleep(3)
    }

    @MainActor
    private func openAlbum(_ name: String) {
        // Through Search: the Library lists no albums since D210.
        XCTAssert(app.openAlbumFromSearch(name), "no album called \(name)")
        XCTAssert(app.buttons["Search in album"].waitForExistence(timeout: 10), "the album page didn't load")
    }

    @MainActor
    private func openNowPlaying() {
        app.staticTexts["playerBarTitle"].waitAndTap(timeout: 10)
        XCTAssert(app.staticTexts["nowPlayingTitle"].waitForExistence(timeout: 5), "now playing didn't open")
    }

    @MainActor
    private func closeNowPlaying() {
        nowPlayingButton("Close").tap()
        XCTAssert(app.staticTexts["nowPlayingTitle"].waitForNonExistence(timeout: 5))
    }

    @MainActor
    private func goBack() {
        let back = app.navigationBars.buttons.firstMatch
        if back.exists, back.isHittable {
            back.tap()
            sleep(1)
        }
    }

    @MainActor
    private func button(_ label: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    @MainActor
    private func nowPlayingButton(_ label: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier == 'nowPlayingClose' AND label == %@", label)).firstMatch
    }

    /// Time for covers to load and animations to end before a picture.
    private func settle(_ seconds: UInt32) { sleep(seconds) }

    @MainActor
    private func shot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let shots {
            try? screenshot.pngRepresentation.write(to: shots.appending(path: "\(name).png"))
        }
    }
}

private extension XCUIElement {
    @MainActor
    func waitAndTap(timeout: TimeInterval = 5) {
        XCTAssert(waitForExistence(timeout: timeout), "\(self) never appeared")
        tap()
    }

    @MainActor
    func tapIfThere() {
        if exists, isHittable { tap() }
    }

    /// Waits until the element's label is `label`.
    @MainActor
    func waitForLabel(_ label: String, timeout: TimeInterval) -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)
        repeat {
            if exists, self.label == label { return true }
            Thread.sleep(forTimeInterval: 0.5)
        } while Date.now < deadline
        return false
    }
}
