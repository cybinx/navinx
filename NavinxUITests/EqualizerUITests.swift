import XCTest

/// The equalizer bars following a song's levels (C20, D89, C27), signed in through the dev front on
/// the Mac's loopback (`Server/panel/dev/front.py --levels <folder> --eq-delay 3`), which serves
/// `/eq` from `.lvl` files and passes everything else to the real server. Plays one song of an album and saves a burst of pictures of its row while
/// the levels are on their way (the loop) and after (the levels), then of the queue's row.
///
/// Needs `TEST_RUNNER_NAVINX_LIVE` (the login, its `url` the dev front's, for example
/// `http://127.0.0.1:4600`; **writes now-playing and play counts as it: use `api`**),
/// `TEST_RUNNER_NAVINX_SHOTS` (where the pictures go), and
/// optionally `TEST_RUNNER_NAVINX_ALBUM` / `_SONG` (default "DiCaprio 2" / "Mounted Up").
final class EqualizerUITests: XCTestCase {
    private struct Login: Decodable { let url: String; let username: String; let password: String }

    private var app: XCUIApplication!
    private var shots: URL?

    @MainActor
    func testTheBarsFollowTheLevels() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        guard let path = env["NAVINX_LIVE"] else { throw XCTSkip("No login file (TEST_RUNNER_NAVINX_LIVE)") }
        shots = env["NAVINX_SHOTS"].map { URL(filePath: $0) }
        let album = env["NAVINX_ALBUM"] ?? "DiCaprio 2"
        let songTitle = env["NAVINX_SONG"] ?? "Mounted Up"
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
        XCTAssert(app.selectTab("Library"))
        let layout = app.buttons["libraryLayout"]
        if layout.waitForExistence(timeout: 5), layout.label == "Switch to List" { layout.tap() }
        // Through Search: the Library lists no albums since D210.
        XCTAssert(app.openAlbumFromSearch(album), "this test needs the album \"\(album)\"")
        let row = app.staticTexts[songTitle].firstMatch
        XCTAssert(row.waitForExistence(timeout: 5), "the album has no \"\(songTitle)\"")
        row.tap()
        let pause = app.buttons.matching(NSPredicate(format: "identifier == 'playerBarPlayPause' AND label == 'Pause'")).firstMatch
        XCTAssert(pause.waitForExistence(timeout: 15), "the song didn't start")

        // The fake holds the levels back a few seconds (`--delay`): the loop first, then the levels.
        burst("album-a-loop", count: 6)
        sleep(4)
        burst("album-b-levels", count: 12)

        app.staticTexts["playerBarTitle"].tap()
        XCTAssert(app.descendants(matching: .any)["nowPlayingTitle"].firstMatch.waitForExistence(timeout: 5), "now playing didn't open")
        sleep(2)
        let queue = app.buttons["nowPlayingQueue"]
        XCTAssert(queue.waitForExistence(timeout: 5))
        queue.tap()
        // The queue scrolls to the playing row, so "Up Next" may be out of sight.
        let playingRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'queueRow' AND value == 'Playing'")).firstMatch
        XCTAssert(playingRow.waitForExistence(timeout: 5), "the queue page didn't show")
        sleep(1)
        burst("queue", count: 6)
        let close = app.buttons.matching(NSPredicate(format: "identifier == 'nowPlayingClose' AND label == 'Close'")).firstMatch
        if close.exists { close.tap() }
        sleep(1)
        let playing = app.buttons.matching(NSPredicate(format: "identifier == 'playerBarPlayPause' AND label == 'Pause'")).firstMatch
        if playing.exists { playing.tap() }
    }

    @MainActor
    private func burst(_ name: String, count: Int) {
        for index in 0..<count {
            let screenshot = XCUIScreen.main.screenshot()
            if let shots {
                try? screenshot.pngRepresentation.write(to: shots.appending(path: "c20-\(name)-\(index).png"))
            }
            Thread.sleep(forTimeInterval: 0.15)
        }
    }
}
