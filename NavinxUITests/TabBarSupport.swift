import XCTest

/// What the system's tab bar looks like to a test while it minimises on scroll (C14, D74).
///
/// Scrolling a page down folds the bar into two circles: the current tab (its button's value is
/// "Collapsed") and Search. Every other tab's button is gone until the bar comes back, which it does
/// when the page is scrolled to its top or the circle is tapped. So a test that scrolls and then taps
/// another tab has to bring the bar back first: `selectTab` does.
extension XCUIApplication {
    /// The folded current-tab circle, if the bar is folded.
    var collapsedTabCircle: XCUIElement? {
        let circle = tabBars.buttons.matching(NSPredicate(format: "value == 'Collapsed'")).firstMatch
        return circle.exists ? circle : nil
    }

    /// True while the bar is folded into its circles.
    var isTabBarMinimised: Bool { collapsedTabCircle != nil }

    /// The labels of the tab bar's buttons, in order: all five tabs, or just the circles.
    var tabBarLabels: [String] {
        tabBars.buttons.allElementsBoundByIndex.map(\.label)
    }

    /// The hittable button for a tab. A tab bar button can resolve to a copy with no position, hence
    /// the search for a hittable one (`docs/gotchas.md`).
    @MainActor
    func hittableTab(_ label: String) -> XCUIElement? {
        buttons.matching(NSPredicate(format: "label == %@", label)).allElementsBoundByIndex
            .first { $0.isHittable }
    }

    /// Taps a tab, bringing the bar back first if scrolling folded it. Returns false if it never
    /// became tappable. Tapping the circle selects the tab you're already on, which unfolds the bar.
    @MainActor @discardableResult
    func selectTab(_ label: String, timeout: TimeInterval = 15) -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)
        repeat {
            let notNow = buttons["Not Now"]
            if notNow.exists, notNow.isHittable { notNow.tap() }
            if let tab = hittableTab(label) {
                tab.tap()
                return true
            }
            if let circle = collapsedTabCircle, circle.isHittable {
                circle.tap()
            }
            Thread.sleep(forTimeInterval: 0.7)
        } while Date.now < deadline
        return false
    }

    /// Waits until the bar is folded (or not), polling, since the fold is an animation.
    @MainActor
    func waitForTabBar(minimised: Bool, timeout: TimeInterval = 4) -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)
        repeat {
            if isTabBarMinimised == minimised { return true }
            Thread.sleep(forTimeInterval: 0.2)
        } while Date.now < deadline
        return isTabBarMinimised == minimised
    }
}

extension XCUIApplication {
    /// A page's own "Play" button (an album's, a playlist's). The mini-player's Play/Pause is labelled
    /// "Play" too while it's paused, and it's always on screen (D81), so `buttons["Play"]` can be either.
    var pagePlayButton: XCUIElement {
        buttons.matching(NSPredicate(format: "label == 'Play' AND identifier != 'playerBarPlayPause'")).firstMatch
    }

    /// Opens an album's page through the Search tab: since D210 the Library lists no albums. `query`
    /// is typed into the field; the album is the first result whose title is `title` (or, with
    /// `prefix`, begins with it). Returns false if the page didn't load.
    @MainActor @discardableResult
    func openAlbumFromSearch(_ query: String, title: String? = nil, prefix: Bool = false) -> Bool {
        openSearchResult(query, filter: "Albums", title: title, prefix: prefix) && pagePlayButton.waitForExistence(timeout: 10)
    }

    /// Types `query` into the Search tab's field (replacing what was there), picks Search's own
    /// `filter` chip ("Albums", "Artists"), and taps the first result titled `title` (or `query`).
    /// Returns false if no such result came.
    @MainActor @discardableResult
    func openSearchResult(_ query: String, filter: String, title: String? = nil, prefix: Bool = false) -> Bool {
        guard selectTab("Search") else { return false }
        let field = searchFields.firstMatch
        guard field.waitForExistence(timeout: 5) else { return false }
        field.tap()
        if let old = field.value as? String, !old.isEmpty, old != field.placeholderValue {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count))
        }
        field.typeText(query + "\n")
        let notNow = buttons["Not Now"]
        if notNow.waitForExistence(timeout: 1) { notNow.tap() }
        let chip = buttons.matching(NSPredicate(format: "label == %@", filter)).allElementsBoundByIndex.first { $0.isHittable }
        chip?.tap()
        let name = title ?? query
        let match = staticTexts.matching(NSPredicate(format: prefix ? "label BEGINSWITH %@" : "label == %@", name))
        let deadline = Date.now.addingTimeInterval(15)
        while Date.now < deadline {
            if let row = match.allElementsBoundByIndex.first(where: { $0.isHittable }) {
                row.tap()
                return true
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return false
    }
}
