import XCTest

/// Walks the New tab against a real server, saving a screenshot at each step. It plays music, so it
/// writes now-playing and play counts as that login: use the test account `api` (`CLAUDE.md`).
/// Skipped without `TEST_RUNNER_NAVINX_LIVE`; see `README.md`.
final class NewTabUITests: XCTestCase {
    private struct Login: Decodable { let url: String; let username: String; let password: String }

    private var shots: URL?
    private var prefix = ""

    @MainActor
    func testNewTab() throws {
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
        signIn(app, login)
        try tab(app, "New").tap()

        // The hero: the newest albums, in Flutter's order on the page.
        let hero = app.staticTexts.matching(identifier: "newHeroTitle")
        XCTAssert(hero.firstMatch.waitForExistence(timeout: 20))
        XCTAssert(app.staticTexts["RECENTLY ADDED"].firstMatch.exists)
        answerSavePassword(app)
        sleep(4)
        shot("01-top")

        // A swipe moves one card, which lands square on the page's gutter.
        let first = try currentHeroTitle(hero, app)
        let card = app.buttons["newHeroPlay"].firstMatch
        let start = card.coordinate(withNormalizedOffset: CGVector(dx: -1, dy: -3))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: -220, dy: 0)))
        sleep(2)
        let second = try currentHeroTitle(hero, app)
        XCTAssertNotEqual(first, second, "the swipe didn't move the hero")
        shot("02-hero-second-card")

        // The cover opens its album.
        try currentHeroPlay(app).coordinate(withNormalizedOffset: CGVector(dx: -1, dy: -3)).tap()
        XCTAssert(app.buttons["Shuffle"].waitForExistence(timeout: 10), "the hero's cover didn't open the album")
        sleep(2)
        shot("03-album-from-hero")
        goBack(app)
        XCTAssert(hero.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(try currentHeroTitle(hero, app), second, "coming back lost the hero's place")

        // The hero's Play starts that album.
        try currentHeroPlay(app).tap()
        // The bar always has a song (D81), so it's the Pause button that says something started.
        let playing = app.staticTexts["playerBarTitle"]
        let pause = app.buttons.matching(NSPredicate(format: "identifier == 'playerBarPlayPause' AND label == 'Pause'")).firstMatch
        XCTAssert(pause.waitForExistence(timeout: 15), "the hero's Play didn't start anything")
        XCTAssert(playing.exists)
        sleep(3)
        shot("04-hero-playing")

        // Fresh From Artists, then what's below it.
        scroll(app, to: app.staticTexts["Fresh From Artists You Play"])
        sleep(3)
        shot("05-fresh")
        // Fresh has an album on `api`. On the Duo the title arrives with the row still below the screen.
        // The identifier also lands on the tile around the disc, so the disc is the small one.
        let discs = app.buttons.matching(identifier: "newTilePlay")
        func disc() -> XCUIElement? {
            let window = app.windows.firstMatch.frame
            return discs.allElementsBoundByIndex.first { $0.frame.width < 40 && window.contains($0.frame) }
        }
        for _ in 0..<3 where disc() == nil {
            app.swipeUp(velocity: .slow)
            sleep(1)
        }
        // Fresh lists only albums not played yet, so test runs on `api` can use them all up (seen in C8).
        // Paused first: the bar always has a song (D81) and the hero's album can be the one Fresh lists,
        // so the title may not change; the disc has to start the player from a standstill.
        let toggle = app.buttons["playerBarPlayPause"].firstMatch
        if toggle.label == "Pause" { toggle.tap() }
        let stopped = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'Play'"), object: toggle)
        XCTAssertEqual(XCTWaiter().wait(for: [stopped], timeout: 5), .completed, "the hero's album didn't pause")
        if let tile = disc() {
            tile.tap()
            let started = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'Pause'"), object: toggle)
            XCTAssertEqual(XCTWaiter().wait(for: [started], timeout: 10), .completed, "the album's disc didn't start it")
            sleep(4)
            shot("06-tile-playing")
        } else {
            let empty = NSPredicate(format: "label BEGINSWITH 'Play more music'")
            XCTAssert(app.staticTexts.matching(empty).firstMatch.exists, "no album disc and no message in Fresh")
        }
        scroll(app, to: app.staticTexts["Rediscover"])
        scroll(app, to: app.staticTexts["Recently Added"])
        sleep(1)
        shot("07-rediscover-recent")

        // The mix: its count, a new mix and Play.
        scroll(app, to: app.buttons["newMixPlay"])
        sleep(3)
        shot("08-mix")
        let count = app.staticTexts.matching(NSPredicate(format: "label ENDSWITH ' songs'")).firstMatch
        XCTAssert(count.exists)
        let newMix = app.buttons["New mix"]
        XCTAssert(newMix.exists)
        newMix.tap()
        sleep(3)
        XCTAssert(app.buttons["newMixPlay"].exists, "a new mix lost the card")
        shot("09-new-mix")
        let beforeMix = playing.label
        app.buttons["newMixPlay"].tap()
        sleep(4)
        // The mix can start on the same song only by chance.
        XCTAssert(playing.exists)
        print("mix: \(beforeMix) -> \(playing.label)")
        shot("10-mix-playing")

        // A pull to refresh keeps the page, and other tabs keep it too.
        app.swipeDown()
        app.swipeDown()
        app.swipeDown()
        sleep(1)
        let top = app.staticTexts["RECENTLY ADDED"].firstMatch
        XCTAssert(top.waitForExistence(timeout: 5))
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        from.press(forDuration: 0.05, thenDragTo: from.withOffset(CGVector(dx: 0, dy: 350)))
        sleep(4)
        XCTAssert(top.exists, "a refresh lost the hero")
        shot("11-after-refresh")
        try tab(app, "Library").tap()
        sleep(1)
        try tab(app, "New").tap()
        XCTAssert(top.waitForExistence(timeout: 5))

        // An artist's name in now playing opens their page here, in New's own stack.
        playing.tap()
        let artistName = app.buttons.matching(NSPredicate(format: "label != '' AND identifier == 'nowPlayingArtist'")).firstMatch
        XCTAssert(artistName.waitForExistence(timeout: 8), "now playing didn't open, or its artist has no button")
        artistName.tap()
        XCTAssert(top.waitForNonExistence(timeout: 8), "the artist's page didn't open over New")
        let arrivalsTab = try tab(app, "New")
        XCTAssert(arrivalsTab.isSelected, "the artist's page left the New tab")
        sleep(2)
        shot("12-artist-from-now-playing")
        goBack(app)
        XCTAssert(top.waitForExistence(timeout: 5), "going back didn't return to New")
    }

    /// The first match inside the window. Asking `isHittable` of a card that has left a lazy row
    /// fails the test ("Activation point invalid"), so this goes by its frame.
    @MainActor
    private func onScreen(_ query: XCUIElementQuery, _ app: XCUIApplication) -> XCUIElement? {
        let window = app.windows.firstMatch.frame
        return query.allElementsBoundByIndex.first { window.contains($0.frame) }
    }

    @MainActor
    private func currentHeroPlay(_ app: XCUIApplication) throws -> XCUIElement {
        try XCTUnwrap(onScreen(app.buttons.matching(identifier: "newHeroPlay"), app), "no hero Play on screen")
    }

    /// The title of the hero card on the screen now.
    @MainActor
    private func currentHeroTitle(_ titles: XCUIElementQuery, _ app: XCUIApplication) throws -> String {
        let width = app.windows.firstMatch.frame.width
        let element = titles.allElementsBoundByIndex.first { $0.frame.minX >= 0 && $0.frame.minX < width / 2 }
        return try XCTUnwrap(element, "no hero card on screen").label
    }

    @MainActor
    private func scroll(_ app: XCUIApplication, to element: XCUIElement) {
        for _ in 0..<8 where !(element.exists && element.isHittable) {
            app.swipeUp(velocity: .slow)
            sleep(1)
        }
        XCTAssert(element.exists && element.isHittable, "\(element) never came on screen")
    }

    /// The bar's back button; on the Duo the side rail holds it instead.
    @MainActor
    private func goBack(_ app: XCUIApplication) {
        let bar = app.navigationBars.buttons.firstMatch
        if bar.exists, bar.isHittable {
            bar.tap()
            return
        }
        let back = app.buttons.matching(NSPredicate(format: "identifier == 'BackButton' OR label == 'Back'"))
            .allElementsBoundByIndex.first { $0.isHittable }
        back?.tap()
    }

    /// A tab bar button, once it can be tapped (one can resolve to a copy with no position, and
    /// "Save Password?" can be in the way).
    @MainActor
    private func tab(_ app: XCUIApplication, _ title: String) throws -> XCUIElement {
        for _ in 0..<20 {
            answerSavePassword(app)
            let buttons = app.buttons.matching(NSPredicate(format: "label == %@", title)).allElementsBoundByIndex
            if let tab = buttons.first(where: { $0.isHittable }) { return tab }
            // Scrolling folds the bar (C14); the circle unfolds it.
            if let circle = app.collapsedTabCircle, circle.isHittable { circle.tap() }
            sleep(1)
        }
        return try XCTUnwrap(nil as XCUIElement?, "No hittable \(title) tab")
    }

    @MainActor
    private func signIn(_ app: XCUIApplication, _ login: Login) {
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
        answerSavePassword(app, wait: 8)
    }

    /// iOS offers to save the password after a login, sometimes late; answer "Not Now".
    @MainActor
    private func answerSavePassword(_ app: XCUIApplication, wait: TimeInterval = 1) {
        let notNow = app.buttons["Not Now"]
        if notNow.waitForExistence(timeout: wait) { notNow.tap() }
    }

    private func shot(_ name: String) {
        guard let shots else { return }
        let file = shots.appending(path: "\(prefix)\(name).png")
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: file)
    }
}
