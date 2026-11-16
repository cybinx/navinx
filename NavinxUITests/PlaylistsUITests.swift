import CryptoKit
import XCTest

/// Playlists, favorites and collections (C9), against a real server, saving a screenshot at each step
/// and asking the server itself whether each edit landed.
///
/// **This writes to the server as the login given, so use the test account `api`** (`docs/decisions.md`,
/// D49): temporary playlists named "C9 …", created and deleted here, and favourites on and off again.
/// It needs the album "me", with at least six songs. Skipped without `TEST_RUNNER_NAVINX_LIVE`.
final class PlaylistsUITests: XCTestCase {
    private var server: LiveServer!
    private var shots: URL?
    private var prefix = ""
    private var app: XCUIApplication!
    private var login: LiveServer.Login!
    private var isDuo = false

    override func setUpWithError() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        guard let path = env["NAVINX_LIVE"] else { throw XCTSkip("No login file (TEST_RUNNER_NAVINX_LIVE)") }
        login = try JSONDecoder().decode(LiveServer.Login.self, from: Data(contentsOf: URL(filePath: path)))
        server = LiveServer(login: login)
        if let dir = env["NAVINX_SHOTS"] {
            shots = URL(filePath: dir)
            try? FileManager.default.createDirectory(at: shots!, withIntermediateDirectories: true)
        }
        prefix = env["NAVINX_SHOT_PREFIX"] ?? "c9-"
        isDuo = env["NAVINX_DUO"] != nil
        try server.cleanUp()
    }

    override func tearDownWithError() throws {
        try server?.cleanUp()
    }

    // MARK: The playlist page

    /// Reorder (D46), select, swipe, filter, favourite, rename (D47), delete.
    @MainActor
    func testPlaylistPage() throws {
        let songs = try server.albumSongs(named: "me", count: 6)
        let id = try server.createPlaylist("C9 Test", songIDs: songs.map(\.id))

        launch()
        openPlaylist("C9 Test")
        shot("01-playlist")

        // All six buttons are there, and a touch lands on the last, at the capsule's far edge.
        for button in ["Search in playlist", "More options", "Add to Favorites", "Reorder songs", "Select songs", "Download playlist"] {
            XCTAssert(menuItem(button).isHittable, "\(button) isn't on the bar")
        }
        menuItem("Download playlist").tap()
        expectToast(containing: "Queued 6 songs for download")

        try reorder(playlistID: id, songs: songs)
        try select(playlistID: id)
        try swipes(playlistID: id)
        filter()
        favorite()
        try rename(playlistID: id)

        // Delete, from the page: it asks, closes the page and says so.
        app.buttons["More options"].firstMatch.tap()
        menuItem("Delete Playlist").waitAndTap()
        XCTAssert(app.alerts["Delete Playlist"].waitForExistence(timeout: 3))
        XCTAssert(app.alerts.staticTexts["Are you sure you want to delete the playlist \"C9 Renamed\"?"].exists)
        shot("15-delete-alert")
        app.alerts.buttons["Delete"].tap()
        expectToast(containing: "Playlist \"C9 Renamed\" deleted")
        XCTAssert(app.buttons["libraryLayout"].waitForExistence(timeout: 5), "the page didn't close")
        try waitForServer("the playlist to go") { try !server.playlists().contains { $0.id == id } }
    }

    @MainActor
    private func reorder(playlistID id: String, songs: [LiveServer.Song]) throws {
        app.buttons["Reorder songs"].firstMatch.tap()
        XCTAssert(app.buttons["Done reordering"].waitForExistence(timeout: 3))
        sleep(1)
        shot("02-reorder")
        let original = songs.map(\.title)
        let handle = { self.app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Reorder'")).allElementsBoundByIndex.filter(\.isHittable) }
        XCTAssertGreaterThan(handle().count, 3, "no reorder handles")
        handle()[0].press(forDuration: 0.3, thenDragTo: handle()[2], withVelocity: .slow, thenHoldForDuration: 0.3)
        sleep(1)
        let shown = app.descendants(matching: .any).matching(identifier: "playlistReorderRow").allElementsBoundByIndex
            .map { $0.label }
        shot("03-reordered")
        XCTAssertNotEqual(shown.first, "\(original[0]), \(songs[0].artist)", "dragging a handle didn't move the row")

        // The server has the order on screen. Flutter's calls put the moved song last.
        var saved: [String] = []
        try waitForServer("the new order") {
            saved = try server.playlistSongs(id).map(\.title)
            return saved != original
        }
        XCTAssertEqual(saved.count, 6)
        XCTAssertNotEqual(saved.last, original[0], "the moved song went to the end, as in Flutter")
        // A list only has the rows on screen, which on the Duo aren't all six.
        XCTAssertEqual(shown, Array(try server.playlistSongs(id).map { "\($0.title), \($0.artist)" }.prefix(shown.count)), "the server's order isn't the one on screen")
        XCTAssertEqual(try server.playlist(id).name, "C9 Test", "saving the order changed the name")

        app.buttons["Done reordering"].tap()
        XCTAssert(app.buttons["Select songs"].waitForExistence(timeout: 3))

        // It's still that order after coming back.
        goBack()
        openPlaylist("C9 Test")
        app.buttons["Reorder songs"].firstMatch.tap()
        XCTAssert(app.buttons["Close"].waitForExistence(timeout: 3))
        sleep(1)
        let again = app.descendants(matching: .any).matching(identifier: "playlistReorderRow").allElementsBoundByIndex.map { $0.label }
        XCTAssertEqual(again, shown, "the order didn't last")
        app.buttons["Close"].tap()
        XCTAssert(app.buttons["Select songs"].waitForExistence(timeout: 3))
    }

    @MainActor
    private func select(playlistID id: String) throws {
        app.buttons["Select songs"].firstMatch.tap()
        XCTAssert(app.buttons["Select all"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["Remove selected"].isEnabled, "nothing is selected yet")
        let rows = { self.app.descendants(matching: .any).matching(identifier: "playlistSelectRow") }
        XCTAssert(rows().firstMatch.waitForExistence(timeout: 3))
        sleep(1)
        shot("04-select")

        // Select all flips, and back.
        app.buttons["Select all"].tap()
        XCTAssert(app.buttons["Deselect all"].waitForExistence(timeout: 2))
        shot("05-select-all")
        app.buttons["Deselect all"].tap()
        XCTAssert(app.buttons["Select all"].waitForExistence(timeout: 2))

        let before = try server.playlistSongs(id).map(\.title)
        rows().element(boundBy: 0).tap()
        rows().element(boundBy: 1).tap()
        XCTAssert(app.buttons["Remove selected"].isEnabled)
        shot("06-two-selected")
        app.buttons["Remove selected"].tap()
        XCTAssert(app.alerts["Remove songs"].waitForExistence(timeout: 3))
        XCTAssert(app.alerts.staticTexts["Remove 2 song(s) from \"C9 Test\"?"].exists)
        app.alerts.buttons["Cancel"].tap()
        sleep(1)
        XCTAssertEqual(try server.playlistSongs(id).count, 6, "Cancel removed something")

        // Done leaves the mode and stays on the page, with nothing removed (D50). Coming back,
        // nothing is ticked.
        shot("06b-done-button")
        app.buttons["Done selecting"].tap()
        XCTAssert(app.buttons["Select songs"].waitForExistence(timeout: 3), "Done didn't end the mode")
        XCTAssert(app.pagePlayButton.exists, "Done left the page")
        XCTAssertEqual(try server.playlistSongs(id).count, 6, "Done removed something")
        app.buttons["Select songs"].firstMatch.tap()
        XCTAssert(app.buttons["Select all"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["Remove selected"].isEnabled, "the old selection came back")
        rows().element(boundBy: 0).tap()
        rows().element(boundBy: 1).tap()

        app.buttons["Remove selected"].tap()
        XCTAssert(app.alerts["Remove songs"].waitForExistence(timeout: 3))
        app.alerts.buttons["Remove"].tap()
        expectToast(containing: "Removed 2 song(s) from playlist")
        try waitForServer("two songs removed") {
            try server.playlistSongs(id).map(\.title) == Array(before.dropFirst(2))
        }
        XCTAssert(app.buttons["Select songs"].waitForExistence(timeout: 3), "the mode didn't end")

        // A row's own trash takes only that row, and the selection stays with its song.
        app.buttons["Select songs"].tap()
        XCTAssert(rows().firstMatch.waitForExistence(timeout: 3))
        rows().element(boundBy: 2).tap()
        app.buttons.matching(NSPredicate(format: "label == 'Remove from Playlist'")).element(boundBy: 0).tap()
        try waitForServer("the row removed") { try server.playlistSongs(id).count == 3 }
        sleep(1)
        XCTAssertEqual(rows().element(boundBy: 1).isSelected, true, "the selection didn't follow its song")
        XCTAssertEqual(rows().element(boundBy: 0).isSelected, false)
        goBack()
        openPlaylist("C9 Test")
    }

    @MainActor
    private func swipes(playlistID id: String) throws {
        let titles = try server.playlistSongs(id).map(\.title)
        XCTAssertEqual(titles.count, 3)

        // Right: to the queue, past its 72 pt, and the song stays. `swipeRight()` only travels the
        // width of the element, which for a short title isn't enough.
        let start = app.staticTexts[titles[0]].firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 160, dy: 0)))
        expectToast(containing: "added to queue")
        XCTAssertEqual(try server.playlistSongs(id).count, 3, "a swipe right changed the playlist")
        sleep(1)

        // Left: gone, straight away, with no question.
        app.staticTexts[titles[1]].firstMatch.swipeLeft()
        expectToast(containing: "Song removed from playlist")
        try waitForServer("the swiped song to go") {
            try server.playlistSongs(id).map(\.title) == [titles[0], titles[2]]
        }
        XCTAssert(app.staticTexts[titles[1]].waitForNonExistence(timeout: 3))
        shot("07-swiped")
    }

    @MainActor
    private func filter() {
        app.buttons["Search in playlist"].firstMatch.tap()
        let field = app.textFields["Filter songs..."]
        XCTAssert(field.waitForExistence(timeout: 3))
        field.tap()
        field.typeText("zzzz-no-such-song")
        sleep(1)
        shot("08-filter")
        XCTAssertEqual(
            app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Song options'")).count, 0,
            "the filter left rows"
        )
        app.buttons["Search in playlist"].firstMatch.tap()
        XCTAssert(field.waitForNonExistence(timeout: 3))
    }

    @MainActor
    private func favorite() {
        menuItem("Add to Favorites").waitAndTap()
        expectToast(containing: "Added to favorites")
        XCTAssert(menuItem("Remove from Favorites").waitForExistence(timeout: 2))
        shot("09-favorite")
        menuItem("Remove from Favorites").tap()
        expectToast(containing: "Removed from favorites")
        XCTAssert(menuItem("Add to Favorites").waitForExistence(timeout: 2))
    }

    @MainActor
    private func rename(playlistID id: String) throws {
        app.buttons["More options"].firstMatch.tap()
        XCTAssert(menuItem("Add all to queue").waitForExistence(timeout: 3))
        shot("10-page-menu")
        menuItem("Rename Playlist").tap()
        try renameAlert(from: "C9 Test", to: "C9 Renamed")
        try waitForServer("the new name") { try server.playlist(id).name == "C9 Renamed" }
        XCTAssert(app.staticTexts["C9 Renamed"].waitForExistence(timeout: 5), "the page kept the old name")
        XCTAssertEqual(try server.playlistSongs(id).count, 2, "renaming changed the songs")
    }

    @MainActor
    private func renameAlert(from old: String, to new: String) throws {
        XCTAssert(app.alerts["Rename Playlist"].waitForExistence(timeout: 3))
        let field = app.alerts.textFields.firstMatch
        XCTAssertEqual(field.value as? String, old, "the field should start with the name")
        shot("11-rename-alert")
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count))
        XCTAssertFalse(app.alerts.buttons["Save"].isEnabled, "an empty name can be saved")
        field.typeText(new)
        tapWhenEnabled(app.alerts.buttons["Save"])
    }

    /// An alert's button comes back to life a moment after the text that enables it.
    @MainActor
    private func tapWhenEnabled(_ button: XCUIElement) {
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: button)
        XCTAssertEqual(XCTWaiter().wait(for: [enabled], timeout: 3), .completed, "\(button) never enabled")
        usleep(300_000)
        button.tap()
    }

    // MARK: The Library's menus

    /// The + button (straight to Create playlist since D210), the ⋯ menu and the long press (D48).
    @MainActor
    func testLibraryMenus() throws {
        launch()
        app.buttons["libraryAdd"].firstMatch.tap()

        XCTAssert(app.alerts["Create playlist"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.alerts.buttons["Create"].isEnabled, "an empty name can be created")
        shot("21-create-alert")
        let field = app.alerts.textFields.firstMatch
        field.tap()
        field.typeText("C9 Created")
        tapWhenEnabled(app.alerts.buttons["Create"])
        try waitForServer("the new playlist") { try server.playlists().contains { $0.name == "C9 Created" } }

        let row = app.staticTexts["C9 Created"].firstMatch
        XCTAssert(row.waitForExistence(timeout: 5), "the new playlist isn't in the Library")
        sleep(1)
        shot("22-created")

        // ⋯: the rows, in Flutter's order with Rename added.
        app.buttons["Playlist options"].firstMatch.tap()
        for item in ["Play", "Add all to queue", "Add to Favorites", "Rename Playlist", "Delete Playlist"] {
            XCTAssert(menuItem(item).waitForExistence(timeout: 3), "the menu has no \(item)")
        }
        shot("23-playlist-menu")

        // Favourite from the menu, which then offers the opposite.
        menuItem("Add to Favorites").tap()
        sleep(1)
        app.buttons["Playlist options"].firstMatch.tap()
        XCTAssert(menuItem("Remove from Favorites").waitForExistence(timeout: 3), "the menu didn't remember the favourite")
        menuItem("Remove from Favorites").tap()
        sleep(1)

        // Rename.
        app.buttons["Playlist options"].firstMatch.tap()
        menuItem("Rename Playlist").waitAndTap()
        try renameAlert(from: "C9 Created", to: "C9 Second")
        let renamed = app.staticTexts["C9 Second"].firstMatch
        XCTAssert(renamed.waitForExistence(timeout: 5), "the Library kept the old name")
        sleep(1)
        shot("23b-renamed")

        // A long press: the same rows under the header. Cancel keeps it; Delete deletes it.
        renamed.press(forDuration: 1.2)
        XCTAssert(menuItem("Delete Playlist").waitForExistence(timeout: 3), "no long-press menu")
        shot("24-long-press")
        menuItem("Delete Playlist").tap()
        XCTAssert(app.alerts["Delete Playlist"].waitForExistence(timeout: 3))
        app.alerts.buttons["Cancel"].tap()
        sleep(1)
        XCTAssert(try server.playlists().contains { $0.name == "C9 Second" }, "Cancel deleted it")

        renamed.press(forDuration: 1.2)
        menuItem("Delete Playlist").waitAndTap()
        XCTAssert(app.alerts["Delete Playlist"].waitForExistence(timeout: 3))
        app.alerts.buttons["Delete"].tap()
        expectToast(containing: "Playlist \"C9 Second\" deleted")
        XCTAssert(renamed.waitForNonExistence(timeout: 5))
        try waitForServer("the playlist to go") { try !server.playlists().contains { $0.name == "C9 Second" } }
    }

    /// The ⋯ menu's two rows that fetch the songs first. Each is seen by the mini-player, not its
    /// message: XCUITest is too slow for a 2-second message once music plays.
    @MainActor
    func testLibraryMenuPlays() throws {
        let songs = try server.albumSongs(named: "me", count: 3)
        _ = try server.createPlaylist("C9 Menu", songIDs: songs.map(\.id))
        launch()
        let options = app.buttons["Playlist options"].firstMatch
        options.waitAndTap(timeout: 10)
        menuItem("Add all to queue").waitAndTap()
        // With nothing playing, adding to the queue starts it, from the list's first song.
        let bar = app.staticTexts["playerBarTitle"]
        XCTAssert(bar.waitForExistence(timeout: 10), "Add all to queue queued nothing")
        // The bar holds a kept song (D81) until the list replaces it.
        let queued = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", songs[0].title), object: bar)
        XCTAssertEqual(XCTWaiter().wait(for: [queued], timeout: 10), .completed, "Add all to queue didn't start the list")
        sleep(2)

        // Skip on, so that Play starting from the top shows.
        app.buttons.matching(NSPredicate(format: "label == 'Next'")).firstMatch.waitAndTap()
        let moved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", songs[1].title), object: bar)
        XCTAssertEqual(XCTWaiter().wait(for: [moved], timeout: 10), .completed, "Next didn't move along the queue")

        options.tap()
        menuItem("Play").waitAndTap()
        let restarted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", songs[0].title), object: bar)
        XCTAssertEqual(XCTWaiter().wait(for: [restarted], timeout: 10), .completed, "Play didn't start from the top")
    }

    // MARK: Favorites

    @MainActor
    func testFavorites() throws {
        launch()
        // Nothing yet: its empty states.
        openPinned("Liked Songs")
        XCTAssert(app.staticTexts["No favorite songs yet"].waitForExistence(timeout: 5))
        shot("30-favorites-empty")
        app.buttons["Albums"].firstMatch.tap()
        XCTAssert(app.staticTexts["No favorite albums yet"].waitForExistence(timeout: 3))
        shot("31-favorite-albums-empty")
        goBack()

        let songs = try server.albumSongs(named: "me", count: 3)
        try server.star(songs.map(\.id))
        let albumID = try server.albumID(named: "me")
        try server.star(albumID: albumID)

        openPinned("Liked Songs")
        XCTAssert(app.staticTexts[songs[0].title].waitForExistence(timeout: 5))
        XCTAssert(app.buttons["Play All"].exists && app.buttons["Shuffle"].exists && app.buttons["Download All"].exists)
        XCTAssert(app.buttons["Download All Favorites"].exists, "no download button at the top")
        sleep(1)
        shot("32-favorites")

        // A swipe asks first; Cancel leaves the row where it was.
        app.staticTexts[songs[0].title].firstMatch.swipeLeft()
        XCTAssert(app.alerts["Remove from Favorites?"].waitForExistence(timeout: 3), "the swipe didn't ask")
        XCTAssert(app.alerts.staticTexts["Do you want to remove \"\(songs[0].title)\" from favorites?"].exists)
        shot("33-remove-alert")
        app.alerts.buttons["Cancel"].tap()
        sleep(1)
        XCTAssert(app.staticTexts[songs[0].title].isHittable, "Cancel left the row out of place")
        XCTAssertEqual(try server.starredSongs().count, 3)

        app.staticTexts[songs[0].title].firstMatch.swipeLeft()
        XCTAssert(app.alerts["Remove from Favorites?"].waitForExistence(timeout: 3))
        app.alerts.buttons["Remove"].tap()
        expectToast(containing: "Removed from favorites")
        XCTAssert(app.staticTexts[songs[0].title].waitForNonExistence(timeout: 3))
        try waitForServer("the favourite to go") { try server.starredSongs().count == 2 }

        // The albums.
        app.buttons["Albums"].firstMatch.tap()
        XCTAssert(albumTitle("me").waitForExistence(timeout: 3))
        sleep(2)
        XCTAssertFalse(app.buttons["Download All Favorites"].exists, "the top button is for songs only")
        shot("34-favorite-albums")
        goBack()

    }

    // MARK: Collections

    @MainActor
    func testCollections() throws {
        launch()

        // Home's History.
        tab("Home")
        app.buttons["homeHistory"].firstMatch.waitAndTap()
        XCTAssert(app.staticTexts["Listening History"].waitForExistence(timeout: 5))
        sleep(1)
        shot("43-history")
        goBack()

        // New Releases, from the New tab's "Recently Added" (Search's tiles are gone, D210).
        tab("New")
        let seeAll = app.buttons["See All"].firstMatch
        for _ in 0..<4 where !seeAll.exists {
            app.swipeUp()
            sleep(1)
        }
        XCTAssert(seeAll.waitForExistence(timeout: 10), "no See All on Recently Added")
        seeAll.tap()
        XCTAssert(app.staticTexts["New Releases"].waitForExistence(timeout: 5))
        sleep(3)
        shot("45-new-releases")
        // The A–Z index, which needs 8 albums: `api` alone has fewer, unless the server adds some.
        let index = app.descendants(matching: .any)["albumIndex"]
        if index.exists {
            let target = app.buttons.matching(NSPredicate(format: "label == 'Zero Gravity'")).firstMatch
            let firstCard = app.buttons.matching(NSPredicate(format: "label == 'Pow Wow'")).firstMatch
            let start = firstCard.frame.minY
            app.buttons["Z"].firstMatch.tap()
            sleep(1)
            shot("45b-new-releases-z")
            XCTAssert(target.exists, "Z didn't scroll to the album")
            XCTAssert(!firstCard.exists || firstCard.frame.minY < start, "Z didn't scroll")
        }
        goBack()

        // Search no longer has "Browse all" or its tiles (D210).
        tab("Search")
        XCTAssert(app.staticTexts["Search your library"].waitForExistence(timeout: 5) || app.staticTexts["Recent Searches"].exists)
        XCTAssertFalse(app.staticTexts["Browse all"].exists)
        XCTAssertFalse(app.staticTexts["Genres & Moods"].exists)
    }

    // MARK: Home's favourite rows

    /// Behind C11's setting, so the setting and the favourite come as launch arguments.
    @MainActor
    func testFavoritePlaylistRowOnHome() throws {
        let songs = try server.albumSongs(named: "me", count: 3)
        let id = try server.createPlaylist("C9 Home Row", songIDs: songs.map(\.id))

        launch(extraArguments: ["-home_show_favorite_playlists", "YES", "-favorite_playlist_ids", "(\(id))"])
        tab("Home")
        let title = app.staticTexts["C9 Home Row"].firstMatch
        XCTAssert(title.waitForExistence(timeout: 10), "no row for the favourite playlist")
        sleep(2)
        shot("50-home-row")
        app.buttons["See All"].firstMatch.tap()
        XCTAssert(app.buttons["Select songs"].waitForExistence(timeout: 5), "See All didn't open the playlist")
        goBack()
        XCTAssert(title.waitForExistence(timeout: 5))
    }

    /// And without the setting there's no row, as it's off by default.
    @MainActor
    func testFavoritePlaylistRowIsOffByDefault() throws {
        let songs = try server.albumSongs(named: "me", count: 3)
        let id = try server.createPlaylist("C9 Home Row", songIDs: songs.map(\.id))
        launch(extraArguments: ["-favorite_playlist_ids", "(\(id))"])
        tab("Home")
        XCTAssert(app.staticTexts["Jump back in"].waitForExistence(timeout: 10))
        sleep(3)
        XCTAssertFalse(app.buttons["See All"].exists, "the row showed with the setting off")
    }

    // MARK: Getting there

    @MainActor
    private func launch(extraArguments: [String] = []) {
        app = XCUIApplication()
        app.launchArguments = ["-UITestReset"] + extraArguments
        app.launch()
        signIn()
    }

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

    /// The hittable copy: a tab bar button can resolve to one with no position (`docs/gotchas.md`).
    /// The bar can be folded by an earlier scroll (C14): this unfolds it first.
    @MainActor
    private func tab(_ label: String) {
        app.selectTab(label)
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

    /// One of the Library's pinned rows.
    @MainActor
    private func openPinned(_ name: String) {
        tab("Library")
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
            // On the Duo the back button isn't under the navigation bar (`docs/gotchas.md`).
            app.buttons["BackButton"].firstMatch.tap()
        }
        sleep(1)
    }

    /// Exactly this label: `buttons[…]` ignores case.
    @MainActor
    private func menuItem(_ label: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    /// An album card's title, which accessibility sees as a button: the card has the button trait.
    @MainActor
    private func albumTitle(_ name: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@", name)).firstMatch
    }

    @MainActor
    private func expectToast(containing text: String) {
        // One query for both: a message lasts 2 seconds, which can pass between two queries.
        let message = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'toast' AND label CONTAINS %@", text))
            .firstMatch
        XCTAssert(message.waitForExistence(timeout: 5), "no message: \(text)")
    }

    private func waitForServer(_ what: String, timeout: TimeInterval = 8, _ condition: () throws -> Bool) throws {
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            if try condition() { return }
            usleep(300_000)
        }
        XCTFail("the server never showed \(what)")
    }

    @MainActor
    private func shot(_ name: String) {
        guard let shots else { return }
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: shots.appending(path: "\(prefix)\(name).png"))
    }
}

private extension XCUIElement {
    func waitAndTap(timeout: TimeInterval = 3) {
        XCTAssert(waitForExistence(timeout: timeout), "\(self) never appeared")
        tap()
    }
}

/// The test's own line to the server, to set things up and to check what really landed.
private struct LiveServer {
    struct Login: Decodable { let url: String; let username: String; let password: String }
    struct Song { let id: String; let title: String; let artist: String }
    struct Summary { let id: String; let name: String }

    let login: Login

    /// Everything these tests could have left behind.
    func cleanUp() throws {
        for playlist in try playlists() where playlist.name.hasPrefix("C9 ") {
            _ = try call("deletePlaylist", [("id", playlist.id)])
        }
        let starred = try call("getStarred2")["starred2"] as? [String: Any] ?? [:]
        for song in starred["song"] as? [[String: Any]] ?? [] {
            _ = try call("unstar", [("id", song["id"] as? String ?? "")])
        }
        for album in starred["album"] as? [[String: Any]] ?? [] {
            _ = try call("unstar", [("albumId", album["id"] as? String ?? "")])
        }
    }

    func playlists() throws -> [Summary] {
        let list = try call("getPlaylists")["playlists"] as? [String: Any]
        return (list?["playlist"] as? [[String: Any]] ?? []).map {
            Summary(id: $0["id"] as? String ?? "", name: $0["name"] as? String ?? "")
        }
    }

    func playlist(_ id: String) throws -> Summary {
        let list = try call("getPlaylist", [("id", id)])["playlist"] as? [String: Any]
        return Summary(id: id, name: list?["name"] as? String ?? "")
    }

    func playlistSongs(_ id: String) throws -> [Song] {
        let list = try call("getPlaylist", [("id", id)])["playlist"] as? [String: Any]
        return songs(list?["entry"])
    }

    func createPlaylist(_ name: String, songIDs: [String]) throws -> String {
        let reply = try call("createPlaylist", [("name", name)] + songIDs.map { ("songId", $0) })
        return try XCTUnwrap((reply["playlist"] as? [String: Any])?["id"] as? String)
    }

    func albumID(named name: String) throws -> String {
        let list = try call("getAlbumList2", [("type", "alphabeticalByName"), ("size", "500")])["albumList2"] as? [String: Any]
        let albums = list?["album"] as? [[String: Any]] ?? []
        return try XCTUnwrap(albums.first { $0["name"] as? String == name }?["id"] as? String, "this test needs the album \"\(name)\"")
    }

    func albumSongs(named name: String, count: Int) throws -> [Song] {
        let album = try call("getAlbum", [("id", albumID(named: name))])["album"] as? [String: Any]
        let all = songs(album?["song"])
        XCTAssertGreaterThanOrEqual(all.count, count, "this test needs \(count) songs on the album \"\(name)\"")
        return Array(all.prefix(count))
    }

    func star(_ songIDs: [String]) throws {
        _ = try call("star", songIDs.map { ("id", $0) })
    }

    func star(albumID: String) throws {
        _ = try call("star", [("albumId", albumID)])
    }

    func starredSongs() throws -> [Song] {
        songs((try call("getStarred2")["starred2"] as? [String: Any])?["song"])
    }

    private func songs(_ list: Any?) -> [Song] {
        (list as? [[String: Any]] ?? []).map {
            Song(id: $0["id"] as? String ?? "", title: $0["title"] as? String ?? "", artist: $0["artist"] as? String ?? "")
        }
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
