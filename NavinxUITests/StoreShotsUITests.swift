import XCTest

/// The App Store's pictures (C51), taken against the demo server as its reviewer account: Home, an
/// album, now playing, the queue, the Library, an artist, Search and the downloads, numbered in the
/// store's order. Run by `Config/store-shots.sh`, which writes the login file outside the repo, sets
/// the status bar and runs it once per appearance; see `README.md`. Skipped without
/// `TEST_RUNNER_NAVINX_LIVE`.
///
/// It plays songs (now-playing and play counts on the demo server, which the reviewer account may
/// write) and downloads one album to the simulator; nothing else is written. The sign-in screen and
/// now playing's placeholder art are kept out (both show the logo), as are About, errors,
/// spinners and empty states.
final class StoreShotsUITests: XCTestCase {
    private struct Login: Decodable { let url: String; let username: String; let password: String }

    /// The demo server's albums (`Server/demo/README.md`): the cover-led pictures use the CC0 ones.
    private enum Demo {
        static let playedAlbum = "Tale on the Late"       // Komiku, CC0
        static let downloadedAlbum = "Relaxing Ukulele"   // Monplaisir, CC0
        static let artist = "Komiku"
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
        prefix = env["NAVINX_SHOT_PREFIX"] ?? ""
    }

    // MARK: The pictures

    @MainActor
    func testStorePictures() throws {
        start()

        // An album page, then its songs playing.
        openAlbum(Demo.playedAlbum)
        settle(4)
        shot("02-album")
        app.pagePlayButton.tap()
        let barTitle = app.staticTexts["playerBarTitle"]
        XCTAssert(barTitle.waitForExistence(timeout: 15), "nothing started playing")
        settle(5)

        // Now playing with its cover, then the queue.
        barTitle.tap()
        XCTAssert(app.staticTexts["nowPlayingTitle"].waitForExistence(timeout: 5), "now playing didn't open")
        settle(4)
        shot("03-now-playing")
        let queue = app.buttons["nowPlayingQueue"]
        XCTAssert(queue.waitForExistence(timeout: 3))
        queue.tap()
        XCTAssert(app.staticTexts["Up Next"].waitForExistence(timeout: 5), "the queue page didn't show")
        settle(3)
        shot("04-queue")
        nowPlayingButton("Back").tap()
        settle(1)
        nowPlayingButton("Close").tap()
        XCTAssert(app.staticTexts["nowPlayingTitle"].waitForNonExistence(timeout: 5))
        goBack()

        // The album to show downloaded, fetched while the other pictures are taken.
        openAlbum(Demo.downloadedAlbum)
        button("Download album").waitAndTap()

        // An artist, through Search: the Library lists no artists since D210.
        XCTAssert(app.openSearchResult(Demo.artist, filter: "Artists"), "no artist called \(Demo.artist)")
        XCTAssert(app.buttons["Add to Queue"].waitForExistence(timeout: 10), "the artist page didn't load")
        settle(4)
        shot("06-artist")
        goBack()

        // The Library.
        app.selectTab("Library")
        settle(3)
        shot("05-library")

        // Search, with results.
        XCTAssert(app.selectTab("Search"), "no Search tab")
        let field = app.searchFields.firstMatch
        XCTAssert(field.waitForExistence(timeout: 5))
        field.tap()
        if let old = field.value as? String, !old.isEmpty, old != field.placeholderValue {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count))
        }
        button("All").tapIfThere()
        field.typeText(Demo.searchWord)
        XCTAssert(app.staticTexts["Top result"].waitForExistence(timeout: 15), "no results for \(Demo.searchWord)")
        app.keyboards.buttons["Search"].firstMatch.tapIfThere()
        app.keyboards.buttons["search"].firstMatch.tapIfThere()
        settle(4)
        shot("07-search")

        // The downloads, once the album is in.
        app.selectTab("Library")
        let downloaded = app.staticTexts["Downloaded Songs"].firstMatch
        XCTAssert(downloaded.waitForExistence(timeout: 10), "no Downloaded Songs row")
        downloaded.tap()
        app.buttons["Albums"].firstMatch.waitAndTap()
        XCTAssert(
            app.buttons.matching(NSPredicate(format: "label == %@", Demo.downloadedAlbum)).firstMatch
                .waitForExistence(timeout: 180),
            "\(Demo.downloadedAlbum) never finished downloading")
        settle(4)
        shot("08-downloads")
        goBack()

        // Home last, with the songs just played.
        XCTAssert(app.selectTab("Home"), "no Home tab")
        app.selectTab("Home")  // a second tap scrolls it to the top
        settle(5)
        shot("01-home")
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

    /// A fresh app, signed in.
    @MainActor
    private func start() {
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
            try? screenshot.pngRepresentation.write(to: shots.appending(path: "\(prefix)\(name).png"))
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
}
