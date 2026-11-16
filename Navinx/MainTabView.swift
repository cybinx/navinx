import HubKit
import PlaybackKit
import SubsonicKit
import SwiftUI
import SharedKit

/// The root tab bar.
struct MainTabView: View {
    @Environment(AccountModel.self) private var account
    @Environment(ToastCenter.self) private var toasts
    @Environment(PlayerModel.self) private var player
    @Environment(DownloadModel.self) private var downloads
    @Environment(NetworkMonitor.self) private var network
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(AppNavigator.self) private var navigator
    @State private var selection: MainTab = .home
    @State private var library = LibraryModel()
    @State private var homePath: [LibraryRoute] = []
    @State private var newPath: [LibraryRoute] = []
    @State private var libraryPath: [LibraryRoute] = []
    @State private var searchPath: [LibraryRoute] = []
    /// The server's own tab and Search's section (C27, D106): made again for every account, since this
    /// view is (`RootView` gives it the account's id), so nothing of one account reaches another.
    @State private var hub = HubModel()
    @State private var hubConnector = HubConnector()
    /// Now playing's open and close, Apple Music's way (C26, D104).
    @State private var nowPlaying = PlayerOpening()
    @State private var songSheets = SongSheets()
    @State private var playlistSheets = PlaylistSheets()
    @State private var pinnedPlaylists = PinnedPlaylistsModel()
    /// The Duo's side strip, and its mini-player's fold (C17, D78).
    @State private var sideInsets = SideInsets()
    @State private var duoChrome = DuoChrome()
    @State private var hinge = HingePosture.none
    /// The whole window, safe areas included (the Duo's split, C30 bug 17).
    @State private var window: CGSize = .zero
    private var chromeReturn: TabChromeReturn { .shared }

    var body: some View {
        TabView(selection: $selection) {
            Tab(MainTab.home.title, systemImage: MainTab.home.systemImage, value: .home) {
                HomeView(path: $homePath).expandsTabBarAtTop().showsToasts()
                    .environment(\.pageBottomRoom, bottomRoom)
            }
            Tab(MainTab.new.title, systemImage: MainTab.new.systemImage, value: .new) {
                NewView(path: $newPath).expandsTabBarAtTop().showsToasts()
                    .environment(\.pageBottomRoom, bottomRoom)
            }
            // Third, only while the server sends it, with the server's own title and symbol (D107).
            if let tab = hub.tab {
                Tab(tab.title, systemImage: HubSymbol.resolve(tab.symbol), value: MainTab.hub) {
                    HubTabView(model: hub).expandsTabBarAtTop().showsToasts()
                    .environment(\.pageBottomRoom, bottomRoom)
                }
            }
            Tab(MainTab.library.title, systemImage: MainTab.library.systemImage, value: .library) {
                LibraryView(path: $libraryPath).expandsTabBarAtTop().showsToasts()
                    .environment(\.pageBottomRoom, bottomRoom)
            }
            Tab(MainTab.search.title, systemImage: MainTab.search.systemImage, value: .search, role: .search) {
                SearchView(path: $searchPath).expandsTabBarAtTop().showsToasts()
                    .environment(\.pageBottomRoom, bottomRoom)
            }
        }
        // Scrolling down folds the bar into a circle for the current tab and one for Search, and the
        // mini-player goes inline between them (D74). Apple's own spring and threshold: the bar stays
        // folded on the way up and comes back at the top, as Flutter's does. On the Duo's cover display the
        // rail can't fold, and the system's minimise only faded the accessory out under the app's own fold
        // (C26), so it's off there. Nor does it fold before the mini-player has its song (a first set-up,
        // C30 bug 14): it would fold into the bare circles.
        .tabBarMinimizeBehavior(minimizesOnScroll ? .onScrollDown : .never)
        // What the unfold's flip puts back (C32).
        .onChange(of: minimizesOnScroll, initial: true) { _, minimizes in
            UIKitTabBar.minimizeBehavior = minimizes ? .onScrollDown : .never
        }
        // Scrolling any page closes the keyboard (C30 bug 7).
        .scrollDismissesKeyboard(.immediately)
        // Apple's soft fade under every top bar, the large-title pages included (D75). It sits here, not
        // on the full-screen cover below, so the now-playing pages keep the edge hidden as in Flutter.
        .scrollEdgeEffectStyle(.soft, for: .top)
        .tabViewBottomAccessory(isEnabled: showsAccessory) {
            PlayerBar { nowPlaying.open() }
                .environment(\.openLibraryRoute, openInCurrentTab)
                .environment(nowPlaying)
        }
        // With the accessory gone nothing reports the bar's fold; the mini-player reports it again on its return.
        .onChange(of: showsAccessory, initial: true) { _, shows in
            if !shows { UIKitTabBar.accessoryWent() }
        }
        // On the Duo's inner display with now playing open, the app keeps the half left of the hinge, with
        // no mini-player (C30 bug 17). It narrows once the player has opened and widens as it starts to
        // close, so the player grows out of the mini-player and shrinks back into it over the whole app.
        .frame(width: narrowsApp ? DuoSplit.hinge(in: window) - sideInsets.leading : nil)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        // A full-screen presentation with no animation of its own and a clear background: now playing
        // draws its own open and close inside it, out of the mini-player and back (C26, D104).
        .fullScreenCover(isPresented: Binding(
            get: { nowPlaying.isPresented && !splitsPlayer },
            set: { if !$0 { nowPlaying.finishClosing() } }
        )) {
            NowPlayingHost()
                .environment(nowPlaying)
                // A page opened from the player closes it first.
                .environment(\.openLibraryRoute) { route in
                    nowPlaying.close()
                    openInCurrentTab(route)
                }
        }
        // Now playing beside the app, in the half right of the hinge (C30 bug 17).
        .overlay(alignment: .topLeading) {
            if isSplitOpen {
                let area = DuoSplit.playerArea(in: window)
                NowPlayingHost()
                    .environment(nowPlaying)
                    .environment(\.nowPlayingArea, area)
                    .environment(\.openLibraryRoute) { route in
                        nowPlaying.close()
                        openInCurrentTab(route)
                    }
                    .padding(.leading, max(area.minX - sideInsets.leading, 0))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // The song's cover and backdrop are decoded before now playing opens, so its first frame has them (C15, D76).
        .task(id: player.currentSong?.coverArt) {
            await NowPlayingCovers.warm(coverArt: player.currentSong?.coverArt, client: account.client)
        }
        // What the mini-player folds into on the Duo's cover display, over the tabs and their rail. Inside
        // the sheets and the environment below, so its capsule's song menu has them as the tabs do.
        .overlay {
            // (Not drawn at all while hidden: an accessibility modifier on this window-sized overlay made it
            // one element over the whole app, and XCUITest found nothing under it hittable.)
            DuoFoldedPlayerBar(isHidden: hidesTabChrome || isSplitOpen)
        }
        // The phone's forced unfold: the mini-player's copy flying into its open place (C32).
        .overlay {
            if !sideInsets.hasRail {
                UnfoldFlightCopy { nowPlaying.open() }
                    .environment(nowPlaying)
            }
        }
        // Anything that changes the chrome under a flight ends it at once.
        .onChange(of: FlightEnds(tab: selection, nowPlaying: nowPlaying.isPresented, hides: hidesTabChrome, window: window, pages: [homePath.count, newPath.count, libraryPath.count, searchPath.count, hub.path.count])) {
            UnfoldFlight.shared.end()
        }
        .songSheets(songSheets)
        .playlistSheets(playlistSheets)
        .environment(\.openLibraryRoute, openInCurrentTab)
        .environment(pinnedPlaylists)
        .environment(library)
        .environment(hub)
        .environment(duoChrome)
        // How wide the Duo's side strip is, for the pages below (C17).
        .readsSideInsets($sideInsets)
        .readsHinge($hinge)
        .onGeometryChange(for: CGSize.self) { proxy in
            let insets = proxy.safeAreaInsets
            return CGSize(
                width: proxy.size.width + insets.leading + insets.trailing,
                height: proxy.size.height + insets.top + insets.bottom
            )
        } action: { window = $0 }
        #if DEBUG
        .task { await UITestHooks.openPlayerIfAsked(player: player, nowPlaying: nowPlaying) }
        .task { await UITestHooks.foldIfAsked(player: player, chrome: duoChrome) }
        #endif
        .onChange(of: sideInsets.hasRail) { duoChrome.reset() }
        // Scrolling Settings or Add Server doesn't fold the Duo's mini-player, which is off there.
        .onChange(of: hidesTabChrome, initial: true) { _, hides in
            duoChrome.ignoresScrolling = hides
            // The swipe out of Settings has landed: the path has caught up (C65).
            if !hides { chromeReturn.ended() }
        }
        .task {
            await library.start(
                client: account.client, cacheKey: account.active?.id.uuidString, account: account.active?.accountKey.mark
            ) {
                downloads.offlineSnapshot()
            }
        }
        // Signed out or switched: this account's sync stops with its tabs (C32).
        .onDisappear {
            library.stop()
            UnfoldFlight.shared.end()
        }
        // Back online by itself (C10): the lists load again from the server.
        .onChange(of: account.client == nil) {
            if let client = account.client { Task { await library.goOnline(client: client) } }
        }
        // Signed in again to this server with a changed password, or another address in use (C32): the
        // library's next loads use it. Nothing while it has no client: `goOnline` is for that.
        .onChange(of: account.client?.config) { if let client = account.client { library.use(client) } }
        .onChange(of: account.client?.baseURL) { if let client = account.client { library.use(client) } }
        // The server's tab: asked at launch and sign-in, whenever the address in use or the account's
        // login changes (back online, LAN or not, Edit Server), on every return to the foreground (D107:
        // how a newly allowed account gets it) and when the network comes back. Another login clears
        // what the old one was shown first.
        .task(id: account.client.map(HubIdentity.init)) {
            hub.use(account: account.client.map(HubIdentity.init)?.account)
            hub.connect = { [account, hubConnector] in
                hubConnector.connection(
                    client: account.client, offline: account.isOffline, profile: account.active?.id
                )
            }
            hub.onToast = { [toasts] in toasts.show($0) }
            await hub.probe()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await hub.probe() } }
        }
        .onChange(of: network.isConnected) { _, connected in
            if connected { Task { await hub.probe() } }
        }
        // If the server's tab goes while it's open, Home takes its place.
        // A page asked from Spotlight, Siri, Shortcuts, a quick action or a link (C39).
        .onChange(of: navigator.pending, initial: true) {
            if let destination = navigator.take() { Task { await show(destination) } }
        }
        .onChange(of: hub.isShown) { _, shown in
            if !shown, selection == .hub { selection = .home }
        }
    }

    /// What ends a forced unfold's flight when it changes: the tab, now playing, Settings, the window's size, a page.
    private struct FlightEnds: Equatable {
        var tab: MainTab
        var nowPlaying: Bool
        var hides: Bool
        var window: CGSize
        /// The tabs' stacks, for a push or a pop.
        var pages: [Int]
    }

    /// The room the pages' scroll views keep below their content, beyond the system's own (the bottom safe
    /// area); each page takes it with `keepsBottomRoom()`.
    /// The system's bottom inset follows the bar: the open mini-player above it, and 56 pt less with the bar
    /// folded and the mini-player inline. At the bottom of a page the bar is folded; when it unfolds there (a
    /// bounce, the circle) the offset stays, the last row is left under the open mini-player, and the scroll
    /// that would bring it up folds the bar again. So while the bar can fold, the pages keep that difference
    /// as room of their own, and their last row clears the open mini-player too. None on a short screen
    /// (an iPhone in landscape): the mini-player sits inline beside the bar there, and nothing grows.
    private var bottomRoom: CGFloat {
        minimizesOnScroll && showsAccessory && verticalSizeClass != .compact ? Self.foldStep : 0
    }

    /// How much the system's bottom inset shrinks when the bar folds with the mini-player on (measured on the
    /// iPhone 17 Pro, iOS 27.2: 139 pt open, 83 pt folded).
    private static let foldStep: CGFloat = 56

    /// The bar folds on scroll: not on the Duo's cover display, nor before there's a song (above).
    private var minimizesOnScroll: Bool { !sideInsets.hasRail && player.currentSong != nil }

    /// The system's accessory, the mini-player, is on.
    private var showsAccessory: Bool {
        // A swipe out of Settings brings it back with the tab bar, as the swipe starts (C65).
        player.currentSong != nil && !isFoldedOnDuo && (!hidesTabChrome || chromeReturn.isReturning) && !narrowsApp
    }

    /// The system's accessory is off while the Duo's mini-player is folded or melting (the circle, the small
    /// capsule or the copy of the capsule stands in for it).
    private var isFoldedOnDuo: Bool { sideInsets.hasRail && duoChrome.hidesAccessory }

    /// The Duo's inner display, open or half open: now playing opens beside the app (C30 bug 17).
    private var splitsPlayer: Bool { DuoSplit.applies(hinge: hinge, window: window) }

    /// Now playing is open beside the app.
    private var isSplitOpen: Bool { splitsPlayer && nowPlaying.isPresented }

    /// The app is in the half left of the hinge: from the end of the player's open to the start of its close.
    private var narrowsApp: Bool { isSplitOpen && nowPlaying.isSettled }

    /// Settings or Add Server is on the selected tab's stack (C30 bugs 3, 4): the mini-player is off, as the
    /// tab bar is (`RouteDestination`), until they're left.
    private var hidesTabChrome: Bool {
        switch selection {
        case .home: homePath.hidesTabChrome
        case .new: newPath.hidesTabChrome
        case .hub: hub.path.compactMap { if case .library(let route) = $0 { route } else { nil } }.hidesTabChrome
        case .library: libraryPath.hidesTabChrome
        case .search: searchPath.hidesTabChrome
        }
    }

    /// A page asked from outside the app (C39): over the tab underneath, as a page opened from now playing
    /// is; Search's text in the Search tab. Never on the server's tab: Home takes its place.
    private func show(_ destination: AppDestination) async {
        if nowPlaying.isPresented { nowPlaying.close() }
        if selection == .hub { selection = .home }
        switch destination {
        case .search(let text):
            searchPath = []
            selection = .search
            navigator.searchText = text
        case .favorites:
            openInCurrentTab(.favorites)
        case .downloads:
            openInCurrentTab(.downloads)
        case .album(let id):
            // The page loads the album by its ID.
            openInCurrentTab(.album(Album(id: id, name: library.allAlbums.first { $0.id == id }?.name ?? "")))
        case .artist(let id):
            openInCurrentTab(.artist(Artist(id: id, name: library.artists.first { $0.id == id }?.name ?? "")))
        case .playlist(let id):
            // The page's title and its edit actions come from the playlist's name and owner.
            var playlist = library.playlists.first { $0.id == id }
            if playlist == nil { playlist = await SavedLibrary.shared.lists()?.playlists.first { $0.id == id } }
            openInCurrentTab(.playlist(playlist ?? Playlist(id: id, name: "")))
        }
    }

    /// Opens a page in the tab underneath (Flutter pushes it over the current tab).
    private func openInCurrentTab(_ route: LibraryRoute) {
        switch selection {
        case .home: homePath.append(route)
        case .new: newPath.append(route)
        case .hub: hub.path.append(.library(route))
        case .library: libraryPath.append(route)
        case .search: searchPath.append(route)
        }
    }
}

#Preview {
    MainTabView()
        .environment(AccountModel())
        .environment(ToastCenter())
        .environment(PlayerModel())
        .environment(RecommendationModel())
        .environment(DownloadModel())
        .environment(NetworkMonitor())
        .environment(AppNavigator.shared)
}
