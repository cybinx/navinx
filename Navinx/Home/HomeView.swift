import PlaybackKit
import SubsonicKit
import SwiftUI

/// The Home tab: Flutter `HomeScreen`, with system glass for its capsule and chips.
///
/// Offline, every row keeps only what's downloaded, as in Flutter (C10). In season (24 Nov–15 Jan) the
/// "Navinx Playback" banner leads every category (C23, D92). The favourite-playlist rows are here,
/// behind C11's setting, off by default as in Flutter.
struct HomeView: View {
    @Environment(LibraryModel.self) private var library
    @Environment(RecommendationModel.self) private var recommendations
    @Environment(AccountModel.self) private var account
    @Environment(ToastCenter.self) private var toasts
    @Environment(PlayerModel.self) private var player
    @Environment(PinnedPlaylistsModel.self) private var pinnedPlaylists
    @Environment(DownloadModel.self) private var downloads

    /// Kept by `MainTabView`, so now playing can open a page here.
    @Binding var path: [LibraryRoute]
    @State private var category: HomeCategory = .all
    @State private var feed = HomeFeed()
    @State private var isPlaybackOpen = false
    /// The recap's banner, worked out off the main actor when the library changes (C54).
    @State private var showsRecapBanner = false
    @AppStorage(PinnedPlaylistsModel.showOnHomeKey) private var showsPinnedPlaylists = false

    private let posterSide: CGFloat = 155
    private let artistPosterSide: CGFloat = 140

    /// The songs recommendations work from: the full library once it's synced.
    private var songs: [Song] { library.allSongs.isEmpty ? library.randomSongs : library.allSongs }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                if isFirstLoad {
                    skeleton
                } else if isEmptyAfterLoad {
                    DetailMessage(icon: "music.note", text: "Nothing to show yet") {
                        Task { await library.refresh() }
                    }
                    .padding(.top, 120)
                } else {
                    sections
                }
            }
            // A separate task: a cancelled pull (the list changing under it) must not stop the load.
            .refreshable { await Task { await library.refresh() }.value }
            .keepsBottomRoom()
            .background(Palette.background)
            .safeAreaBar(edge: .top) { chips }
            .navigationTitle("Navinx")
            .toolbarTitleDisplayMode(.inlineLarge)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    // The capsule's icons in the primary colour, not red (D72).
                    Button("History", systemImage: "clock") { path.pushOnce(.history) }
                        .accessibilityIdentifier("homeHistory")
                        .tint(.primary)
                    Button("Settings", systemImage: "gearshape") { path.pushOnce(.settings) }
                        .accessibilityIdentifier("settingsGear")
                        .tint(.primary)
                }
            }
            .navigationDestination(for: LibraryRoute.self) { RouteDestination(route: $0, path: $path) }
        }
        .fullScreenCover(isPresented: $isPlaybackOpen) { RecapView() }
        .environment(\.openLibraryRoute) { path.append($0) }
        // In season and with plays to show: the recap reads the server's counts fresh, else these same
        // songs, and counts only grow, so a banner shown here never opens onto "Nothing to recap yet".
        .task(id: RecapBannerKey(songs: library.allSongs.count, synced: library.lastSynced)) {
            let today = RecapSeason.today
            guard RecapSeason.isInSeason(today) else {
                showsRecapBanner = false
                return
            }
            let songs = library.allSongs
            showsRecapBanner = await Task.detached(priority: .utility) {
                RecapSeason.showsBanner(on: today, songs: songs)
            }.value
        }
        .task(id: HomeFeed.key(data: recommendations.data, songs: songs)) { await rankFeed() }
        .task(id: showsPinnedPlaylists ? pinnedPlaylists.loadKey(library.playlists) : "") {
            guard showsPinnedPlaylists else { return }
            await pinnedPlaylists.loadSongs(library.playlists, client: account.client)
        }
    }

    /// What the rows show: offline, only what's downloaded (Flutter `isOffline`).
    private var shown: OfflineLogic.Home {
        let all = OfflineLogic.Home(latestAlbums: library.latestAlbums, playlists: library.playlists, feed: feed)
        guard account.isOffline else { return all }
        return OfflineLogic.home(
            latestAlbums: all.latestAlbums,
            playlists: all.playlists,
            feed: feed,
            downloadedIDs: downloads.downloadedIDs,
            downloadedAlbumIDs: Set(downloads.songsByAlbum.keys),
            isPlaylistDownloaded: { downloads.allDownloaded(downloads.playlist(id: $0.id)?.songs ?? []) }
        )
    }

    /// The favourite-playlist rows: offline, the downloaded ones, as saved with their download.
    private func favoriteRows(_ shown: OfflineLogic.Home) -> [Playlist] {
        guard account.isOffline else { return pinnedPlaylists.homeRows(library.playlists) }
        return shown.playlists
            .filter { pinnedPlaylists.isFavorite($0.id) }
            .compactMap { downloads.playlist(id: $0.id) }
    }

    /// Flutter shows the placeholders until the first load ends; a saved library shows at once (D22).
    private var isFirstLoad: Bool {
        library.isLoading && !library.isInitialized && library.latestAlbums.isEmpty && library.playlists.isEmpty
    }

    /// The first load is over, online, and every list came back empty: a failed load looks the same
    /// as an empty server (the library keeps no failure of its own), so the message doesn't say which.
    private var isEmptyAfterLoad: Bool {
        account.client != nil && library.isInitialized && !library.isLoading && !library.isSyncingQuietly
            && library.latestAlbums.isEmpty && library.playlists.isEmpty && library.artists.isEmpty
            && library.allSongs.isEmpty && library.randomSongs.isEmpty
    }

    private func rankFeed() async {
        let data = recommendations.data
        let songs = songs
        let hour = Calendar.current.component(.hour, from: .now)
        let ranked = await Task.detached(priority: .userInitiated) {
            HomeFeed.make(data: data, songs: songs, hour: hour)
        }.value
        if !Task.isCancelled { feed = ranked }
    }

    // MARK: Chips

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(HomeCategory.allCases, id: \.self) { chip in
                        chipButton(chip)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            }
        }
        // On the Duo the row stops at the side strip instead of running under the clock (C17).
        .scrollClipDisabled()
        .clippedToPages()
    }

    private func chipButton(_ chip: HomeCategory) -> some View {
        let button = Button { category = chip } label: {
            Text(chip.title).font(.system(size: 13, weight: .semibold))
        }
        return button.filterChipStyle(selected: category == chip)
    }

    // MARK: Sections, in Flutter's order

    private var sections: some View {
        let shown = shown
        let feed = shown.feed
        return LazyVStack(alignment: .leading, spacing: 28) {
            if showsRecapBanner {
                RecapBanner(year: RecapSeason.year(for: RecapSeason.today)) { isPlaybackOpen = true }
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
            }
            if category.showsMusic { quickAccess(shown) }
            if category.showsPlaylists, showsPinnedPlaylists {
                ForEach(favoriteRows(shown)) { playlist in
                    songSection(playlist.name, playlist.songs ?? []) { path.append(.playlist(playlist)) }
                }
            }
            if category.showsMusic, !shown.latestAlbums.isEmpty { jumpBackIn(shown.latestAlbums) }
            if category.showsMadeForYou, !feed.personalized.isEmpty {
                songSection("Made For You", feed.personalized)
            }
            if category.showsMusic, !feed.replayPicks.isEmpty {
                songSection("Listen Again", feed.replayPicks)
            }
            if category.showsMadeForYou, !feed.heavyRotation.isEmpty {
                songSection("Your Top Hits", feed.heavyRotation)
            }
            if category.showsPlaylists, !shown.playlists.isEmpty { yourPlaylists(shown.playlists) }
            if category.showsMadeForYou {
                ForEach(feed.mixes.prefix(4)) { songSection($0.name, $0.songs) }
            }
            if category.showsMusic, !library.artists.isEmpty { artistsYouLove }
        }
        .padding(.top, 8)
        .padding(.bottom, 40)
    }

    /// Flutter `_buildSpotifyTopGrid`: Liked Songs, two playlists, three recent albums (or mixes).
    private func quickAccess(_ shown: OfflineLogic.Home) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2), spacing: 8) {
            ShortcutTile(title: "Liked Songs", onTap: { path.append(.favorites) }) {
                LinearGradient(colors: [Color(hex: 0x450AF5), Color(hex: 0x8E8EE5)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    .overlay {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(.white)
                    }
            }
            ForEach(shown.playlists.prefix(2)) { playlist in
                ShortcutTile(title: playlist.name, onTap: { path.append(.playlist(playlist)) }) {
                    AlbumArtwork(coverArt: playlist.coverArt, size: 56, cornerRadius: 0)
                }
                .playlistContextMenu(playlist)
            }
            if shown.latestAlbums.isEmpty {
                ForEach(shown.feed.mixes.prefix(3)) { mix in
                    ShortcutTile(title: mix.name, onTap: { play(mix.songs.first, in: mix.songs) }) {
                        AlbumArtwork(coverArt: mix.songs.first?.coverArt, size: 56, cornerRadius: 0)
                    }
                }
            } else {
                ForEach(shown.latestAlbums.prefix(3)) { album in
                    ShortcutTile(title: album.name, onTap: { path.append(.album(album)) }) {
                        AlbumArtwork(coverArt: album.coverArt, size: 56, cornerRadius: 0)
                    }
                    .albumContextMenu(album)
                }
            }
        }
        .padding(.horizontal, 16)
    }

    private func jumpBackIn(_ albums: [Album]) -> some View {
        HorizontalSection(title: "Jump back in", posterSide: posterSide) {
            ForEach(albums.prefix(12)) { album in
                CoverCard(
                    title: album.name,
                    subtitle: album.artist,
                    coverArt: album.coverArt,
                    size: posterSide,
                    onTap: { path.append(.album(album)) },
                    onPlay: { Task { await player.playAlbum(album, client: account.client, toasts: toasts, downloads: downloads) } }
                )
                .albumContextMenu(album)
            }
        }
    }

    private func yourPlaylists(_ playlists: [Playlist]) -> some View {
        HorizontalSection(title: "Your Playlists", posterSide: posterSide) {
            ForEach(playlists.prefix(12)) { playlist in
                // "Playlist • Musly" in Flutter (D35).
                CoverCard(title: playlist.name, subtitle: "Playlist • Navinx", size: posterSide, onTap: { path.append(.playlist(playlist)) }) {
                    PlaylistArtwork(playlist: playlist, size: posterSide - 30, cornerRadius: 4)
                }
                .playlistContextMenu(playlist)
            }
        }
    }

    private var artistsYouLove: some View {
        HorizontalSection(title: "Artists You Love", posterSide: artistPosterSide) {
            ForEach(library.artists.prefix(10), id: \.listKey) { artist in
                CoverCard(
                    title: artist.name,
                    subtitle: "Artist",
                    coverArt: artist.artworkReference,
                    size: artistPosterSide,
                    isRound: true,
                    onTap: { path.append(.artist(artist)) }
                )
            }
        }
    }

    /// Flutter `_buildMixSection`: a card plays the row as a queue, from that song.
    private func songSection(_ title: String, _ songs: [Song], onShowAll: (() -> Void)? = nil) -> some View {
        HorizontalSection(title: title, posterSide: posterSide, onShowAll: onShowAll) {
            // By place: a playlist can hold a song twice, and the same ID twice breaks the row.
            ForEach(Array(songs.prefix(12).enumerated()), id: \.offset) { _, song in
                CoverCard(
                    title: song.title,
                    subtitle: song.artist,
                    coverArt: song.coverArt,
                    size: posterSide,
                    onTap: { play(song, in: songs) },
                    onPlay: { play(song, in: songs) }
                )
            }
        }
    }

    private func play(_ song: Song?, in songs: [Song]) {
        guard let song else { return }
        player.playSong(song, playlist: songs)
    }

    /// Flutter `_buildLoadingState`.
    private var skeleton: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                ForEach(0..<2, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 6).fill(Palette.fieldFill).frame(height: 56)
                }
            }
            RoundedRectangle(cornerRadius: 4).fill(Palette.fieldFill).frame(width: 140, height: 20).padding(.top, 24)
            HStack(spacing: 12) {
                ForEach(0..<4, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 8).fill(Palette.fieldFill).frame(width: 140, height: 160)
                }
            }
            .padding(.top, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
    }
}

/// What Home's recap banner is worked out again for: the library's songs changing.
private struct RecapBannerKey: Hashable {
    let songs: Int
    let synced: Date?
}
