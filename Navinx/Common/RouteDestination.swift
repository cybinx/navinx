import SubsonicKit
import SwiftUI

/// Where a tab's stack can go.
enum LibraryRoute: Hashable {
    case album(Album), artist(Artist), playlist(Playlist)
    case favorites, downloads, addServer, settings
    case history, latestReleases, playlistDownloads
}

extension LibraryRoute {
    /// Settings and Add Server stand on their own, with neither the tab bar nor the mini-player, as a
    /// system settings page does (C30 bugs 3, 4); so does every page pushed above them (Settings → Storage →
    /// a playlist's downloads). Both come back on leaving.
    var hidesTabChrome: Bool { self == .settings || self == .addServer }
}

extension [LibraryRoute] {
    /// Whether a stack has Settings or Add Server on it, so the tab bar and the mini-player are away.
    var hidesTabChrome: Bool { contains(where: \.hidesTabChrome) }

    /// Whether the page for `route` stands at or above Settings or Add Server in this stack.
    func hidesTabChrome(at route: LibraryRoute) -> Bool {
        guard let index = lastIndex(of: route) else { return route.hidesTabChrome || hidesTabChrome }
        return self[...index].contains(where: \.hidesTabChrome)
    }

    /// Whether the page under the one for `route` hides the chrome too (C65: Storage over Settings).
    func hidesTabChrome(below route: LibraryRoute) -> Bool {
        guard let index = lastIndex(of: route) else { return hidesTabChrome }
        return self[..<index].contains(where: \.hidesTabChrome)
    }
}

/// The page for a route, in whichever tab's stack it was pushed.
struct RouteDestination: View {
    let route: LibraryRoute
    @Binding var path: [LibraryRoute]
    /// Read once, when the page is pushed, so a page on its way out keeps its own answer while the stack
    /// under it has already changed.
    @State private var hidesTabBar: Bool
    /// The page under it shows the tab bar: a swipe back brings the bar with the finger (C65).
    @State private var belowShowsTabBar: Bool

    init(route: LibraryRoute, path: Binding<[LibraryRoute]>) {
        self.route = route
        _path = path
        _hidesTabBar = State(initialValue: path.wrappedValue.hidesTabChrome(at: route))
        _belowShowsTabBar = State(initialValue: !path.wrappedValue.hidesTabChrome(below: route))
    }

    var body: some View {
        // A page pushed on a tab unfolds the tab bar when it's scrolled back to its top too.
        if hidesTabBar {
            // `MainTabView` turns the mini-player off for the same pages.
            destination.keepsBottomRoom().expandsTabBarAtTop().toolbarVisibility(.hidden, for: .tabBar)
                .returnsTabChromeOnSwipe(belowShowsTabBar)
        } else {
            // No visibility of its own otherwise: the bar is left as the stack below has it.
            destination.keepsBottomRoom().expandsTabBarAtTop()
        }
    }

    @ViewBuilder
    private var destination: some View {
        switch route {
        case .album(let album): AlbumView(albumID: album.id)
        case .artist(let artist): ArtistView(artistID: artist.id)
        case .playlist(let playlist): PlaylistView(seed: playlist)
        case .favorites: FavoritesView()
        case .history: SongCollectionView()
        case .latestReleases: AlbumCollectionView()
        case .downloads: DownloadsView()
        case .playlistDownloads: PlaylistDownloadsView()
        case .settings: SettingsView()
        case .addServer: AddServerView()
        }
    }
}

extension Artist {
    /// Flutter's artist artwork: its cover, its image URL, else the server's `ar-` ID.
    var artworkReference: String? {
        coverArt ?? artistImageURL ?? (id.isEmpty ? nil : "ar-\(id)")
    }
}
