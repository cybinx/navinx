import PlaybackKit
import SubsonicKit
import SwiftUI

/// Flutter `FavoritesScreen`: the favourite songs and albums, under a segmented control. Where Flutter
/// shows empty lists after a failed load (and offline), this says so, with a Retry, or that it needs the server.
struct FavoritesView: View {
    private enum Page: Hashable { case songs, albums }

    @Environment(AccountModel.self) private var account
    @Environment(ToastCenter.self) private var toasts
    @Environment(PlayerModel.self) private var player
    @Environment(DownloadModel.self) private var downloads
    @State private var page: Page = .songs
    @State private var songs: [Song] = []
    @State private var albums: [Album] = []
    @State private var isLoading = true
    @State private var hasLoaded = false
    @State private var failed = false
    @State private var removing: Song?

    /// A song un-favourited anywhere this run leaves the list. Flutter's stayed until the page reopened.
    private var shownSongs: [Song] { songs.filter { player.latest($0).starred } }

    var body: some View {
        VStack(spacing: 0) {
            // The page's own title, so it moves with the page in a push and a pop (C66).
            PageTitle("Favorites")
            Picker("Favorites", selection: $page) {
                Text("Songs").tag(Page.songs)
                Text("Albums").tag(Page.albums)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if account.isOffline {
                // The favourites are the server's list; downloads aren't kept as one.
                DetailMessage(icon: "wifi.slash", text: "Favorites need your server")
            } else if failed {
                DetailMessage(icon: "exclamationmark.circle", text: "Error loading favorites") {
                    Task {
                        isLoading = true
                        await load()
                    }
                }
            } else if page == .songs {
                songsPage
            } else {
                albumsPage
            }
        }
        .background(Palette.background)
        .ownPageTitle("Favorites")
        .toolbar {
            if !isLoading, !shownSongs.isEmpty, page == .songs {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Download All Favorites", systemImage: "arrow.down.circle", action: downloadAll)
                }
            }
        }
        .task { await load() }
        .alert(
            "Remove from Favorites?",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            presenting: removing
        ) { song in
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) { remove(song) }
        } message: { song in
            Text("Do you want to remove \"\(song.title)\" from favorites?")
        }
    }

    private func load() async {
        do {
            guard let client = account.client else { throw SubsonicError.network }
            let starred = try await client.starred()
            songs = starred.songs
            albums = starred.albums
            hasLoaded = true
            failed = false
        } catch {
            // The lists already shown stay, if there are any.
            failed = !hasLoaded
        }
        isLoading = false
    }

    /// Flutter `_downloadAllFavorites`, through the albums' queue: it says so at once and skips the
    /// songs already there (Flutter fetched every one, one at a time, then said "Queued").
    private func downloadAll() {
        let count = downloads.download(batch: "favorites", name: "Favorites", songs: shownSongs)
        toasts.show(count > 0 ? "Queued \(CountText.of(count, "song")) for download…" : "All favorites are already downloaded")
    }

    @ViewBuilder
    private var songsPage: some View {
        let shown = shownSongs
        if shown.isEmpty {
            emptyMessage(icon: "heart", text: "No favorite songs yet")
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    HStack(spacing: 10) {
                        PlayShuffleRow(songs: shown, playTitle: "Play All")
                        Button("Download All", systemImage: "arrow.down.circle", action: downloadAll)
                            .labelStyle(.iconOnly)
                            .font(.system(size: 17))
                            .foregroundStyle(.tint)
                            .appGlassButtonStyle()
                            .buttonBorderShape(.circle)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, song in
                        SongRow(song: song, list: shown, index: index, showsAlbum: true)
                            .modifier(SwipeToRemove(systemImage: "heart.slash", slidesAway: false) { removing = song })
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var albumsPage: some View {
        if albums.isEmpty {
            emptyMessage(icon: "opticaldisc", text: "No favorite albums yet")
        } else {
            ScrollView {
                AlbumWall(albums: albums, cellRatio: 0.75)
            }
        }
    }

    private func emptyMessage(icon: String, text: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 64))
                .foregroundStyle(.gray)
            Text(text)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func remove(_ song: Song) {
        Task {
            do {
                try await player.toggleFavorite(for: song)
                toasts.show("Removed from favorites")
            } catch {
                toasts.show("Failed to remove: \(error.localizedDescription)")
            }
        }
    }
}

/// Flutter's album grids: two columns of `AlbumCard`s, in cells 0.76 as wide as they're tall (Favorites:
/// 0.75). The cover takes what the text leaves of the cell's height, so it's narrower than the cell,
/// as measured from Flutter's: 150 pt in a 177 pt cell, which leaves room for the A–Z index.
struct AlbumWall: View {
    let albums: [Album]
    var cellRatio: CGFloat = 0.76

    private static let textHeight: CGFloat = 83

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: 2), spacing: 16) {
            ForEach(albums) { album in
                Color.clear
                    .aspectRatio(cellRatio, contentMode: .fit)
                    .overlay {
                        GeometryReader { cell in
                            AlbumPoster(album: album, artSide: cell.size.height - Self.textHeight)
                        }
                    }
                    .id(album.id)
            }
        }
        .padding(16)
    }
}
