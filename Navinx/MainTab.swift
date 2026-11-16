/// The app's tabs, in the Flutter app's order (`MainTabs` in `lib/screens/main/main_tabs.dart`):
/// Home, New, the server's tab when it sends one (C27, D106), Library, Search.
///
/// The icons are the SF Symbols behind the Flutter app's Cupertino icons
/// (`_glassTabItems` in `main_screen.dart`). The tab bar fills them itself
/// when selected, as the Flutter app's `activeIcon`s do.
nonisolated enum MainTab: Int, CaseIterable, Identifiable, Hashable {
    case home
    case new
    /// The server's own tab: its title and symbol come from the server, so it has none here.
    case hub
    case library
    case search

    var id: Self { self }

    /// The tabs that are always there.
    static let fixed: [MainTab] = [.home, .new, .library, .search]

    var title: String {
        switch self {
        case .home: "Home"
        case .new: "New"
        case .hub: ""
        case .library: "Library"
        case .search: "Search"
        }
    }

    var systemImage: String {
        switch self {
        case .home: "music.note.house"            // CupertinoIcons.music_house
        case .new: "square.grid.2x2"              // CupertinoIcons.square_grid_2x2
        case .hub: "circle.grid.2x2"              // the server's own symbol stands in for it
        case .library: "rectangle.stack"          // CupertinoIcons.collections
        case .search: "magnifyingglass"           // CupertinoIcons.search
        }
    }
}
