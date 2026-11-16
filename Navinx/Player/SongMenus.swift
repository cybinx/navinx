import PlaybackKit
import SubsonicKit
import SwiftUI

/// Whether a song is already on a playlist (Flutter's check before adding): the same ID, or the same
/// title and artist, ignoring case and outer spaces.
nonisolated enum PlaylistMembership {
    private static func normal(_ text: String?) -> String {
        (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// The same song by title and artist, whatever its ID (another album's copy of it).
    private static func nameKey(_ song: Song) -> String { normal(song.title) + "\n" + normal(song.artist) }

    static func contains(_ song: Song, in songs: [Song]) -> Bool {
        songs.contains {
            $0.id == song.id || (normal($0.title) == normal(song.title) && normal($0.artist) == normal(song.artist))
        }
    }

    /// The songs of `songs` a playlist holding `existing` doesn't have yet, each once, in order: by
    /// the same check as `contains` (C48: "Add all to playlist" skips what's already there).
    static func missing(_ songs: [Song], from existing: [Song]) -> [Song] {
        var ids = Set(existing.map(\.id))
        var names = Set(existing.map(nameKey))
        return songs.filter { song in
            let key = nameKey(song)
            guard !ids.contains(song.id), !names.contains(key) else { return false }
            ids.insert(song.id)
            names.insert(key)
            return true
        }
    }

    /// Flutter's `songsCount`.
    static func countText(_ count: Int?) -> String {
        switch count ?? 0 {
        case 0: "No songs"
        case 1: "1 song"
        case let count: "\(count) songs"
        }
    }
}

// MARK: - The menus

/// Flutter `SongOptionsModal`'s rows in its order, as a menu next to its button (D30). Jukebox is a
/// later feature, and Flutter's rows for it only show with it on.
struct SongOptionsItems: View {
    let song: Song

    @Environment(PlayerModel.self) private var player
    @Environment(SongSheets.self) private var sheets
    @Environment(ToastCenter.self) private var toasts
    @Environment(AccountModel.self) private var account
    @Environment(DownloadModel.self) private var downloads
    @Environment(\.openLibraryRoute) private var openRoute
    /// Settings' "Show Star Ratings", as on now playing: off, there's no "Rate Song" (D213).
    @AppStorage(PlayerDisplayOptions.showsRatingStars) private var showsStarRatings = false

    var body: some View {
        let song = player.latest(song)
        let rating = song.userRating ?? 0
        Button(
            song.starred ? "Remove from Liked Songs" : "Add to Liked Songs",
            systemImage: song.starred ? "heart.fill" : "heart"
        ) {
            toggleFavorite(song)
        }
        Button("Play Next", systemImage: "play.fill") { player.queueUpNext(song) }
        Button("Add to Queue", systemImage: "music.note.list") { player.queueUp(song) }
        Button("Add to Playlist", systemImage: "text.badge.plus") {
            sheets.playlistRequest = PlaylistRequest(song: song, title: "Add to Playlist")
        }
        Button("Go to Album", systemImage: "opticaldisc") {
            guard let albumID = song.albumID else { return }
            openRoute(.album(Album(id: albumID, name: song.album ?? "")))
        }
        // Shown with nothing to open, but disabled, so the rows keep their places.
        .disabled(song.albumID == nil)
        goToArtist(song)
        if showsStarRatings {
            Menu(rating > 0 ? "Rate Song (\(rating) \(rating == 1 ? "star" : "stars"))" : "Rate Song", systemImage: rating > 0 ? "star.fill" : "star") {
                ratingItems(song, current: rating)
            }
        }
        downloadItem(song)
        // Last, in its own section (D142).
        Section {
            SongInfoItem(song: song)
        }
    }

    /// Flutter's last row: Download, "Downloading... N%", or Downloaded (which asks before removing).
    /// Offline there's no row, as in Flutter. Reopened mid-download it shows how far it got then.
    @ViewBuilder
    private func downloadItem(_ song: Song) -> some View {
        if !account.isOffline {
            if downloads.isDownloaded(song.id) {
                Button("Downloaded", systemImage: "checkmark.circle.fill") {
                    sheets.removingDownload = song
                }
            } else if downloads.isSongDownloading(song.id) {
                let percent = Int((downloads.songProgress[song.id] ?? 0) * 100)
                Button("Downloading... \(percent)%", systemImage: "arrow.down.circle") {}
                    .disabled(true)
            } else {
                Button("Download", systemImage: "arrow.down.circle") { downloads.downloadSong(song) }
            }
        }
    }

    /// Flutter's dialog of five stars and "Remove Rating", as a submenu.
    @ViewBuilder
    private func ratingItems(_ song: Song, current: Int) -> some View {
        ForEach((1...5).reversed(), id: \.self) { stars in
            Button {
                rate(song, stars)
            } label: {
                if stars == current {
                    Label(starsText(stars), systemImage: "checkmark")
                } else {
                    Text(starsText(stars))
                }
            }
        }
        if current > 0 {
            Button("Remove Rating") { rate(song, 0) }
        }
    }

    private func starsText(_ stars: Int) -> String {
        String(repeating: "★", count: stars) + String(repeating: "☆", count: 5 - stars)
    }

    private func toggleFavorite(_ song: Song) {
        Task {
            do {
                try await player.toggleFavorite(for: song)
                toasts.show(song.starred ? "Removed from Liked Songs" : "Added to Liked Songs")
            } catch {
                toasts.show("Error: \(error.localizedDescription)")
            }
        }
    }

    private func rate(_ song: Song, _ stars: Int) {
        Task {
            do {
                try await player.rate(song, rating: stars)
                toasts.show(stars > 0 ? "Rated \(stars) \(stars == 1 ? "star" : "stars")" : "Rating removed")
            } catch {
                toasts.show("Failed to set rating: \(error.localizedDescription)")
            }
        }
    }

    /// One artist opens their page; several are a submenu of names next to the row (D77).
    @ViewBuilder
    private func goToArtist(_ song: Song) -> some View {
        let artists = song.displayArtists
        if artists.count > 1 {
            Menu("Go to Artist", systemImage: "person") { ArtistChoiceItems(artists: artists) }
        } else {
            Button("Go to Artist", systemImage: "person") {
                if let artist = artists.first {
                    ArtistOpening.open(artist, client: account.client, toasts: toasts, route: openRoute)
                }
            }
            .disabled(artists.isEmpty)
        }
    }
}

/// Song Info (C35, D142): the song menus' last row, and now playing's ⋯.
struct SongInfoItem: View {
    let song: Song

    @Environment(SongSheets.self) private var sheets

    var body: some View {
        Button("Song Info", systemImage: "info.circle") { sheets.infoSong = song }
            .accessibilityIdentifier("songInfoItem")
    }
}

/// A ⋯ button that opens the song options next to itself.
struct SongOptionsButton: View {
    let song: Song
    var systemImage = "ellipsis"
    var rotated = false
    var color: Color = Palette.secondaryText
    var width: CGFloat = 44

    var body: some View {
        Menu {
            SongOptionsItems(song: song)
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 17))
                .rotationEffect(rotated ? .degrees(90) : .zero)
                .foregroundStyle(color)
                .frame(width: width, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Song options")
    }
}

extension View {
    /// A long press opens the song options, under Flutter's header of cover, title and artist.
    func songContextMenu(_ song: Song) -> some View {
        modifier(SongContextMenu(song: song))
    }
}

private struct SongContextMenu: ViewModifier {
    let song: Song

    @Environment(AccountModel.self) private var account

    func body(content: Content) -> some View {
        content.contextMenu {
            SongOptionsItems(song: song)
        } preview: {
            // A preview is hosted on its own, without the environment: the cover needs this.
            SongMenuHeader(song: song).environment(account)
        }
    }
}

private struct SongMenuHeader: View {
    let song: Song

    var body: some View {
        HStack(spacing: 12) {
            AlbumArtwork(coverArt: song.coverArt, size: 60)
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(1)
                if let artist = song.artist {
                    Text(artist)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.secondaryText)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(width: 320)
        .background(Palette.surface)
    }
}

/// Flutter `NowPlayingMoreMenu`: the sleep timer, then the playback speed and "Preserve pitch".
/// Flutter's speed slider is a submenu of its seven values here, as the sleep timer's choices are
/// (D87). Song Info last, for the playing song (C35, D142).
struct NowPlayingMoreItems: View {
    @Environment(PlayerModel.self) private var player

    private var status: String {
        switch player.sleepTimerChoice {
        case .off:
            return "Off"
        case .whenSongEnds:
            return "End of Song"
        case .minutes:
            let left = Int(max(player.sleepTimerDeadline?.timeIntervalSinceNow ?? 0, 0).rounded(.up))
            return "\(left / 60):" + String(format: "%02d", left % 60)
        }
    }

    var body: some View {
        // Reading the position keeps the time left ticking while the menu is open.
        let _ = player.sleepTimerDeadline == nil ? 0 : player.position
        Menu {
            Picker("Sleep Timer", selection: Binding(
                get: { player.sleepTimerChoice },
                set: { player.armSleepTimer($0) }
            )) {
                Text("Off").tag(SleepTimerChoice.off)
                ForEach([5, 10, 15, 30], id: \.self) { minutes in
                    Text("\(minutes) min").tag(SleepTimerChoice.minutes(minutes))
                }
                Text("End of Song").tag(SleepTimerChoice.whenSongEnds)
            }
            .pickerStyle(.inline)
        } label: {
            // A menu row's title, subtitle and icon.
            Text("Sleep Timer")
            Text(status)
            Image(systemName: "timer")
        }
        Menu {
            Picker("Playback Speed", selection: Binding(
                get: { player.playbackSpeed },
                set: { player.changeSpeed($0) }
            )) {
                ForEach(PlayerModel.speedChoices, id: \.self) { speed in
                    Text(Self.speedLabel(speed)).tag(speed)
                }
            }
            .pickerStyle(.inline)
            Section {
                Toggle(isOn: Binding(
                    get: { player.preservesPitch },
                    set: { player.setPreservesPitch($0) }
                )) {
                    Text("Preserve pitch")
                    Text("Keep original pitch when changing speed")
                }
                .accessibilityIdentifier("nowPlayingPreservePitch")
            }
        } label: {
            // The speed shows under the title only when it isn't normal (D87).
            Text("Playback Speed")
            if player.playbackSpeed != 1 { Text(Self.speedLabel(player.playbackSpeed)) }
            Image(systemName: "gauge.with.dots.needle.67percent")
        }
        .accessibilityIdentifier("nowPlayingSpeed")
        if let song = player.currentSong {
            Section {
                SongInfoItem(song: player.latest(song))
            }
        }
    }

    /// "0.75×", "1×", "1.5×": Apple's sign, no trailing zeros (Flutter's "1.00x").
    static func speedLabel(_ speed: Double) -> String {
        speed.formatted(.number.precision(.fractionLength(0...2))) + "×"
    }
}

/// Flutter `AddToMenu`'s rows. Its "Add to Library" isn't here (D41): everything is already on the
/// server, so all it did was say so.
struct AddToItems: View {
    let song: Song

    @Environment(PlayerModel.self) private var player
    @Environment(SongSheets.self) private var sheets
    @Environment(ToastCenter.self) private var toasts

    var body: some View {
        let song = player.latest(song)
        Button("Add to Playlist", systemImage: "text.badge.plus") {
            sheets.playlistRequest = PlaylistRequest(song: song, title: "Select Playlist")
        }
        Button(
            song.starred ? "Remove from Favorites" : "Add to Favorites",
            systemImage: song.starred ? "heart.fill" : "heart"
        ) {
            Task {
                // Flutter's messages, and its silence on failure.
                if (try? await player.toggleFavorite(for: song)) != nil {
                    toasts.show(song.starred ? "Remove from Favorites" : "Add to Favorites")
                }
            }
        }
    }
}

// MARK: - What the menus open

struct PlaylistRequest: Identifiable {
    let id = UUID()
    let song: Song
    let title: String
}

/// Every song of an album or a playlist, for the playlist the user picks next (C48).
struct BatchRequest: Identifiable {
    let id = UUID()
    let source: BatchSource
}

/// What the menus open once they've closed. It lives above the rows, one for the tabs and one for
/// now playing, since a menu's own content can't present anything.
@Observable
final class SongSheets {
    var playlistRequest: PlaylistRequest?
    /// "Add all to playlist" on an album or a playlist (C48).
    var batchRequest: BatchRequest?
    /// The song menu's Downloaded row asks first.
    var removingDownload: Song?
    /// Song Info's sheet (C35).
    var infoSong: Song?
    fileprivate var duplicate: Duplicate?

    fileprivate struct Duplicate {
        let song: Song
        let playlist: Playlist
    }
}

extension View {
    func songSheets(_ sheets: SongSheets) -> some View {
        modifier(SongSheetsModifier(sheets: sheets))
    }
}

private struct SongSheetsModifier: ViewModifier {
    let sheets: SongSheets

    @Environment(AccountModel.self) private var account
    @Environment(ToastCenter.self) private var toasts
    @Environment(LibraryModel.self) private var library
    @Environment(DownloadModel.self) private var downloads

    func body(content: Content) -> some View {
        @Bindable var sheets = sheets
        content
            .environment(sheets)
            .sheet(item: $sheets.playlistRequest) { request in
                PlaylistChooser(title: request.title) { playlist in
                    sheets.playlistRequest = nil
                    Task { await choose(playlist, for: request.song) }
                }
            }
            .sheet(item: $sheets.batchRequest) { request in
                PlaylistChooser(title: "Add to Playlist") { playlist in
                    sheets.batchRequest = nil
                    Task { await addAll(request.source, to: playlist) }
                }
            }
            .sheet(item: $sheets.infoSong) { song in
                SongInfoView(song: song)
            }
            .alert(
                "Already in playlist",
                isPresented: Binding(get: { sheets.duplicate != nil }, set: { if !$0 { sheets.duplicate = nil } }),
                presenting: sheets.duplicate
            ) { duplicate in
                Button("Cancel", role: .cancel) {}
                Button("Add anyway") { Task { await add(duplicate.song, to: duplicate.playlist) } }
            } message: { duplicate in
                Text("\"\(duplicate.song.title)\" is already in \"\(duplicate.playlist.name)\". Do you still want to add it?")
            }
            .alert(
                "Remove Download",
                isPresented: Binding(get: { sheets.removingDownload != nil }, set: { if !$0 { sheets.removingDownload = nil } }),
                presenting: sheets.removingDownload
            ) { song in
                Button("Cancel", role: .cancel) {}
                Button("Remove", role: .destructive) {
                    downloads.removeSong(song.id)
                    toasts.show("Download removed")
                }
            } message: { _ in
                Text("Remove this song from offline storage?")
            }
    }

    /// Flutter's order: closes the sheet, checks for a duplicate, and adds. If the check fails, it
    /// adds anyway.
    private func choose(_ playlist: Playlist, for song: Song) async {
        let existing = (try? await account.client?.playlist(id: playlist.id))?.songs ?? []
        if PlaylistMembership.contains(song, in: existing) {
            sheets.duplicate = SongSheets.Duplicate(song: song, playlist: playlist)
        } else {
            await add(song, to: playlist)
        }
    }

    /// "Add all to playlist": one request, the songs already there skipped and counted in the message.
    private func addAll(_ source: BatchSource, to playlist: Playlist) async {
        do {
            guard let client = account.client else { throw SubsonicError.network }
            let result = try await BatchActions.addAll(source, to: playlist, client: client)
            if result.added > 0 { await library.refreshPlaylists() }
            toasts.show(result.message(playlist: playlist.name), checkmark: result.added > 0)
        } catch {
            toasts.show("Error adding to playlist: \(error.localizedDescription)")
        }
    }

    private func add(_ song: Song, to playlist: Playlist) async {
        do {
            guard let client = account.client else { throw SubsonicError.network }
            try await client.addToPlaylist(id: playlist.id, songIDs: [song.id])
            await library.refreshPlaylists()
            toasts.show("Added \"\(song.title)\" to \(playlist.name)", checkmark: true)
        } catch {
            toasts.show("Error adding to playlist: \(error.localizedDescription)")
        }
    }
}

/// Flutter's two playlist sheets as one: the server's list, each with its cover and song count.
/// It stays a sheet (D30, the user's choice), since a playlist list can be long.
private struct PlaylistChooser: View {
    let title: String
    let onChoose: (Playlist) -> Void

    @Environment(AccountModel.self) private var account
    @Environment(ToastCenter.self) private var toasts
    @State private var playlists: [Playlist]?

    var body: some View {
        VStack(spacing: 16) {
            Text(title)
                .font(.system(size: 18, weight: .bold))
                .padding(.top, 24)
            if let playlists, !playlists.isEmpty {
                List(playlists) { playlist in
                    Button { onChoose(playlist) } label: { row(playlist) }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.clear)
                        .accessibilityIdentifier("playlistChooserRow")
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            } else if playlists == nil {
                ProgressView().padding(32)
                Spacer(minLength: 0)
            } else {
                Text("No playlists available").padding(32)
                Spacer(minLength: 0)
            }
        }
        .presentationDetents([.fraction(0.7)])
        .presentationDragIndicator(.visible)
        .task { await load() }
    }

    private func row(_ playlist: Playlist) -> some View {
        HStack(spacing: 16) {
            Group {
                if playlist.coverArt != nil {
                    AlbumArtwork(coverArt: playlist.coverArt, size: 48, cornerRadius: 4)
                } else {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.gray.opacity(0.2))
                        .frame(width: 48, height: 48)
                        .overlay { Image(systemName: "music.note.list").foregroundStyle(.gray) }
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.name).font(.system(size: 16)).lineLimit(1)
                Text(PlaylistMembership.countText(playlist.songCount))
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.secondaryText)
            }
            Spacer(minLength: 0)
        }
        .contentShape(.rect)
    }

    private func load() async {
        do {
            guard let client = account.client else { throw SubsonicError.network }
            playlists = try await client.playlists()
        } catch is CancellationError {
        } catch {
            playlists = []
            toasts.show("Error loading playlists: \(error.localizedDescription)")
        }
    }
}
