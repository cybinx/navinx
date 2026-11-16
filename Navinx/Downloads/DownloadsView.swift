import PlaybackKit
import SubsonicKit
import SwiftUI

/// Flutter `DownloadsScreen`, from the Library's "Downloaded Songs": every downloaded song, and every
/// album with one (Flutter kept only the cached library's songs and the 20 albums played last). It
/// follows the downloads as they land.
struct DownloadsView: View {
    private enum Page: Hashable { case songs, albums }

    @Environment(DownloadModel.self) private var downloads
    @State private var page: Page = .songs

    var body: some View {
        VStack(spacing: 0) {
            // The page's own title, so it moves with the page in a push and a pop (C66).
            PageTitle("Downloads")
            Picker("Downloads", selection: $page) {
                Text("Songs").tag(Page.songs)
                Text("Albums").tag(Page.albums)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            if page == .songs {
                songsPage
            } else {
                albumsPage
            }
        }
        .background(Palette.background)
        .ownPageTitle("Downloads")
    }

    @ViewBuilder
    private var songsPage: some View {
        let songs = downloads.offlineSongs
        if songs.isEmpty {
            emptyMessage(icon: "checkmark.circle", text: "No downloaded songs yet")
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                        SongRow(song: song, list: songs, index: index, showsAlbum: true)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var albumsPage: some View {
        let albums = downloads.downloadedAlbums
        if albums.isEmpty {
            emptyMessage(icon: "opticaldisc", text: "No downloaded albums yet")
        } else {
            ScrollView {
                AlbumWall(albums: albums, cellRatio: 0.75)
            }
        }
    }

    private func emptyMessage(icon: String, text: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 56))
                .foregroundStyle(.gray)
            Text(text)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Flutter `DownloadPlaylistStatusScreen`: each playlist with how many of its songs are downloaded.
/// It fetches every playlist's songs when it opens, so each row has its count (Flutter's showed
/// "N songs" for one not opened since launch).
struct PlaylistDownloadsView: View {
    @Environment(LibraryModel.self) private var library
    @Environment(AccountModel.self) private var account
    @Environment(DownloadModel.self) private var downloads
    @State private var songs: [String: [Song]] = [:]

    private var playlists: [Playlist] {
        library.playlists.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    var body: some View {
        Group {
            if playlists.isEmpty {
                Text("No playlists found")
                    .foregroundStyle(Palette.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(playlists) { playlist in
                    row(playlist)
                        .listRowBackground(Color.clear)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .background(Palette.background)
        .navigationTitle("Playlist Downloads")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: playlists.map(\.id)) { await load() }
    }

    /// The server's lists, six at a time; offline, the copies saved with a download or an opening.
    private func load() async {
        for playlist in playlists {
            if let saved = downloads.playlist(id: playlist.id)?.songs ?? library.openedPlaylists[playlist.id]?.songs {
                songs[playlist.id] = saved
            }
        }
        guard let client = account.client else { return }
        let ids = playlists.map(\.id)
        for start in stride(from: 0, to: ids.count, by: 6) {
            let batch = ids[start..<min(start + 6, ids.count)]
            let found = await withTaskGroup(of: (String, [Song]?).self) { group in
                for id in batch {
                    group.addTask { (id, try? await client.playlist(id: id).songs ?? []) }
                }
                var found: [(String, [Song]?)] = []
                for await result in group { found.append(result) }
                return found
            }
            guard !Task.isCancelled else { return }
            for case let (id, list?) in found { songs[id] = list }
        }
    }

    private func row(_ playlist: Playlist) -> some View {
        HStack(spacing: 12) {
            Group {
                if playlist.coverArt != nil {
                    AlbumArtwork(coverArt: playlist.coverArt, size: 48, cornerRadius: 8)
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Palette.accent.opacity(0.15))
                        .frame(width: 48, height: 48)
                        .overlay { Image(systemName: "music.note").foregroundStyle(.tint) }
                }
            }
            Text(playlist.name)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            status(playlist)
        }
        .frame(minHeight: 56)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("playlistDownloadRow")
    }

    @ViewBuilder
    private func status(_ playlist: Playlist) -> some View {
        if let list = songs[playlist.id] {
            let total = list.count
            let done = downloads.downloadedCount(list)
            if total > 0, done >= total {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 16))
                    Text("\(done) / \(total)").font(.system(size: 14, weight: .semibold))
                }
                .foregroundStyle(Palette.green)
            } else {
                Text("\(done) / \(total)")
                    .font(.system(size: 14))
                    .foregroundStyle(done > 0 ? AnyShapeStyle(Palette.orange) : AnyShapeStyle(.primary.opacity(0.5)))
            }
        } else {
            Text(PlaylistMembership.countText(playlist.songCount))
                .font(.system(size: 13))
                .foregroundStyle(.primary.opacity(0.5))
        }
    }
}
