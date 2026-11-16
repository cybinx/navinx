import PlaybackKit
import SubsonicKit
import SwiftUI

/// Flutter `ArtistScreen`.
struct ArtistView: View {
    let artistID: String

    @Environment(AccountModel.self) private var account
    @Environment(LibraryModel.self) private var library
    @Environment(ToastCenter.self) private var toasts
    @Environment(PlayerModel.self) private var player
    @Environment(DownloadModel.self) private var downloads
    @Environment(\.openLibraryRoute) private var openRoute
    @State private var artist: Artist?
    @State private var info: ArtistInfo?
    @State private var topSongs: [Song] = []
    @State private var albums: [Album] = []
    @State private var isLoading = true
    @State private var showsTitle = false

    var body: some View {
        Group {
            if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let artist {
                page(artist)
            } else {
                Text("Artist not found").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Palette.background)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    /// Each call fails on its own, leaving that part empty, as in Flutter. With no server, the saved
    /// library's albums (D52; Flutter showed the name and nothing else). Top songs need the server.
    private func load() async {
        guard let client = account.client else {
            albums = OfflineLogic.artistAlbums(artistID: artistID, libraryAlbums: library.allAlbums)
            artist = DetailLogic.fallbackArtist(id: artistID, cached: library.artists, songs: library.allSongs, albums: albums)
            isLoading = false
            return
        }
        let id = artistID
        async let found = try? client.artist(id: id)
        async let foundInfo = try? client.artistInfo(id: id)
        async let foundSongs = try? client.topSongs(artistID: id)
        async let foundAlbums = try? client.artistAlbums(artistID: id)
        let (artist, info, songs, albums) = await (found, foundInfo, foundSongs, foundAlbums)
        // A reload keeps any part that fails, so the page doesn't empty.
        self.info = info ?? self.info
        topSongs = songs ?? topSongs
        self.albums = albums ?? self.albums
        self.artist = artist ?? self.artist ?? DetailLogic.fallbackArtist(
            id: id,
            cached: library.artists,
            songs: library.allSongs,
            albums: self.albums
        )
        isLoading = false
    }

    private func page(_ artist: Artist) -> some View {
        let sections = DetailLogic.sections(albums)
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                hero(artist)
                if !topSongs.isEmpty {
                    PlayShuffleRow(songs: topSongs)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                    sectionTitle("Top Songs").padding(.top, 16)
                    // The rows bring their own 16 pt side padding.
                    ForEach(Array(topSongs.prefix(5).enumerated()), id: \.element.id) { index, song in
                        SongRow(song: song, list: topSongs, index: index, showsAlbum: true)
                    }
                    Color.clear.frame(height: 24)
                }
                albumSection("Albums", sections.albums)
                albumSection("EPs", sections.eps)
                albumSection("Singles", sections.singles)
                similarArtists
                // Navidrome passes Last.fm's biography on as HTML.
                let biography = DetailLogic.plainBiography(info?.biography ?? "")
                if !biography.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("About \(artist.name)").font(.system(size: 24))
                        Text(biography)
                            .font(.system(size: 15))
                            .lineSpacing(7)
                            .opacity(0.8)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                }
                Color.clear.frame(height: 16)
            }
        }
        .ignoresSafeArea(edges: .top)
        .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y + $0.contentInsets.top > 200 } action: { _, past in
            showsTitle = past
        }
        // Flutter's pinned bar shows the name once the picture has scrolled away.
        .navigationTitle(showsTitle ? artist.name : "")
        .toolbar {
            if account.client != nil {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Download All Albums", systemImage: "arrow.down.circle") {
                        Task { await downloadDiscography() }
                    }
                    .disabled(albums.isEmpty)
                    Button("Add to Queue", systemImage: "music.note.list") {
                        Task { await queueUpArtist() }
                    }
                    .disabled(albums.isEmpty)
                }
            }
        }
    }

    /// The picture fading down into the page, with the name over it.
    private func hero(_ artist: Artist) -> some View {
        AlbumArtwork(
            coverArt: DetailLogic.artistArt(artist, info: info),
            size: 200,
            cornerRadius: 0,
            flexible: true
        )
        .frame(height: 280)
        .frame(maxWidth: .infinity)
        .mask(LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom))
        .overlay(alignment: .bottom) {
            Text(artist.name)
                .font(.system(size: 26, weight: .semibold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
        }
    }

    /// Flutter `_downloadAllAlbums`: each album queued on its own, so each gets its own button state.
    private func downloadDiscography() async {
        guard let client = account.client else { return }
        var songCount = 0
        for album in albums {
            guard let full = try? await client.album(id: album.id), !full.songs.isEmpty else { continue }
            songCount += downloads.download(album: full, songs: full.songs)
        }
        if songCount > 0 { toasts.show("Queued \(CountText.of(songCount, "song")) from \(CountText.of(albums.count, "album")) for download…") }
    }

    /// Flutter `_addArtistToQueue`: every album's songs, in order. It says at once what it's doing, since
    /// the albums come one at a time, and then how many songs went in (C66, the owner's word; Flutter
    /// said only "Added artist to Queue" at the end).
    private func queueUpArtist() async {
        guard let client = account.client else { return }
        toasts.show(artist.map { "Adding all songs by \($0.name) to the queue…" } ?? "Adding all songs to the queue…")
        do {
            var songs: [Song] = []
            for album in albums {
                songs += try await client.albumSongs(albumID: album.id)
            }
            player.queueUpAll(songs)
            toasts.show("Added \(CountText.of(songs.count, "song")) to the queue")
        } catch {
            toasts.show("Failed adding artist to Queue")
        }
    }

    /// C35 (D142): the server's similar artists that are in the library, as Home's "Artists You Love"
    /// shows artists. Absent while loading, with none, on a failure and offline (it needs the server).
    @ViewBuilder
    private var similarArtists: some View {
        if let similar = info?.similarArtists, !similar.isEmpty {
            HorizontalSection(title: "Similar Artists", posterSide: 140) {
                ForEach(similar) { artist in
                    CoverCard(
                        title: artist.name,
                        subtitle: "Artist",
                        coverArt: artist.artworkReference,
                        size: 140,
                        isRound: true,
                        onTap: { openRoute(.artist(artist)) }
                    )
                }
            }
            .padding(.bottom, 24)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("similarArtists")
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 24))
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
    }

    @ViewBuilder
    private func albumSection(_ title: String, _ albums: [Album]) -> some View {
        if !albums.isEmpty {
            sectionTitle(title)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: 2), spacing: 16) {
                ForEach(albums) { AlbumPoster(album: $0) }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
    }
}
