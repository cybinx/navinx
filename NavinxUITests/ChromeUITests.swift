import XCTest

/// Walks the system's tab bar minimise (C14, D74) against a real server, saving a screenshot at each
/// step and the bar's state to the marks file. The player part plays one song, so it writes
/// now-playing and a play count as that login: use the test account `api` (`CLAUDE.md`).
/// Skipped without `TEST_RUNNER_NAVINX_LIVE`; see `README.md`.
///
/// Environment: `NAVINX_LIVE` (login file), `NAVINX_SHOTS` (screenshot folder), `NAVINX_SHOT_PREFIX`,
/// `NAVINX_MARKS` (a file that gets a line with the time and state at each step). For dark shots set the
/// simulator first (`xcrun simctl ui <udid> appearance dark`); a launch argument doesn't reach the app's windows.
final class ChromeUITests: XCTestCase {
    private struct Login: Decodable { let url: String; let username: String; let password: String }

    private var app: XCUIApplication!
    private var shots: URL?
    private var prefix = ""

    /// No song playing: the bar folds when a page scrolls down, stays folded on the way up, and comes
    /// back at the top or on a tap of the circle; what each tab and page does.
    @MainActor
    func testBarMinimises() throws {
        try launch()

        // Home.
        XCTAssertFalse(app.isTabBarMinimised, "the bar starts open")
        XCTAssertEqual(app.tabBarLabels, ["Home", "New", "Library", "Search"])
        note("Home top"); shot("01-home-top")
        flickDown(); flickDown()
        XCTAssert(app.waitForTabBar(minimised: true), "two flicks down didn't fold the bar")
        XCTAssertEqual(app.tabBarLabels, ["Home", "Search"], "the folded bar shows the current tab and Search")
        wait(1); note("Home folded"); shot("02-home-folded")
        flickUp()
        wait(1.5)
        XCTAssert(app.isTabBarMinimised, "scrolling up must not unfold the bar (Flutter's rule 2)")
        note("Home one flick up"); shot("03-home-flick-up")
        app.collapsedTabCircle?.tap()
        XCTAssert(app.waitForTabBar(minimised: false), "the circle didn't unfold the bar")
        wait(1); note("Home after circle"); shot("04-home-circle")
        flickDown(); flickDown()
        XCTAssert(app.waitForTabBar(minimised: true))
        scrollToTop()
        XCTAssert(app.waitForTabBar(minimised: false, timeout: 6), "the top of the page didn't unfold the bar")
        wait(1); note("Home back at top"); shot("05-home-back-top")

        // Search: the circle shows the tab you're on.
        app.selectTab("Search")
        wait(2); note("Search top"); shot("06-search-top")
        flickDown(); flickDown()
        wait(2); note("Search after flicks"); shot("07-search-flicks")

        // New, Library.
        for name in ["New", "Library"] {
            XCTAssert(app.selectTab(name), "no \(name) tab")
            wait(2.5); note("\(name) top"); shot("08-\(name)-top")
            flickDown(); flickDown()
            wait(2); note("\(name) after flicks"); shot("09-\(name)-flicks")
            scrollToTop()
            wait(2); note("\(name) back at top"); shot("10-\(name)-back-top")
        }
    }

    /// A page pushed and popped while the bar is folded, and the circle on a pushed page. Home is the
    /// one page long enough to stay folded (the system unfolds the bar when a short list reaches its
    /// end); its History button stays reachable in the top bar while the bar below is folded.
    @MainActor
    func testBarAcrossPushAndPop() throws {
        try launch()
        flickDown(); flickDown()
        XCTAssert(app.waitForTabBar(minimised: true), "Home didn't fold the bar")
        note("Home folded"); shot("20-home-folded")

        // Push History (a C9 page) while the bar is folded.
        app.buttons["homeHistory"].tap()
        XCTAssert(app.buttons["Shuffle"].waitForExistence(timeout: 10), "History didn't open")
        wait(2); note("History pushed while folded"); shot("21-pushed")
        XCTAssert(app.isTabBarMinimised, "a push keeps the bar folded (Flutter's rule 2)")

        // Back: still folded, and the Home page is where it was.
        goBack()
        wait(1.5); note("after the pop"); shot("22-popped")
        XCTAssert(app.isTabBarMinimised, "a pop keeps the bar folded (Flutter's rule 2)")

        // The circle on a pushed page: Flutter pops to the root and unfolds.
        app.buttons["homeHistory"].tap()
        XCTAssert(app.buttons["Shuffle"].waitForExistence(timeout: 10))
        wait(1.5)
        note("History pushed again"); shot("23-pushed-again")
        let foldedHere = app.isTabBarMinimised
        app.collapsedTabCircle?.tap()
        wait(2); note("after the circle on the pushed page (folded there: \(foldedHere))"); shot("24-pushed-circle")
        note("History still open (Shuffle): \(app.buttons["Shuffle"].exists); Home's gear: \(app.buttons["settingsGear"].isHittable)")
    }

    /// The C9 pages with large titles, with the bar folded.
    @MainActor
    func testBarOnCollectionPages() throws {
        try launch()
        let history = app.buttons["homeHistory"]
        XCTAssert(history.waitForExistence(timeout: 10))
        history.tap()
        wait(3); note("History top"); shot("30-history-top")
        flickDown(); flickDown()
        wait(2); note("History flicks"); shot("31-history-flicks")
        goBack()
    }

    /// D81: the mini-player always has a song. A fresh sign-in shows one, paused at its start, and
    /// folded the bar is the circles with the inline accessory between them, never the bare circles.
    @MainActor
    func testBarAlwaysHasASong() throws {
        try launch()
        let title = app.staticTexts["playerBarTitle"]
        XCTAssert(title.waitForExistence(timeout: 30), "a fresh sign-in should show a song in the bar")
        let playPause = app.buttons["playerBarPlayPause"]
        XCTAssertEqual(playPause.label, "Play", "the song kept in the bar shouldn't be playing")
        XCTAssert(app.descendants(matching: .any)["playerBarTime"].label.hasPrefix("00:00"), "it should be at its start")
        wait(2); note("fresh sign-in, the kept song is \(title.label)"); shot("90-kept-open")
        flickDown(); flickDown()
        XCTAssert(app.waitForTabBar(minimised: true), "Home didn't fold the bar")
        wait(1.5); note("fresh sign-in, folded"); shot("91-kept-folded")
        XCTAssertEqual(app.tabBarLabels, ["Home", "Search"])
        XCTAssert(title.exists && playPause.exists, "the folded bar keeps the song's title and Play/Pause")
        XCTAssertFalse(app.buttons["Next"].exists, "inline, only Play/Pause is left")
        XCTAssertEqual(playPause.label, "Play")
    }

    /// D81: the last song comes back after the app is closed (a relaunch, a reboot), paused.
    @MainActor
    func testLastSongComesBackAfterARelaunch() throws {
        try launch()
        XCTAssert(app.selectTab("New"))
        let play = app.buttons["newHeroPlay"].firstMatch
        XCTAssert(play.waitForExistence(timeout: 20))
        play.tap()
        let title = app.staticTexts["playerBarTitle"]
        let playPause = app.buttons["playerBarPlayPause"]
        let pause = app.buttons.matching(NSPredicate(format: "identifier == 'playerBarPlayPause' AND label == 'Pause'")).firstMatch
        XCTAssert(pause.waitForExistence(timeout: 20), "nothing playing")
        // Skip to the next song, so the one that should come back isn't the one a fresh sign-in kept.
        let first = title.label
        app.buttons.matching(NSPredicate(format: "label == 'Next'")).allElementsBoundByIndex
            .first { $0.isHittable }?.tap()
        let moved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", first), object: title)
        XCTAssertEqual(XCTWaiter().wait(for: [moved], timeout: 15), .completed, "Next didn't change the song")
        let played = title.label
        wait(3)
        playPause.tap()
        let paused = app.buttons.matching(NSPredicate(format: "identifier == 'playerBarPlayPause' AND label == 'Play'")).firstMatch
        XCTAssert(paused.waitForExistence(timeout: 5))
        wait(2); note("before the relaunch: \(played)"); shot("92-before-relaunch")
        app.terminate()
        app.launchArguments = []
        app.launch()
        XCTAssert(title.waitForExistence(timeout: 30), "the last song didn't come back")
        wait(2); note("after the relaunch: \(title.label)"); shot("93-after-relaunch")
        XCTAssertEqual(title.label, played, "the bar should show the song that was playing")
        XCTAssertEqual(playPause.label, "Play", "it comes back paused")
    }

    /// With a song playing the mini-player goes inline between the two circles.
    @MainActor
    func testBarWithPlayerBar() throws {
        try launch()
        XCTAssert(app.selectTab("New"))
        let play = app.buttons["newHeroPlay"].firstMatch
        XCTAssert(play.waitForExistence(timeout: 20))
        play.tap()
        // The bar always has a song (D81), so it's the Pause button that says the hero's album started.
        let pause = app.buttons.matching(NSPredicate(format: "identifier == 'playerBarPlayPause' AND label == 'Pause'")).firstMatch
        XCTAssert(pause.waitForExistence(timeout: 20), "nothing playing")
        wait(2)
        XCTAssert(app.selectTab("Home"))
        wait(2); note("Home with player, open bar"); shot("40-home-player-open")
        XCTAssert(app.buttons["Next"].exists, "the open accessory has a Next button")
        flickDown(); flickDown()
        XCTAssert(app.waitForTabBar(minimised: true), "the bar with a player didn't fold")
        wait(1.5); note("Home with player, folded"); shot("41-home-player-folded")
        XCTAssert(app.buttons["playerBarPlayPause"].exists, "the folded accessory keeps Play/Pause")
        XCTAssertFalse(app.buttons["Next"].exists, "inline, only Play/Pause is left")
        XCTAssert(app.staticTexts["playerBarTitle"].exists, "the inline accessory keeps the title")
        // Scrolling up leaves it folded; the circle brings the open accessory back.
        flickUp()
        wait(1); note("Home with player, one flick up"); shot("42-home-player-flick-up")
        XCTAssert(app.isTabBarMinimised)
        // Pause from the folded bar.
        app.buttons["playerBarPlayPause"].firstMatch.tap()
        wait(1); note("paused from the inline bar"); shot("43-inline-paused")
        XCTAssert(app.isTabBarMinimised, "pausing keeps the bar folded")
        // Open now playing from it.
        app.staticTexts["playerBarTitle"].firstMatch.tap()
        wait(3); shot("44-now-playing-from-inline")
        XCTAssert(app.staticTexts["nowPlayingElapsed"].waitForExistence(timeout: 5), "the inline accessory didn't open now playing")
        app.buttons.matching(NSPredicate(format: "identifier == 'nowPlayingClose' AND label == 'Close'")).firstMatch.tap()
        XCTAssert(app.staticTexts["nowPlayingElapsed"].waitForNonExistence(timeout: 5))
        wait(1.5); note("after closing now playing"); shot("45-closed")
        // The circle unfolds the bar and the open accessory returns.
        app.collapsedTabCircle?.tap()
        XCTAssert(app.waitForTabBar(minimised: false))
        wait(1.5); note("after the circle"); shot("46-circle")
        XCTAssert(app.buttons["Next"].exists, "the open accessory is back")
    }

    /// C30 bugs 3 and 4: Settings and Add Server show neither the tab bar nor the mini-player, by every way
    /// in (Home's gear, the Library's gear and +, Settings → Server, the switcher), and both come back on
    /// leaving.
    @MainActor
    func testSettingsAndAddServerHideTheChrome() throws {
        try launch()
        let title = app.staticTexts["playerBarTitle"]
        XCTAssert(title.waitForExistence(timeout: 30), "a fresh sign-in shows a song")
        func chromeHidden(_ step: String) {
            wait(1.5); note(step); shot("c30-\(step)")
            XCTAssert(title.waitForNonExistence(timeout: 4), "\(step): the mini-player should be gone")
            XCTAssertNil(app.hittableTab("New"), "\(step): the tab bar should be gone")
        }
        func chromeBack(_ step: String) {
            wait(1.5); note(step); shot("c30-\(step)")
            XCTAssert(title.waitForExistence(timeout: 4), "\(step): the mini-player should be back")
            XCTAssertNotNil(app.hittableTab("New"), "\(step): the tab bar should be back")
        }
        chromeBack("home")

        // Home's gear, Settings' own pages, Server's Add button, then back out.
        app.buttons["settingsGear"].tap()
        XCTAssert(app.buttons["settingsTab-Display"].waitForExistence(timeout: 8), "Settings didn't open")
        chromeHidden("settings")
        app.buttons["settingsTab-Server"].tap()
        let addOnPage = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Add Server'")).firstMatch
        XCTAssert(addOnPage.waitForExistence(timeout: 5))
        addOnPage.tap()
        XCTAssert(app.navigationBars["Add Server"].waitForExistence(timeout: 5), "Add Server didn't open")
        chromeHidden("settings-add-server")
        goBack()
        XCTAssert(app.buttons["settingsTab-Server"].waitForExistence(timeout: 5))
        chromeHidden("settings-again")
        // The switcher's Add Server.
        let manage = app.buttons["settingsManageServers"]
        if manage.waitForExistence(timeout: 3) {
            manage.tap()
            let add = app.buttons["addServer"]
            XCTAssert(add.waitForExistence(timeout: 5), "the switcher didn't open")
            add.tap()
            XCTAssert(app.navigationBars["Add Server"].waitForExistence(timeout: 5), "Add Server didn't open from the switcher")
            chromeHidden("switcher-add-server")
            goBack()
        }
        goBack()
        XCTAssert(app.staticTexts["Liked Songs"].waitForExistence(timeout: 5), "back on Home")
        chromeBack("home-again")

        // The Library's gear and its +.
        XCTAssert(app.selectTab("Library"))
        app.buttons["librarySettingsGear"].tap()
        XCTAssert(app.buttons["settingsTab-Display"].waitForExistence(timeout: 8))
        chromeHidden("library-settings")
        goBack()
        chromeBack("library")
        // The + asks for a new playlist's name (D210: Add Server left it; Settings still opens it).
        app.buttons["libraryAdd"].tap()
        let create = app.alerts["Create playlist"]
        XCTAssert(create.waitForExistence(timeout: 5))
        create.buttons["Cancel"].tap()
        chromeBack("library-again")
    }

    /// C30 bug 13: a swipe left on the mini-player is Next, a swipe right is Previous; a tap still opens
    /// now playing. Plays the album "me", which has several songs (now-playing and a play count, D121).
    @MainActor
    func testSwipeOnThePlayerBarSkips() throws {
        try launch()
        // Through Search: the Library lists no albums since D210.
        XCTAssert(app.openAlbumFromSearch("me"), "this test needs the album \"me\"")
        XCTAssert(app.buttons["Shuffle"].waitForExistence(timeout: 10), "the album page didn't load")
        wait(1)
        app.pagePlayButton.tap()
        let pause = app.buttons.matching(NSPredicate(format: "identifier == 'playerBarPlayPause' AND label == 'Pause'")).firstMatch
        XCTAssert(pause.waitForExistence(timeout: 20), "nothing playing")
        let title = app.staticTexts["playerBarTitle"]
        let first = title.label
        func swipe(left: Bool) {
            let frame = title.frame
            let start = app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: left ? frame.maxX : frame.minX - 10, dy: frame.midY))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: left ? -150 : 150, dy: 0)),
                        withVelocity: .fast, thenHoldForDuration: 0)
        }
        swipe(left: true)
        let moved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", first), object: title)
        XCTAssertEqual(XCTWaiter().wait(for: [moved], timeout: 10), .completed, "a swipe left didn't skip")
        let second = title.label
        wait(1); note("swiped left: \(first) → \(second)"); shot("c30-swipe-left")
        // A swipe right is Previous, as the button: past 3 s into the song it starts it again, then a second
        // one goes back a song. Paused, so the song stays at its start in between.
        pause.tap()
        swipe(left: false)
        wait(2)
        if title.label != first {
            let time = app.descendants(matching: .any)["playerBarTime"]
            XCTAssert(time.label.hasPrefix("00:0"), "a swipe right past 3 s should start the song again: \(time.label)")
            swipe(left: false)
        }
        let back = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", first), object: title)
        XCTAssertEqual(XCTWaiter().wait(for: [back], timeout: 10), .completed, "a swipe right didn't go back")
        wait(1); note("swiped right: \(title.label)"); shot("c30-swipe-right")
        // A tap still opens now playing.
        title.tap()
        XCTAssert(app.staticTexts["nowPlayingElapsed"].waitForExistence(timeout: 5), "a tap didn't open now playing")
        app.buttons.matching(NSPredicate(format: "identifier == 'nowPlayingClose' AND label == 'Close'")).firstMatch.tap()
        XCTAssert(app.staticTexts["nowPlayingElapsed"].waitForNonExistence(timeout: 5))
        // Folded, the inline accessory swipes too.
        goBack()
        XCTAssert(app.selectTab("Home"))
        flickDown(); flickDown()
        XCTAssert(app.waitForTabBar(minimised: true), "Home didn't fold the bar")
        wait(1)
        let before = title.label
        swipe(left: true)
        let inline = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", before), object: title)
        XCTAssertEqual(XCTWaiter().wait(for: [inline], timeout: 10), .completed, "a swipe on the inline accessory didn't skip")
        XCTAssert(app.isTabBarMinimised, "the swipe keeps the bar folded")
        note("inline swipe: \(before) → \(title.label)"); shot("c30-swipe-inline")
        if pause.exists { pause.tap() }
    }

    /// C30 bug 15, a measurement: does the bar fold on Search? On the empty page, on a long result list
    /// with the keyboard closed, and with the field still active. Marks and pictures; it checks nothing.
    @MainActor
    func testSearchFold() throws {
        try launch()
        XCTAssert(app.selectTab("Search"))
        wait(3)
        func tryFold(_ step: String) {
            drag(points: 300, speed: 200)
            _ = app.waitForTabBar(minimised: true, timeout: 3)
            note("\(step), a 300 pt drag: keyboard \(app.keyboards.count > 0)"); shot("c30-search-\(step)-drag")
            flickDown(); flickDown()
            _ = app.waitForTabBar(minimised: true, timeout: 3)
            wait(1); note("\(step), two flicks: keyboard \(app.keyboards.count > 0)"); shot("c30-search-\(step)-flicks")
        }
        note("Search's empty page, at rest"); shot("c30-search-empty")
        tryFold("empty")
        scrollToTop(flicks: 4)
        wait(1)
        let field = app.searchFields.firstMatch
        XCTAssert(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("Cochise\n")
        wait(4)
        note("results, after Return: keyboard \(app.keyboards.count > 0)"); shot("c30-search-results")
        tryFold("results")
        // The field active with the keyboard up: the system takes the bar away.
        scrollToTop(flicks: 6)
        field.tap()
        wait(2)
        note("field active: keyboard \(app.keyboards.count > 0)"); shot("c30-search-field-active")
        drag(points: 300, speed: 200)
        wait(2)
        note("field active, a 300 pt drag: keyboard \(app.keyboards.count > 0)"); shot("c30-search-field-active-drag")
        let cancel = app.buttons["Cancel"].firstMatch
        if cancel.exists { cancel.tap() }
        wait(1)
    }

    /// Every page's top edge, scrolled by three drags (D75: the soft scroll edge). Screenshots only.
    @MainActor
    func testScrollEdges() throws {
        try launch()
        func scrolled(_ name: String) {
            for _ in 0..<3 { drag(points: 350, speed: 350) }
            wait(1.5); shot("80-\(name)")
        }
        scrolled("home")
        for name in ["New", "Library"] {
            XCTAssert(app.selectTab(name))
            wait(2.5)
            scrolled(name.lowercased())
        }
        // An album page, from Search (the Library lists no albums since D210).
        XCTAssert(app.openAlbumFromSearch("me"))
        XCTAssert(app.buttons["Shuffle"].waitForExistence(timeout: 10))
        wait(1.5)
        scrolled("album")
        goBack()
        // Search, and History.
        XCTAssert(app.selectTab("Search"))
        wait(2)
        scrolled("search")
        XCTAssert(app.selectTab("Home"))
        wait(1.5)
        scrollToTop()
        wait(2)
        app.buttons["homeHistory"].tap()
        wait(3)
        scrolled("history")
    }

    /// Does the fold depend on how fast the page is scrolled? The same 300 pt, dragged slowly, at a
    /// medium pace and flicked, from the top of Home, with a mark at each start and end so a screen
    /// recording can be read frame by frame (`NAVINX_MARKS` also gets the bar's state afterwards).
    @MainActor
    func testFoldSpeed() throws {
        try launch()
        for (name, speed) in [("slow", 60.0), ("medium", 250.0), ("fast", 0.0), ("slow2", 90.0), ("fast2", 0.0)] {
            XCTAssert(app.waitForTabBar(minimised: false, timeout: 8), "\(name): the bar should be open at the top")
            wait(1.5)
            note("\(name) start")
            if speed == 0 {
                app.swipeUp(velocity: .fast)
            } else {
                drag(points: 300, speed: speed)
            }
            note("\(name) end")
            wait(0.2)
            let folded = app.waitForTabBar(minimised: true, timeout: 3)
            note("\(name) +\(folded ? "folded" : "NOT folded") 0.2 s after the end of the gesture")
            XCTAssert(folded, "\(name): 300 pt of scrolling must fold the bar")
            wait(1.5)
            shot("50-\(name)-after")
            if speed > 0 {
                // Back up at the same pace: the bar must stay folded on the way (Flutter's rule 2) and
                // unfold once the page is at its top.
                note("\(name) return start")
                drag(points: 300, speed: speed, down: true)
                wait(2)
                note("\(name) return end, 2 s later")
                shot("51-\(name)-return")
                // At the very top, a further pull past it: does that bring the bar back?
                drag(points: 90, speed: 120, down: true)
                wait(1.5)
                note("\(name) pulled past the top")
                shot("52-\(name)-pull")
            }
            scrollToTop(flicks: 12)
            _ = app.waitForTabBar(minimised: false, timeout: 6)
            wait(2)
            note("\(name) back at the top")
        }
    }

    /// Tapping the tab you're on, with the bar open and with it folded (Flutter pops to the root on
    /// any tab press). Measurement only: the answers go to the marks file.
    @MainActor
    func testReselectTab() throws {
        try launch()
        // Open bar.
        app.buttons["homeHistory"].tap()
        XCTAssert(app.buttons["Shuffle"].waitForExistence(timeout: 10))
        wait(1.5)
        app.hittableTab("Home")?.tap()
        wait(2); note("open bar, Home tapped on a pushed History page; History still open: \(app.buttons["Shuffle"].exists)")
        shot("70-reselect-open")
        // Back to Home's root if it didn't pop.
        if app.buttons["Shuffle"].exists { goBack() }
        // Folded: the circle on a page pushed from the folded state.
        flickDown(); flickDown()
        XCTAssert(app.waitForTabBar(minimised: true))
        app.buttons["homeHistory"].tap()
        XCTAssert(app.buttons["Shuffle"].waitForExistence(timeout: 10))
        wait(1.5)
        note("folded: History pushed")
        app.collapsedTabCircle?.tap()
        wait(2); note("folded circle tapped; History still open: \(app.buttons["Shuffle"].exists)")
        shot("71-reselect-folded")
        if app.buttons["Shuffle"].exists {
            // A second tap on the open bar's tab for the same page.
            app.hittableTab("Home")?.tap()
            wait(2); note("then Home tapped again with the bar open; History still open: \(app.buttons["Shuffle"].exists)")
            shot("72-reselect-again")
        }
    }

    /// What brings a folded bar back when the page is at its top (the system's own rule): a flick that
    /// lands on the top, a slow drag to it, a pull past it, a tap on the status bar. Measurement only:
    /// the answers go to the marks file.
    @MainActor
    func testUnfoldTriggers() throws {
        try launch()
        func fold() {
            drag(points: 300, speed: 200)
            _ = app.waitForTabBar(minimised: true, timeout: 3)
        }
        func result(_ name: String) {
            wait(1.5); note(name); shot("60-\(name.replacingOccurrences(of: " ", with: "-"))")
        }
        // V1: one flick up from 300 pt down, landing on the top with its momentum.
        fold()
        app.swipeDown(velocity: .fast)
        result("V1 one fast flick up from 300 pt")
        scrollToTop(flicks: 12); wait(2)
        // V2: a slow drag to the top, then a flick up while already there.
        fold()
        drag(points: 300, speed: 60, down: true)
        note("V2 slow to the top")
        app.swipeDown(velocity: .fast)
        result("V2 then a flick at the top")
        scrollToTop(flicks: 12); wait(2)
        // V3: a slow drag to the top, then the status bar.
        fold()
        drag(points: 300, speed: 60, down: true)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.004)).tap()
        result("V3 status bar tap at the top")
        scrollToTop(flicks: 12); wait(2)
        // V4: a status bar tap from deep down.
        fold()
        flickDown()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.004)).tap()
        result("V4 status bar tap from deep")
        scrollToTop(flicks: 12); wait(2)
        // V5: a fast flick up from 300 pt, stopped by a touch before the top (momentum, not at top).
        fold()
        drag(points: 200, speed: 60, down: true)
        result("V5 slow up 200 of 300")
        app.swipeDown(velocity: .slow)
        result("V5 then a slow swipe")
    }

    /// The user's report (2026-11-07): scrolling a page back to its top must bring the full tab bar and
    /// the mini-player's Next button back, however the finger got there. The system alone left the bar
    /// folded after a slow drag to the top, a pull past it and the like (D80 (3), now fixed by
    /// `expandsTabBarAtTop`). Plays a song first, so the folded bar has its inline accessory.
    @MainActor
    func testBarComesBackAtTheTop() throws {
        try launch()
        XCTAssert(app.selectTab("New"))
        let play = app.buttons["newHeroPlay"].firstMatch
        XCTAssert(play.waitForExistence(timeout: 20))
        play.tap()
        let pause = app.buttons.matching(NSPredicate(format: "identifier == 'playerBarPlayPause' AND label == 'Pause'")).firstMatch
        XCTAssert(pause.waitForExistence(timeout: 20), "nothing playing")
        XCTAssert(app.selectTab("Home"))
        wait(2)

        func foldIt() {
            drag(points: 300, speed: 200)
            XCTAssert(app.waitForTabBar(minimised: true, timeout: 4), "the bar didn't fold")
            XCTAssertFalse(app.buttons["Next"].exists, "folded, the accessory is the inline one")
        }
        func assertBack(_ what: String) {
            XCTAssert(app.waitForTabBar(minimised: false, timeout: 4), "the bar stayed folded: \(what)")
            wait(1)
            XCTAssert(app.buttons["Next"].exists, "the mini-player's Next button didn't come back: \(what)")
            note(what); shot("80-\(what.replacingOccurrences(of: " ", with: "-"))")
        }

        // A slow drag that reaches the top and lifts (a touch past it).
        foldIt()
        drag(points: 330, speed: 60, down: true)
        assertBack("slow drag to the top")
        // A pull past the top: slow up to near it (still folded), then a slow pull down.
        foldIt()
        drag(points: 240, speed: 60, down: true)
        drag(points: 160, speed: 60, down: true)
        assertBack("slow pull past the top")
        // A flick that lands on it.
        foldIt()
        app.swipeDown(velocity: .fast)
        assertBack("fast flick to the top")
        // Folding again from the top still works: the fix doesn't hold the bar open.
        drag(points: 300, speed: 200)
        XCTAssert(app.waitForTabBar(minimised: true, timeout: 4), "the bar didn't fold again from the top")
        // And scrolling back up a little, not to the top, leaves it folded (D74's rule).
        drag(points: 120, speed: 60, down: true)
        wait(1.5)
        XCTAssert(app.isTabBarMinimised, "scrolling up, short of the top, must leave the bar folded")

        // A pushed page: History. The bar is folded here, and the toolbar's History button only comes
        // back with it: tap the circle first.
        scrollToTop(flicks: 8)
        wait(1)
        XCTAssert(app.selectTab("Home"))
        wait(1)
        app.buttons["homeHistory"].tap()
        wait(3)
        // `api`'s History can be too short to fold the bar (C26): then there's nothing to bring back.
        drag(points: 300, speed: 200)
        if app.waitForTabBar(minimised: true, timeout: 4) {
            drag(points: 330, speed: 60, down: true)
            assertBack("History, slow drag to the top")
        } else {
            note("History too short to fold the bar; skipped")
        }
        goBack()

        // An album page, from Search (the Library lists no albums since D210).
        if app.openAlbumFromSearch("me") {
            wait(3)
            foldIt()
            drag(points: 330, speed: 60, down: true)
            assertBack("album page, slow drag to the top")
        }
    }

    /// The user's case (C26, D104): a quick scroll down and straight back up, which reaches the top while
    /// the system's fold is still running. Since C65 (the user's choice) a fold that outran the arrival isn't
    /// forced open after it: the bar may stay folded at the top, and the next touch (a pull at the top)
    /// brings it back, on every main page.
    @MainActor
    func testBarComesBackAfterAQuickDownAndUp() throws {
        try launch()
        XCTAssert(app.selectTab("New"))
        let play = app.buttons["newHeroPlay"].firstMatch
        XCTAssert(play.waitForExistence(timeout: 20))
        play.tap()
        let pause = app.buttons.matching(NSPredicate(format: "identifier == 'playerBarPlayPause' AND label == 'Pause'")).firstMatch
        XCTAssert(pause.waitForExistence(timeout: 20), "nothing playing")

        func quickDownAndUp(_ what: String) {
            drag(points: 200, speed: 1200, hold: 0)
            let folded = app.isTabBarMinimised
            drag(points: 400, speed: 1200, down: true, hold: 0)
            note("\(what): folded after the quick scroll down: \(folded)")
            if !app.waitForTabBar(minimised: false, timeout: 2) {
                note("\(what): stayed folded at the top (C65); a pull at the top")
                drag(points: 30, speed: 200, down: true, hold: 0.3)
            }
            XCTAssert(app.waitForTabBar(minimised: false, timeout: 4), "the bar stayed folded at the top: \(what)")
            note(what); shot("85-\(what.replacingOccurrences(of: " ", with: "-"))")
            wait(1)
        }

        XCTAssert(app.selectTab("Home")); wait(2)
        for round in 1...3 { quickDownAndUp("Home \(round)") }
        XCTAssert(app.selectTab("New")); wait(2)
        quickDownAndUp("New")
        XCTAssert(app.selectTab("Library")); wait(2)
        quickDownAndUp("Library")
        // A detail page: an album, from Search (the Library lists no albums since D210).
        if app.openAlbumFromSearch("me") {
            wait(3)
            quickDownAndUp("album page")
        }
        // History, a pushed collection page.
        XCTAssert(app.selectTab("Home")); wait(1)
        scrollToTop(flicks: 4)
        XCTAssert(app.selectTab("Home")); wait(1)
        if app.buttons["homeHistory"].waitForExistence(timeout: 5) {
            app.buttons["homeHistory"].tap()
            wait(3)
            quickDownAndUp("History")
        }
    }

    /// A drag of a known length at a known speed (points per second), ending without a fling.
    @MainActor
    private func drag(points: CGFloat, speed: Double, down: Bool = false, hold: TimeInterval = 0.3) {
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: down ? 0.25 : 0.80))
        let to = from.withOffset(CGVector(dx: 0, dy: down ? points : -points))
        from.press(forDuration: 0.05, thenDragTo: to, withVelocity: XCUIGestureVelocity(speed), thenHoldForDuration: hold)
    }

    // MARK: steps

    @MainActor
    private func launch() throws {
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
        wait(4)
        if notNow.exists { notNow.tap() }
        wait(1)
    }

    /// A page scrolled down by a real flick.
    @MainActor
    private func flickDown() {
        app.swipeUp(velocity: .fast)
        wait(0.4)
    }

    @MainActor
    private func flickUp() {
        app.swipeDown(velocity: .fast)
        wait(0.4)
    }

    /// Flicks up until the page can't go further.
    @MainActor
    private func scrollToTop(flicks: Int = 10) {
        for _ in 0..<flicks { flickUp() }
    }

    @MainActor
    private func goBack() {
        let back = app.navigationBars.buttons.firstMatch
        if back.exists, back.isHittable { back.tap() } else { app.buttons["BackButton"].firstMatch.tap() }
        wait(1)
    }

    private func wait(_ seconds: TimeInterval) { Thread.sleep(forTimeInterval: seconds) }

    /// One line in the marks file: the time, the step and what the tab bar shows.
    @MainActor
    private func note(_ step: String) {
        let state = app.isTabBarMinimised ? "FOLDED" : "open"
        let line = "\(Date.now.timeIntervalSince1970) \(step) | bar \(state) \(app.tabBarLabels)\n"
        print("CHROME: \(line)", terminator: "")
        guard let path = ProcessInfo.processInfo.environment["NAVINX_MARKS"] else { return }
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            FileManager.default.createFile(atPath: path, contents: Data(line.utf8))
        }
    }

    private func shot(_ name: String) {
        guard let shots else { return }
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: shots.appending(path: "\(prefix)\(name).png"))
    }
}
