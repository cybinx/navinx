import PlaybackKit
import SubsonicKit
import SwiftUI

/// Flutter `AlbumScreen`.
struct AlbumView: View {
    let albumID: String

    @Environment(AccountModel.self) private var account
    @Environment(ToastCenter.self) private var toasts
    @Environment(PlayerModel.self) private var player
    @Environment(DownloadModel.self) private var downloads
    @Environment(SmartDownloads.self) private var smartDownloads
    @Environment(LibraryModel.self) private var library
    @State private var album: Album?
    @State private var isLoading = true
    /// The first load failed for a reason other than the album being gone.
    @State private var loadFailed = false
    @State private var showsFilter = false
    @State private var query = ""

    var body: some View {
        Group {
            if isLoading {
                AlbumSkeleton()
            } else if let album {
                page(album)
            } else if loadFailed {
                DetailMessage(icon: "exclamationmark.circle", text: "Error loading album") {
                    Task {
                        isLoading = true
                        await load()
                    }
                }
            } else {
                Text("Album not found").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Palette.background)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    /// An album the server says is gone shows "Album not found" (Flutter's catch for any failure); a
    /// load that failed for another reason shows an error with Retry. With no server, the album as saved, with
    /// every song it knows (D52); Flutter asked the server anyway and said "Album not found".
    private func load() async {
        if let client = account.client {
            // A reload that fails keeps the album already shown.
            do {
                let fresh = try await client.album(id: albumID)
                album = fresh
                downloads.refresh(collectionID: fresh.id, songs: fresh.songs)
                loadFailed = false
            } catch {
                loadFailed = album == nil && !DetailLogic.isMissing(error)
            }
        } else {
            let downloaded = downloads.album(id: albumID)
            album = OfflineLogic.album(
                id: albumID,
                downloaded: downloaded,
                isComplete: downloads.records.collections[albumID] != nil,
                libraryAlbums: library.allAlbums,
                librarySongs: library.allSongs
            )
        }
        isLoading = false
    }

    private func page(_ album: Album) -> some View {
        GeometryReader { geometry in
            let isSmall = geometry.size.width < 380
            ScrollView {
                VStack(spacing: 0) {
                    let side: CGFloat = isSmall ? 190 : 240
                    AlbumArtwork(coverArt: album.coverArt, size: side, cornerRadius: 14, prominentShadow: true)
                        .overlay(alignment: .bottomTrailing) {
                            if downloads.allDownloaded(album.songs) { DownloadedCoverBadge(style: .album) }
                        }
                        .collapsingHeaderArt()
                        .padding(.top, 12)
                        .padding(.bottom, 16)
                    header(album, isSmall: isSmall)
                        .padding(.horizontal, 20)
                    LazyVStack(spacing: 0) {
                        let shown = DetailLogic.filter(album.songs, query: query)
                        ForEach(Array(shown.enumerated()), id: \.element.id) { index, song in
                            SongRow(song: song, list: shown, index: index, showsArtwork: false, showsArtist: false, showsTrackNumber: true, height: 58)
                        }
                    }
                }
            }
        }
        .toolbar { toolbar(album) }
    }

    private func header(_ album: Album, isSmall: Bool) -> some View {
        VStack(spacing: 4) {
            Text(album.name)
                .font(.system(size: 22, weight: .bold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
            ArtistNames(
                artists: album.displayArtists,
                font: .system(size: isSmall ? 16 : 17, weight: .semibold),
                color: Palette.accent
            )
            Text(DetailLogic.albumSummary(album: album, songs: album.songs))
                .font(.system(size: 13))
                .foregroundStyle(Palette.secondaryText)
                .lineLimit(1)
            PlayShuffleRow(songs: album.songs)
                .padding(.top, 16)
            if showsFilter {
                SongFilterField(placeholder: "Filter tracks...", text: $query)
                    .padding(.top, 12)
            }
        }
        .padding(.bottom, 24)
    }

    @ToolbarContentBuilder
    private func toolbar(_ album: Album) -> some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button("Search in album", systemImage: showsFilter ? "magnifyingglass.circle.fill" : "magnifyingglass") {
                showsFilter.toggle()
                if !showsFilter { query = "" }
            }
            Menu("More options", systemImage: "ellipsis.circle") {
                Button("Add all to queue", systemImage: "text.badge.plus") {
                    player.queueUpAll(album.songs, toasts: toasts)
                }
                BatchItems(source: .album(album))
            }
            if account.client != nil {
                Button(album.starred ? "Remove from Favorites" : "Add to Favorites", systemImage: album.starred ? "heart.fill" : "heart") {
                    Task { await toggleFavorite() }
                }
                .tint(album.starred ? Palette.accent : nil)
                CollectionDownloadButton(target: .album(album))
            }
        }
    }

    /// Flutter `_toggleLike`: the heart changes at once and changes back on failure.
    private func toggleFavorite() async {
        guard let album, let client = account.client else { return }
        let wasStarred = album.starred
        self.album?.starred = !wasStarred
        do {
            if wasStarred {
                try await client.unstar(albumID: album.id)
            } else {
                try await client.star(albumID: album.id)
            }
            // Album stars don't go through the player: Smart Downloads hear of them here (C37).
            smartDownloads.albumStarChanged(album, isStarred: !wasStarred)
        } catch {
            self.album?.starred = wasStarred
            toasts.show("Failed to update liked status")
        }
    }
}
