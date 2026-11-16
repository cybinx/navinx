import CryptoKit
import XCTest

/// Downloads and offline mode (C10), against a real server, saving a screenshot at each step.
///
/// **This writes to the server as the login given, so use the test account `api`** (`docs/decisions.md`,
/// D55): downloads (which only read), a temporary playlist named "C10 …", favourites on and off, and
/// play counts. It needs `api`'s albums: "Pow Wow" (Smino), Cochise's "me", "PIRU" and "IMGEEKED, IM HIGH,
/// IM FCKED UP", and "[Unknown Album]". It ends signed out, which deletes the downloads. Skipped
/// without `TEST_RUNNER_NAVINX_LIVE`.
final class DownloadsUITests: XCTestCase {
    private var server: Server!
    private var shots: URL?
    private var prefix = ""
    private var app: XCUIApplication!
    private var login: Server.Login!

    override func setUpWithError() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        guard let path = env["NAVINX_LIVE"] else { throw XCTSkip("No login file (TEST_RUNNER_NAVINX_LIVE)") }
        login = try JSONDecoder().decode(Server.Login.self, from: Data(contentsOf: URL(filePath: path)))
        server = Server(login: login)
        if let dir = env["NAVINX_SHOTS"] {
            shots = URL(filePath: dir)
            try? FileManager.default.createDirectory(at: shots!, withIntermediateDirectories: true)
        }
        prefix = env["NAVINX_SHOT_PREFIX"] ?? "c10-"
        try server.cleanUp()
    }

    override func tearDownWithError() throws {
        try server?.cleanUp()
    }

    @MainActor
    func testDownloadsThenOffline() throws {
        let unknownSong = try XCTUnwrap(server.albumSongs(named: "[Unknown Album]").first)
        let piru = try XCTUnwrap(server.albumSongs(named: "PIRU").first)
                let blackity = try XCTUnwrap(server.albumSongs(named: "me").first { $0.title == "Blackity" })

        // Made before the app starts, so the Library lists it.
        _ = try server.createPlaylist("C10 Test", songIDs: [piru.id, blackity.id])

        app = XCUIApplication()
        app.launchArguments = ["-UITestReset"]
        app.launch()
        signIn()

        // An album: queued, then green, with the cover's mark; Remove asks first.
        openAlbum("Pow Wow")
        shot("01-album-not-downloaded")
        menuItem("Download album").waitAndTap()
        expectToast(containing: "Queued 1 song for download")
        XCTAssert(menuItem("Downloaded — tap to remove").waitForExistence(timeout: 60), "the album never finished")
        XCTAssert(app.descendants(matching: .any)["downloadedBadge"].exists)
        shot("02-album-downloaded")
        menuItem("Downloaded — tap to remove").tap()
        XCTAssert(app.alerts["Remove downloads?"].waitForExistence(timeout: 3))
        XCTAssert(app.alerts.staticTexts["Remove 1 downloaded song from \"Pow Wow\"?"].exists)
        shot("03-remove-question")
        app.alerts.buttons["Cancel"].tap()
        XCTAssert(menuItem("Downloaded — tap to remove").exists, "Cancel removed it")
        // Removed, so offline it shows greyed out.
        menuItem("Downloaded — tap to remove").tap()
        app.alerts["Remove downloads?"].buttons["Remove"].waitAndTap()
        XCTAssert(menuItem("Download album").waitForExistence(timeout: 5), "the album still says downloaded")
        goBack()

        // The artist's Download All Albums: each album on its own.
        openAlbum("me")
        app.buttons.matching(NSPredicate(format: "label == 'Cochise'")).firstMatch.waitAndTap()
        menuItem("Download All Albums").waitAndTap()
        expectToast(containing: "Queued 16 songs from 3 albums for download")
        shot("04-artist-queued")
        goBack()
        // The album shows the spinner while it waits or runs, then green.
        let spinner = menuItem("Downloading — tap to cancel")
        if spinner.waitForExistence(timeout: 3) { shot("05-album-downloading") }
        XCTAssert(menuItem("Downloaded — tap to remove").waitForExistence(timeout: 240), "\"me\" never finished")
        shot("06-me-downloaded")

        // The song menu says so, and a song from another list downloads on its own.
        app.buttons.matching(NSPredicate(format: "label == 'Song options'")).firstMatch.tap()
        XCTAssert(menuItem("Downloaded").waitForExistence(timeout: 3))
        shot("07-song-menu-downloaded")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).tap()
        sleep(1)
        goBack()

        // A playlist whose songs are all downloaded already shows green (truthful marks), and the
        // status page counts it.
        tab("Library")
        openPlaylist("C10 Test")
        XCTAssert(menuItem("Downloaded — tap to remove").waitForExistence(timeout: 5), "a fully downloaded playlist isn't green")
        shot("08-playlist-downloaded")
        goBack()

        tab("Home")
        app.buttons["settingsGear"].waitAndTap()
        app.buttons["settingsTab-Storage"].waitAndTap()
        app.buttons["playlistDownloadsRow"].waitAndTap()
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == 'playlistDownloadRow' AND label CONTAINS 'C10 Test'")).firstMatch
        XCTAssert(row.waitForExistence(timeout: 10))
        XCTAssert(waitFor { row.label.contains("2 / 2") }, "the row says \(row.label)")
        shot("09-playlist-downloads")
        goBack()
        goBack()

        // Favorites' Download All: at once, skipping what's there.
        try server.star([piru.id, unknownSong.id])
        tab("Library")
        openPinned("Liked Songs")
        menuItem("Download All").waitAndTap()
        expectToast(containing: "Queued 1 song for download")
        sleep(8)
        goBack()

        // The Downloads page: every song and every album.
        openPinned("Downloaded Songs")
        XCTAssert(app.staticTexts["Blackity"].waitForExistence(timeout: 5))
        shot("10-downloads-songs")
        app.buttons["Albums"].firstMatch.tap()
        XCTAssert(albumTitle("PIRU").waitForExistence(timeout: 5))
        XCTAssert(albumTitle("[Unknown Album]").waitForExistence(timeout: 30), "Favorites' song never arrived")
        shot("11-downloads-albums")
        goBack()

        // The song menu: Downloaded asks before removing, then Download fetches it on its own.
        tab("Search")
        let field = app.searchFields.firstMatch
        XCTAssert(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("snippet\n")
        let options = app.buttons.matching(NSPredicate(format: "label == 'Song options'")).firstMatch
        XCTAssert(options.waitForExistence(timeout: 10))
        sleep(1)
        options.tap()
        menuItem("Downloaded").waitAndTap()
        XCTAssert(app.alerts["Remove Download"].waitForExistence(timeout: 3))
        XCTAssert(app.alerts.staticTexts["Remove this song from offline storage?"].exists)
        shot("12-remove-download-question")
        app.alerts.buttons["Remove"].tap()
        expectToast(containing: "Download removed")
        options.tap()
        menuItem("Download").waitAndTap()
        expectToast(containing: "Downloaded \"")
        options.tap()
        XCTAssert(menuItem("Downloaded").waitForExistence(timeout: 3), "the song doesn't say downloaded")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).tap()
        sleep(1)

        // Offline: the server is unreachable, and the downloads are there.
        app.terminate()
        app.launchArguments = ["-UITestUnreachable"]
        app.launch()
        let offline = app.buttons.matching(NSPredicate(format: "label == 'Open in offline mode' OR label == 'Offline mode?'")).firstMatch
        XCTAssert(offline.waitForExistence(timeout: 45), "offline mode wasn't offered")
        shot("13-offline-offered")
        offline.tap()
        XCTAssert(app.descendants(matching: .any)["offlineBanner"].waitForExistence(timeout: 10))
        sleep(2)
        shot("14-offline-home")

        tab("Library")
        sleep(1)
        shot("15-offline-library")
        // Since D210 the Library lists no albums, so an album with nothing downloaded ("Pow Wow")
        // has no way in offline; the Library's own rows are still there.
        XCTAssert(app.staticTexts["Liked Songs"].exists && app.staticTexts["Downloaded Songs"].exists)

        tab("New")
        sleep(1)
        shot("17-offline-new")

        tab("Search")
        let offlineField = app.searchFields.firstMatch
        XCTAssert(offlineField.waitForExistence(timeout: 5))
        offlineField.tap()
        offlineField.typeText("Black\n")
        XCTAssert(app.staticTexts["Blackity"].waitForExistence(timeout: 5), "offline search found nothing")
        sleep(1)
        shot("18-offline-search")

        // Play a downloaded song with no server: it moves, with its cover.
        openDownloadedAlbum("me")
        shot("19-offline-album")
        // "Do Sum" has lyrics, saved with its download.
        app.staticTexts["Do Sum"].firstMatch.tap()
        let bar = app.staticTexts["playerBarTitle"]
        XCTAssert(bar.waitForExistence(timeout: 10))
        XCTAssert(waitFor(timeout: 10) { bar.label == "Do Sum" }, "the song didn't take the bar: \(bar.label)")
        bar.tap()
        let elapsed = app.staticTexts["nowPlayingElapsed"]
        XCTAssert(elapsed.waitForExistence(timeout: 5))
        XCTAssert(waitFor(timeout: 20) { self.seconds(elapsed) >= 3 }, "the downloaded song didn't play: \(elapsed.label)")
        shot("20-offline-now-playing")
        app.buttons["nowPlayingLyrics"].tap()
        sleep(2)
        shot("21-offline-lyrics")
        XCTAssertFalse(app.staticTexts["No lyrics available"].exists, "the saved lyrics didn't show offline")
        // ✕ goes back to the player, then its chevron closes it.
        app.buttons.matching(NSPredicate(format: "identifier == 'nowPlayingClose' AND label == 'Back'")).firstMatch.waitAndTap()
        app.buttons.matching(NSPredicate(format: "identifier == 'nowPlayingClose' AND label == 'Close'")).firstMatch.waitAndTap()
        XCTAssert(app.staticTexts["nowPlayingElapsed"].waitForNonExistence(timeout: 5), "now playing didn't close")
        app.buttons["playerBarPlayPause"].firstMatch.tap()

        // Logout deletes the downloads: the next offline launch has nothing to offer.
        tab("Home")
        app.buttons["settingsGear"].waitAndTap()
        app.buttons["settingsTab-Server"].waitAndTap()
        app.buttons["settingsLogout"].waitAndTap()
        XCTAssert(app.alerts["Sign Out"].waitForExistence(timeout: 3))
        app.alerts.buttons["Sign Out"].tap()
        XCTAssert(app.buttons["connect"].waitForExistence(timeout: 10))
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
            tab("Library")
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
    private func tab(_ label: String) {
        // The bar can be folded by an earlier scroll (C14): this unfolds it first.
        app.selectTab(label)
        sleep(1)
    }

    @MainActor
    private func openAlbum(_ name: String) {
        // Through Search: the Library lists no albums since D210.
        XCTAssert(app.openAlbumFromSearch(name), "no album called \(name)")
        XCTAssert(app.buttons["Search in album"].waitForExistence(timeout: 10), "the album page didn't load")
        sleep(1)
    }

    /// An album from the Downloads page's Albums, which works offline too.
    @MainActor
    private func openDownloadedAlbum(_ name: String) {
        tab("Library")
        openPinned("Downloaded Songs")
        app.buttons["Albums"].firstMatch.waitAndTap()
        albumTitle(name).waitAndTap(timeout: 10)
        XCTAssert(app.buttons["Search in album"].waitForExistence(timeout: 10), "the album page didn't load")
        sleep(1)
    }

    @MainActor
    private func openPlaylist(_ name: String) {
        let row = app.staticTexts[name].firstMatch
        XCTAssert(row.waitForExistence(timeout: 10), "no playlist called \(name)")
        row.tap()
        XCTAssert(app.buttons["Select songs"].waitForExistence(timeout: 10), "the playlist page didn't load")
        sleep(1)
    }

    @MainActor
    private func openPinned(_ name: String) {
        let row = app.staticTexts[name].firstMatch
        XCTAssert(row.waitForExistence(timeout: 10), "no row called \(name)")
        row.tap()
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
    private func menuItem(_ label: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    @MainActor
    private func albumTitle(_ name: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@", name)).firstMatch
    }

    @MainActor
    private func menuRow(_ title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
    }

    @MainActor
    private func expectToast(containing text: String) {
        let message = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'toast' AND label CONTAINS %@", text))
            .firstMatch
        XCTAssert(message.waitForExistence(timeout: 8), "no message: \(text)")
    }

    private func waitFor(timeout: TimeInterval = 15, _ condition: () -> Bool) -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.3)
        }
        return condition()
    }

    /// The time label's elapsed part, `m:ss / m:ss`, in seconds.
    @MainActor
    private func seconds(_ element: XCUIElement) -> Int {
        let parts = element.label.split(separator: " ").first?.split(separator: ":").compactMap { Int($0) } ?? []
        return parts.count == 2 ? parts[0] * 60 + parts[1] : -1
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

/// The test's own line to the server.
private struct Server {
    struct Login: Decodable { let url: String; let username: String; let password: String }
    struct Song { let id: String; let title: String }

    let login: Login

    func cleanUp() throws {
        let list = try call("getPlaylists")["playlists"] as? [String: Any]
        for playlist in list?["playlist"] as? [[String: Any]] ?? [] where (playlist["name"] as? String ?? "").hasPrefix("C10 ") {
            _ = try call("deletePlaylist", [("id", playlist["id"] as? String ?? "")])
        }
        let starred = try call("getStarred2")["starred2"] as? [String: Any] ?? [:]
        for song in starred["song"] as? [[String: Any]] ?? [] {
            _ = try call("unstar", [("id", song["id"] as? String ?? "")])
        }
    }

    func albumSongs(named name: String) throws -> [Song] {
        let list = try call("getAlbumList2", [("type", "alphabeticalByName"), ("size", "500")])["albumList2"] as? [String: Any]
        let albums = list?["album"] as? [[String: Any]] ?? []
        let id = try XCTUnwrap(albums.first { $0["name"] as? String == name }?["id"] as? String, "this test needs the album \"\(name)\"")
        let album = try call("getAlbum", [("id", id)])["album"] as? [String: Any]
        return (album?["song"] as? [[String: Any]] ?? []).map {
            Song(id: $0["id"] as? String ?? "", title: $0["title"] as? String ?? "")
        }
    }

    func createPlaylist(_ name: String, songIDs: [String]) throws -> String {
        let reply = try call("createPlaylist", [("name", name)] + songIDs.map { ("songId", $0) })
        return try XCTUnwrap((reply["playlist"] as? [String: Any])?["id"] as? String)
    }

    func star(_ songIDs: [String]) throws {
        _ = try call("star", songIDs.map { ("id", $0) })
    }

    private func call(_ endpoint: String, _ params: [(String, String)] = []) throws -> [String: Any] {
        let salt = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)
        let token = Insecure.MD5.hash(data: Data((login.password + salt).utf8)).map { String(format: "%02x", $0) }.joined()
        var components = try XCTUnwrap(URLComponents(string: "\(login.url)/rest/\(endpoint)"))
        components.queryItems = [
            ("u", login.username), ("t", token), ("s", String(salt)), ("v", "1.16.1"), ("c", "NavinxUITests"), ("f", "json"),
        ].map(URLQueryItem.init) + params.map(URLQueryItem.init)
        let url = try XCTUnwrap(components.url)
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var body: Data?
        URLSession.shared.dataTask(with: url) { data, _, _ in
            body = data
            done.signal()
        }.resume()
        done.wait()
        let object = try JSONSerialization.jsonObject(with: try XCTUnwrap(body)) as? [String: Any]
        let reply = try XCTUnwrap(object?["subsonic-response"] as? [String: Any])
        XCTAssertEqual(reply["status"] as? String, "ok", "\(endpoint) failed")
        return reply
    }
}
