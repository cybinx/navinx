import XCTest

/// "Navinx Playback" (C23, D92): pictures of every slide, the banner and the empty state.
///
/// Needs `TEST_RUNNER_NAVINX_LIVE` (the login; **the drumroll and "Play Your Top Songs" play the top
/// songs, writing now-playing and play counts as it: use `api`**) and `TEST_RUNNER_NAVINX_SHOTS`.
/// `-UITestDate` fakes today; `-UITestRecapSample` (debug builds) gives the slides fixed numbers on
/// the account's own songs, since `api` has few plays and no genres.
final class RecapUITests: XCTestCase {
    private struct Login: Decodable { let url: String; let username: String; let password: String }

    private var app: XCUIApplication!
    private var shots: URL?

    /// In season, from Home's banner, with the sample: every slide, the drumroll, then Play Your Top Songs.
    @MainActor
    func testEverySlideFromTheBanner() throws {
        try launch(date: "2026-12-01", sample: true)
        let banner = app.buttons["recapBanner"]
        XCTAssert(banner.waitForExistence(timeout: 15), "no banner in season")
        sleep(3)
        dismissSavePassword()
        shot("01-home-banner")
        banner.tap()

        XCTAssert(element("recapSlide.intro").waitForExistence(timeout: 20), "the story didn't open")
        sleep(1)
        shot("02-intro")
        app.buttons["recapBegin"].tap()

        XCTAssert(element("recapSlide.minutes").waitForExistence(timeout: 5))
        sleep(2)
        shot("03-minutes")
        for (slide, name) in [("chronotype", "04-chronotype"), ("genres", "05-genres")] {
            next()
            XCTAssert(element("recapSlide.\(slide)").waitForExistence(timeout: 5), "no \(slide) slide")
            sleep(1)
            shot(name)
        }
        next()
        XCTAssert(element("recapDrumroll").waitForExistence(timeout: 5), "no drumroll")
        shot("06-drumroll")
        let nowPlaying = element("recapNowPlaying")
        XCTAssert(nowPlaying.waitForExistence(timeout: 20), "the drumroll didn't play the top songs")
        sleep(1)
        shot("07-top-songs")
        for (slide, name) in [("topArtists", "08-top-artists"), ("personality", "09-personality"), ("summary", "10-summary")] {
            next()
            XCTAssert(element("recapSlide.\(slide)").waitForExistence(timeout: 5), "no \(slide) slide")
            sleep(1)
            shot(name)
        }
        // A tap on the left goes back.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).tap()
        XCTAssert(element("recapSlide.personality").waitForExistence(timeout: 5), "a tap on the left didn't go back")
        next()
        XCTAssert(element("recapSlide.summary").waitForExistence(timeout: 5))
        app.buttons["recapPlayRankedSongs"].tap()
        XCTAssert(app.buttons["recapBanner"].waitForExistence(timeout: 5), "Play Your Top Songs didn't close it")
        let pause = app.buttons.matching(NSPredicate(format: "identifier == 'playerBarPlayPause' AND label == 'Pause'")).firstMatch
        XCTAssert(pause.waitForExistence(timeout: 15), "the top songs aren't playing")
        sleep(1)
        shot("11-playing")
        pause.tap()
    }

    /// Out of season: no banner; Settings → About opens it on the account's real plays; a year with
    /// none shows the empty state.
    @MainActor
    func testAboutRowRealDataAndEmpty() throws {
        try launch(date: "2026-11-08", sample: false)
        XCTAssert(app.buttons["settingsGear"].waitForExistence(timeout: 15))
        sleep(2)
        XCTAssertFalse(app.buttons["recapBanner"].exists, "the banner shows out of season")
        openFromAbout()
        sleep(2)
        shot("20-about")
        app.swipeUp()
        sleep(1)
        shot("20b-about-row")
        app.buttons["aboutPlayback"].tap()
        XCTAssert(element("recapSlide.intro").waitForExistence(timeout: 20), "no story for the real plays")
        shot("21-real-intro")
        app.buttons["recapBegin"].tap()
        XCTAssert(element("recapSlide.minutes").waitForExistence(timeout: 5))
        sleep(2)
        shot("22-real-minutes")
        let progress = element("recapProgress")
        shot("22b-real-progress-\(progress.label.replacingOccurrences(of: " ", with: "_"))")
        app.buttons["recapClose"].tap()
        XCTAssert(app.buttons["aboutPlayback"].waitForExistence(timeout: 5))

        app.terminate()
        try launch(date: "2031-06-01", sample: false, reset: false)
        openFromAbout()
        app.buttons["aboutPlayback"].tap()
        XCTAssert(element("recapEmpty").waitForExistence(timeout: 20), "no empty state for a year without plays")
        sleep(1)
        shot("23-empty")
        app.buttons["recapClose"].tap()
    }

    // MARK: Helpers

    @MainActor
    private func launch(date: String, sample: Bool, reset: Bool = true) throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        guard let path = env["NAVINX_LIVE"] else { throw XCTSkip("No login file (TEST_RUNNER_NAVINX_LIVE)") }
        shots = env["NAVINX_SHOTS"].map { URL(filePath: $0) }
        let login = try JSONDecoder().decode(Login.self, from: Data(contentsOf: URL(filePath: path)))

        app = XCUIApplication()
        var arguments = ["-UITestDate", date]
        if reset { arguments.append("-UITestReset") }
        if sample { arguments.append("-UITestRecapSample") }
        app.launchArguments = arguments
        app.launch()
        guard reset else { return }
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
    }

    /// iOS's "Save Password?" can come up late, over whatever is next.
    @MainActor
    private func dismissSavePassword() {
        let notNow = app.buttons["Not Now"]
        if notNow.waitForExistence(timeout: 3) {
            notNow.tap()
            sleep(1)
        }
    }

    @MainActor
    private func openFromAbout() {
        dismissSavePassword()
        XCTAssert(app.selectTab("Home"))
        let gear = app.buttons["settingsGear"]
        XCTAssert(gear.waitForExistence(timeout: 15))
        gear.tap()
        let about = app.buttons["settingsTab-About"]
        XCTAssert(about.waitForExistence(timeout: 5))
        about.tap()
        XCTAssert(app.buttons["aboutPlayback"].waitForExistence(timeout: 5), "no Playback row in About")
    }

    @MainActor
    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    /// A tap on the right of the slide.
    @MainActor
    private func next() {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.55)).tap()
    }

    @MainActor
    private func shot(_ name: String) {
        guard let shots else { return }
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: shots.appending(path: "c23-\(name).png"))
    }
}
