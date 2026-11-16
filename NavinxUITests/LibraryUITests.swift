import XCTest

/// Walks the Library tab against a real server (read-only), saving a screenshot at each step.
/// Skipped without `TEST_RUNNER_NAVINX_LIVE`; see `README.md`.
final class LibraryUITests: XCTestCase {
    private struct Login: Decodable { let url: String; let username: String; let password: String }

    private var shots: URL?
    private var prefix = ""

    @MainActor
    func testLibraryTab() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        guard let path = env["NAVINX_LIVE"] else { throw XCTSkip("No login file (TEST_RUNNER_NAVINX_LIVE)") }
        let login = try JSONDecoder().decode(Login.self, from: Data(contentsOf: URL(filePath: path)))
        if let dir = env["NAVINX_SHOTS"] {
            shots = URL(filePath: dir)
            try? FileManager.default.createDirectory(at: shots!, withIntermediateDirectories: true)
        }
        prefix = env["NAVINX_SHOT_PREFIX"] ?? ""

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
        // iOS offers to save the password after a login; answer "Not Now".
        let notNow = app.buttons["Not Now"]
        if notNow.waitForExistence(timeout: 8) { notNow.tap() }

        XCTAssert(app.buttons["Library"].firstMatch.waitForExistence(timeout: 15))
        // The hittable copy of the tab, and the row's subtitle: Home has a "Liked Songs" too.
        let liked = app.staticTexts["Playlist • Favorites"]
        for _ in 0..<3 where !liked.exists {
            app.buttons.matching(NSPredicate(format: "label == 'Library'")).allElementsBoundByIndex
                .first { $0.isHittable }?.tap()
            _ = liked.waitForExistence(timeout: 4)
        }

        // The built-in rows.
        XCTAssert(liked.exists, "the Library tab didn't open")
        XCTAssert(app.staticTexts["Liked Songs"].exists)
        sleep(4)
        shot("01-list")

        // The grid, and back: each tap must switch the layout.
        let layout = app.buttons["libraryLayout"]
        XCTAssertEqual(layout.label, "Switch to Grid")
        layout.tap()
        XCTAssert(app.buttons["Switch to List"].waitForExistence(timeout: 3), "first tap didn't switch")
        sleep(2)
        shot("03-grid")
        layout.tap()
        XCTAssert(app.buttons["Switch to Grid"].waitForExistence(timeout: 3), "second tap didn't switch")

        // Only Liked Songs, Downloaded Songs and the playlists (D210): no chips, albums, artists,
        // Songs, Liked Albums or library search.
        XCTAssert(app.staticTexts["Downloaded Songs"].exists)
        for gone in ["Albums", "Artists", "Playlists", "Clear filter", "Search in Library"] {
            XCTAssertFalse(app.buttons[gone].exists, "\"\(gone)\" is still on the tab")
        }
        XCTAssertFalse(app.staticTexts["Liked Albums"].exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Album •'")).firstMatch.exists)

        // The end of the list, and a tap straight after scrolling back.
        app.swipeUp()
        sleep(1)
        shot("02-list-end")
        app.swipeDown()
        sleep(2)
        layout.tap()
        XCTAssert(app.buttons["Switch to List"].waitForExistence(timeout: 3), "tap after scrolling didn't switch")
        sleep(3)
        XCTAssertEqual(layout.label, "Switch to List", "the layout reset itself")
        layout.tap()
        XCTAssert(app.buttons["Switch to Grid"].waitForExistence(timeout: 3))

        // The sort menu opens under its button (D77), without a title.
        app.buttons["librarySort"].tap()
        let alphabetical = app.buttons["Alphabetical"]
        XCTAssert(alphabetical.waitForExistence(timeout: 3), "the sort menu didn't open")
        XCTAssertFalse(app.staticTexts["Sort by"].exists, "the menu has no title")
        sleep(1)
        shot("06-sort")
        alphabetical.tap()
        XCTAssert(app.buttons["librarySort"].waitForExistence(timeout: 3))
        sleep(1)

        // The + button creates a playlist straight away (Add Music Source left it, D210).
        app.buttons["libraryAdd"].tap()
        let create = app.alerts["Create playlist"]
        XCTAssert(create.waitForExistence(timeout: 3), "the + didn't ask for a playlist's name")
        sleep(1)
        shot("07-add")
        create.buttons["Cancel"].tap()
        XCTAssert(app.buttons["libraryAdd"].waitForExistence(timeout: 3))
    }

    @MainActor
    private func goBack(_ app: XCUIApplication) {
        app.navigationBars.buttons.element(boundBy: 0).tap()
        sleep(1)
    }

    @MainActor
    private func shot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        if let shots {
            try? screenshot.pngRepresentation.write(to: shots.appending(path: "\(prefix)\(name).png"))
        }
    }
}
