import SubsonicKit
import SwiftUI

/// An album or a playlist whose songs are taken all at once: "Add all to playlist" and "Download
/// all" (C48, D166; the user, 2026-11-14: "for playlists and albums there should be a download all
/// or a add all to playlist"). Not in the Flutter app.
enum BatchSource {
    case album(Album)
    case playlist(Playlist)

    var name: String {
        switch self {
        case .album(let album): album.name
        case .playlist(let playlist): playlist.name
        }
    }

    /// Every song as the server has it now, in order.
    func songs(client: SubsonicClient) async throws -> [Song] {
        switch self {
        case .album(let album): try await client.album(id: album.id).songs
        case .playlist(let playlist): try await client.playlist(id: playlist.id).songs ?? []
        }
    }
}

/// What "Add all to playlist" did, for its message.
struct BatchAddResult: Equatable {
    var added: Int
    /// Already in the playlist (D166: skipped, and said).
    var skipped: Int

    func message(playlist: String) -> String {
        func songs(_ count: Int) -> String { count == 1 ? "1 song" : "\(count) songs" }
        if added == 0 {
            if skipped == 0 { return "No songs to add" }
            return skipped == 1 ? "That song is already in \(playlist)" : "All \(skipped) songs are already in \(playlist)"
        }
        let already = skipped == 0 ? "" : " (\(skipped) already there)"
        return "Added \(songs(added)) to \(playlist)\(already)"
    }
}

@MainActor
enum BatchActions {
    /// Adds every song of `source` to `playlist` in one request, at its end, skipping the songs it
    /// already has (the same check as one song's "Add to Playlist"). If the playlist can't be read,
    /// nothing is added: adding blind would double its songs.
    static func addAll(_ source: BatchSource, to playlist: Playlist, client: SubsonicClient) async throws -> BatchAddResult {
        let songs = try await source.songs(client: client)
        let existing = try await client.playlist(id: playlist.id).songs ?? []
        let missing = PlaylistMembership.missing(songs, from: existing)
        if !missing.isEmpty {
            try await client.addToPlaylist(id: playlist.id, songIDs: missing.map(\.id))
        }
        return BatchAddResult(added: missing.count, skipped: songs.count - missing.count)
    }
}

/// The two rows, in the album and playlist pages' ⋯ menus, the library's playlist options and a
/// long press on an album or playlist card. Online only: both ask the server for the songs.
struct BatchItems: View {
    let source: BatchSource

    @Environment(AccountModel.self) private var account
    @Environment(DownloadModel.self) private var downloads
    @Environment(SongSheets.self) private var sheets
    @Environment(ToastCenter.self) private var toasts

    var body: some View {
        if account.client != nil {
            Button("Add all to playlist", systemImage: "rectangle.stack.badge.plus") {
                sheets.batchRequest = BatchRequest(source: source)
            }
            if canDownload {
                Button("Download all", systemImage: "arrow.down.circle") {
                    Task { await download() }
                }
            }
        }
    }

    /// Not while it's downloading or already here (its page's cloud button cancels and removes).
    private var canDownload: Bool {
        switch source {
        case .album(let album): downloads.state(of: album.id) == .none && !downloads.isAlbumDownloaded(album)
        case .playlist(let playlist): downloads.state(of: playlist.id) == .none
        }
    }

    /// As the page's cloud button, with the songs asked of the server first (a card has none). An
    /// empty album or playlist does nothing.
    private func download() async {
        guard let client = account.client else { return }
        do {
            let count: Int
            switch source {
            case .album(let album):
                let full = try await client.album(id: album.id)
                guard !full.songs.isEmpty else { return }
                count = downloads.download(album: full, songs: full.songs)
            case .playlist(let playlist):
                let full = try await client.playlist(id: playlist.id)
                guard let songs = full.songs, !songs.isEmpty else { return }
                count = downloads.download(playlist: full, songs: songs)
            }
            toasts.show("Queued \(CountText.of(count, "song")) for download…")
        } catch {
            toasts.show("Error loading songs")
        }
    }
}

extension View {
    /// A long press on an album's card: its batch actions (C48). Nothing offline.
    func albumContextMenu(_ album: Album) -> some View {
        modifier(AlbumContextMenu(album: album))
    }
}

private struct AlbumContextMenu: ViewModifier {
    let album: Album

    @Environment(AccountModel.self) private var account

    func body(content: Content) -> some View {
        if account.client != nil {
            content.contextMenu { BatchItems(source: .album(album)) }
        } else {
            content
        }
    }
}
