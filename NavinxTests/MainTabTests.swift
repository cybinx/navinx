import Testing
@testable import Navinx

struct MainTabTests {
    @Test func tabsFollowTheFlutterOrder() {
        #expect(MainTab.allCases.map(\.rawValue) == [0, 1, 2, 3, 4])
        #expect(MainTab.fixed.map(\.title) == ["Home", "New", "Library", "Search"])
        #expect(MainTab.hub.title.isEmpty, "the server's tab has no title of its own")
    }

    @Test func tabsUseTheFlutterIcons() {
        #expect(MainTab.fixed.map(\.systemImage) == [
            "music.note.house",
            "square.grid.2x2",
            "rectangle.stack",
            "magnifyingglass",
        ])
    }
}
