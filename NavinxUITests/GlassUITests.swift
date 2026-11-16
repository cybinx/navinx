import XCTest

/// The app's own glass at its one look (C30, D122: the Glass slider is gone, the glass is C26's default):
/// Settings → Display has no Glass row, and Home and now playing are taken for a before/after check.
/// Pictures only, besides the row being gone. Live, as `api`; it plays New's first song (now-playing, a
/// play count; D85). For dark, set the simulator first (`xcrun simctl ui <udid> appearance dark`) and pass
/// `TEST_RUNNER_NAVINX_SHOT_PREFIX=dark-`.
final class GlassUITests: XCTestCase {
    private struct Login: Decodable { let url: String; let username: String; let password: String }

    private var app: XCUIApplication!
    private var shots: URL?
    private var prefix = ""

    @MainActor
    func testGlassAtItsDefault() throws {
        continueAfterFailure = true
        let env = ProcessInfo.processInfo.environment
        guard let path = env["NAVINX_LIVE"] else { throw XCTSkip("No login file (TEST_RUNNER_NAVINX_LIVE)") }
        let login = try JSONDecoder().decode(Login.self, from: Data(contentsOf: URL(filePath: path)))
        if let dir = env["NAVINX_SHOTS"] {
            shots = URL(filePath: dir)
            try? FileManager.default.createDirectory(at: shots!, withIntermediateDirectories: true)
        }
        prefix = env["NAVINX_SHOT_PREFIX"] ?? ""
        app = XCUIApplication()
        app.launchArguments = ["-UITestReset"]
        app.launch()
        signIn(login)

        XCTAssert(app.selectTab("New"))
        let play = app.buttons["newHeroPlay"].firstMatch
        XCTAssert(play.waitForExistence(timeout: 20))
        play.tap()
        let title = app.staticTexts["playerBarTitle"]
        XCTAssert(title.waitForExistence(timeout: 20), "nothing playing")

        XCTAssert(app.selectTab("Home"))
        sleep(1)
        let gear = app.buttons["settingsGear"]
        XCTAssert(gear.waitForExistence(timeout: 10))
        gear.tap()
        let display = app.buttons["settingsTab-Display"]
        XCTAssert(display.waitForExistence(timeout: 8), "Settings didn't open")
        display.tap()
        sleep(1)
        XCTAssertFalse(app.sliders["glassClarity"].exists, "the Glass row is gone (D122)")
        XCTAssertFalse(app.staticTexts["Frosted"].exists, "the Glass row is gone (D122)")
        shot("settings-standard")
        let back = app.navigationBars.buttons.firstMatch
        if back.exists { back.tap() } else { app.buttons["BackButton"].firstMatch.tap() }
        sleep(2)
        shot("home-standard")
        XCTAssert(title.waitForExistence(timeout: 5))
        title.tap()
        XCTAssert(app.buttons["nowPlayingClose"].waitForExistence(timeout: 5), "now playing didn't open")
        sleep(2)
        shot("nowplaying-standard")
        app.buttons["nowPlayingClose"].tap()
        sleep(2)
    }

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
        if notNow.waitForExistence(timeout: 12) { notNow.tap() }
        XCTAssert(app.staticTexts["Liked Songs"].waitForExistence(timeout: 20))
        sleep(4)
        if notNow.exists { notNow.tap() }
    }

    private func shot(_ name: String) {
        guard let shots else { return }
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: shots.appending(path: "\(prefix)glass-\(name).png"))
    }
}
