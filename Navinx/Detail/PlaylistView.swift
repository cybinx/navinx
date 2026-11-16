import PlaybackKit
import SubsonicKit
import SwiftUI

/// Flutter `PlaylistScreen`: the page, its filter, its two editing modes and its Download button.
struct PlaylistView: View {
    let seed: Playlist

    private enum Mode { case normal, selecting, reordering }

    @Environment(AccountModel.self) private var account
    @Environment(ToastCenter.self) private var toasts
    @Environment(PlayerModel.self) private var player
    @Environment(LibraryModel.self) private var library
    @Environment(PinnedPlaylistsModel.self) private var favorites
    @Environment(PlaylistSheets.self) private var sheets
    @Environment(DownloadModel.self) private var downloads
    @Environment(\.dismiss) private var dismiss
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var playlist: Playlist?
    @State private var isLoading = true
    /// The first load failed for a reason other than the playlist being gone, and nothing earlier
    /// can stand in for it.
    @State private var loadFailed = false
    /// The songs shown came from the server on this visit. Removing and reordering go by place in the
    /// list, so they wait for it: against a copy saved earlier they could change the wrong song.
    @State private var isFromServer = false
    /// The server didn't answer the first load, so the page shows a copy saved earlier.
    @State private var showsSavedCopy = false
    /// Navidrome lets an administrator change any playlist; asked only for one that isn't the account's own.
    @State private var isAdmin = false
    @State private var showsFilter = false
    @State private var query = ""
    @State private var mode = Mode.normal
    @State private var selected: Set<Int> = []
    @State private var showsRemoveConfirmation = false
    /// The last write. Each waits for the one before, as they go by place in the list.
    @State private var lastWrite: Task<Void, Never>?
    /// Counts the failed writes: one made before a failure is dropped, as its place in the list was
    /// worked out against a list the server never got.
    @State private var failures = 0
    /// The writes not yet finished, the one being made among them.
    @State private var queued = 0
    /// A load came while writes were queued or on their way: it loads again once they're done, as an
    /// answer from before them would put back songs they removed and shift the places the next go by.
    @State private var reloadsAfterWrites = false
    /// The failures whose toast already says the writes behind them were dropped.
    @State private var announcedDrop = -1
    @State private var failureText = ""

    /// Another user's public playlist can be played and queued but not changed: the server would refuse.
    private var canEdit: Bool {
        DetailLogic.canEdit(playlist ?? seed, username: account.active?.username, isAdmin: isAdmin)
    }

    /// Removing and reordering songs: only on the server's own list.
    private var canEditSongs: Bool { canEdit && isFromServer }

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .navigationTitle(seed.name)
            } else if let playlist {
                if mode == .reordering {
                    reorderPage(playlist)
                } else {
                    page(playlist)
                }
            } else if loadFailed {
                DetailMessage(icon: "exclamationmark.circle", text: "Error loading playlist") {
                    Task {
                        isLoading = true
                        await load()
                    }
                }
                .navigationTitle(seed.name)
            } else {
                Text("Playlist not found").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Palette.background)
        .toolbarTitleDisplayMode(mode == .reordering ? .inlineLarge : .inline)
        .navigationBarBackButtonHidden(mode == .reordering)
        // Again when the server comes back or goes (offline mode, or no connection on opening).
        .task(id: account.client != nil) { await load() }
        .task(id: account.active) {
            if !DetailLogic.canEdit(seed, username: account.active?.username, isAdmin: false) { isAdmin = await account.isAdmin() }
        }
        .alert("Remove songs", isPresented: $showsRemoveConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) { removeSelected() }
        } message: {
            Text("Remove \(selected.count) song(s) from \"\(playlist?.name ?? "")\"?")
        }
    }

    /// With no server, the copy saved with its download, else as it was last opened (Flutter: the
    /// saved copy, with songs only if it was opened before). A load that fails shows the copy last
    /// opened, or the one the page was opened with if it has its songs, else an error with Retry; a
    /// playlist the server says is gone shows "Playlist not found".
    private func load() async {
        // Not while writes are queued or on their way: once they're done (`write`).
        guard queued == 0 else {
            reloadsAfterWrites = true
            isLoading = false
            return
        }
        if let client = account.client {
            do {
                let fresh = try await client.playlist(id: seed.id)
                // A write made while this was on its way: this answer may be older than it.
                guard queued == 0 else {
                    reloadsAfterWrites = true
                    isLoading = false
                    return
                }
                playlist = fresh
                isFromServer = true
                showsSavedCopy = false
                library.remember(fresh)
                downloads.refresh(collectionID: fresh.id, songs: fresh.songs ?? [])
                loadFailed = false
            } catch where playlist == nil && !DetailLogic.isMissing(error) {
                playlist = library.openedPlaylists[seed.id] ?? (seed.songs != nil ? seed : nil)
                showsSavedCopy = playlist != nil
                loadFailed = playlist == nil
            } catch {
                // A reload that fails keeps the playlist already shown; one that is gone has none.
            }
        } else {
            playlist = downloads.playlist(id: seed.id) ?? library.openedPlaylists[seed.id] ?? seed
            isFromServer = false
            showsSavedCopy = false
        }
        isLoading = false
    }

    private func page(_ playlist: Playlist) -> some View {
        let songs = playlist.songs ?? []
        return GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 0) {
                    let side: CGFloat = geometry.size.width < 380 ? 190 : 240
                    PlaylistArtwork(playlist: playlist, size: side, cornerRadius: 14, prominentShadow: true)
                        .overlay(alignment: .bottomTrailing) {
                            if downloads.allDownloaded(songs) { DownloadedCoverBadge(style: .playlist) }
                        }
                        .collapsingHeaderArt()
                        .padding(.top, 12)
                        .padding(.bottom, 16)
                    header(playlist, songs: songs)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 24)
                    // Offline mode has its banner; this is a first load that failed.
                    if showsSavedCopy {
                        Text("Couldn't load from your server. Showing the copy last opened.")
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.secondaryText)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 12)
                    }
                    Divider()
                    if songs.isEmpty {
                        Text("No songs in this playlist")
                            .font(.system(size: 15))
                            .foregroundStyle(Palette.secondaryText)
                            .padding(.top, 40)
                    } else if mode == .selecting {
                        selectionRows(songs)
                    } else {
                        songRows(songs)
                    }
                }
            }
        }
        .toolbar { toolbar(playlist, songs: songs) }
    }

    private func header(_ playlist: Playlist, songs: [Song]) -> some View {
        VStack(spacing: 4) {
            Text(playlist.name)
                .font(.system(size: 20, weight: .semibold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
            Text("\(CountText.songs(songs.count)) • \(playlist.formattedDuration)")
                .font(.system(size: 13))
                .foregroundStyle(Palette.secondaryText)
                .lineLimit(1)
            PlayShuffleRow(songs: songs)
                .padding(.top, 16)
            if showsFilter, mode != .reordering {
                SongFilterField(placeholder: "Filter songs...", text: $query)
                    .padding(.top, 12)
            }
        }
    }

    // MARK: The rows

    /// Flutter's `Dismissible` rows: a swipe left removes the song straight away, with no question.
    private func songRows(_ songs: [Song]) -> some View {
        let indexes = DetailLogic.filteredIndexes(songs, query: query)
        let shown = indexes.map { songs[$0] }
        let ids = PlaylistEditing.rowIDs(songs)
        return LazyVStack(spacing: 0) {
            ForEach(Array(indexes.enumerated()), id: \.element) { position, index in
                let row = SongRow(song: songs[index], list: shown, index: position)
                if canEditSongs {
                    row.modifier(SwipeToRemove(systemImage: "trash") { remove(at: index) })
                        .id(ids[index])
                } else {
                    row.id(ids[index])
                }
            }
        }
    }

    /// Flutter's `CheckboxListTile`s. As there, the filter doesn't apply in this mode, and the ✓ rows
    /// are removed together while a row's own trash removes just that one.
    private func selectionRows(_ songs: [Song]) -> some View {
        let ids = PlaylistEditing.rowIDs(songs)
        return LazyVStack(spacing: 0) {
            ForEach(Array(ids.enumerated()), id: \.element) { index, _ in
                selectionRow(songs[index], index: index)
            }
        }
    }

    private func selectionRow(_ song: Song, index: Int) -> some View {
        let isSelected = selected.contains(index)
        return HStack(spacing: 16) {
            Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                .font(.system(size: 20))
                .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            SongLines(song: song)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Remove from Playlist", systemImage: "trash") {
                selected = PlaylistEditing.selection(selected, afterRemoving: index)
                remove(at: index)
            }
            .labelStyle(.iconOnly)
            .font(.system(size: 18))
            .foregroundStyle(.red)
            .buttonStyle(.plain)
            .frame(width: 44, height: 44)
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .frame(minHeight: 72)
        .contentShape(.rect)
        .onTapGesture {
            if isSelected { selected.remove(index) } else { selected.insert(index) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("playlistSelectRow")
    }

    // MARK: Reordering

    /// Flutter's reorder page: the header stays while the songs move under it. In landscape there's
    /// no room for both, so the songs get the screen.
    private func reorderPage(_ playlist: Playlist) -> some View {
        let songs = playlist.songs ?? []
        return VStack(spacing: 0) {
            if verticalSizeClass != .compact {
                VStack(spacing: 16) {
                    PlaylistArtwork(playlist: playlist, size: 150, cornerRadius: 12)
                    header(playlist, songs: songs)
                }
                .padding(16)
                Divider()
            }
            PlaylistReorderList(songs: songs, onMove: saveOrder)
        }
        .navigationTitle("Reorder songs")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Close", systemImage: "xmark") { mode = .normal }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done reordering", systemImage: "checkmark") { mode = .normal }
            }
        }
    }

    // MARK: The toolbar

    /// Flutter's capsule of glyphs, but for one. As separate items, six don't fit beside the back button
    /// and iOS hides the last two in its own ⋯; a trailing item is squeezed to one button's size; and
    /// the principal item, which keeps its own size, takes no touches beyond its centred slot. So five
    /// are the principal item with their own glass, and Download is the trailing item, at the edge.
    @ToolbarContentBuilder
    private func toolbar(_ playlist: Playlist, songs: [Song]) -> some ToolbarContent {
        if mode == .selecting {
            ToolbarItemGroup(placement: .topBarTrailing) {
                let allSelected = selected.count == songs.count
                Button(allSelected ? "Deselect all" : "Select all", systemImage: allSelected ? "checkmark.square" : "square") {
                    selected = allSelected ? [] : Set(songs.indices)
                }
                Button("Remove selected", systemImage: "trash") { showsRemoveConfirmation = true }
                    .tint(selected.isEmpty ? nil : .red)
                    .disabled(selected.isEmpty)
                // Not in Flutter, whose only ways out are leaving the page or removing songs (D50).
                Button("Done selecting", systemImage: "checkmark") {
                    selected = []
                    mode = .normal
                }
            }
        } else {
            ToolbarItem(placement: .principal) {
                ToolbarCapsule {
                    pageButtons(playlist, songs: songs)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .sharedBackgroundVisibility(.hidden)
            if account.client != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    CollectionDownloadButton(target: .playlist(playlist))
                }
            }
        }
    }

    @ViewBuilder
    private func pageButtons(_ playlist: Playlist, songs: [Song]) -> some View {
        let isFavorite = favorites.isFavorite(playlist.id)
        CapsuleButton(title: "Search in playlist", icon: showsFilter ? "magnifyingglass.circle.fill" : "magnifyingglass") {
            showsFilter.toggle()
            if !showsFilter { query = "" }
        }
        Menu {
            Button("Add all to queue", systemImage: "text.badge.plus") {
                player.queueUpAll(songs, toasts: toasts)
            }
            BatchItems(source: .playlist(playlist))
            if canEdit {
                Button("Rename Playlist", systemImage: "pencil") {
                    sheets.renaming = PlaylistEdit(playlist: playlist) { name in
                        self.playlist?.name = name
                    }
                }
                Button("Delete Playlist", systemImage: "trash", role: .destructive) {
                    sheets.deleting = PlaylistEdit(playlist: playlist) { _ in dismiss() }
                }
            }
        } label: {
            CapsuleGlyph(title: "More options", icon: "ellipsis")
        }
        .buttonStyle(.plain)
        CapsuleButton(
            title: isFavorite ? "Remove from Favorites" : "Add to Favorites",
            icon: isFavorite ? "heart.fill" : "heart",
            color: isFavorite ? .red : .primary
        ) {
            favorites.toggle(playlist.id)
            toasts.show(favorites.isFavorite(playlist.id) ? "Added to favorites" : "Removed from favorites")
        }
        if canEditSongs {
            CapsuleButton(title: "Reorder songs", icon: "arrow.up.arrow.down", color: songs.count <= 1 ? .secondary : .primary) {
                mode = .reordering
            }
            .disabled(songs.count <= 1)
            CapsuleButton(title: "Select songs", icon: "checkmark.circle") {
                selected = []
                mode = .selecting
            }
        }
    }

    // MARK: Writing to the server

    private func remove(at index: Int) {
        guard let playlist, isFromServer else { return }
        let songs = PlaylistEditing.removing([index], from: playlist.songs ?? [])
        withAnimation { self.playlist = PlaylistEditing.updated(playlist, songs: songs) }
        write(before: playlist, success: "Song removed from playlist", failure: "Error removing song") { client in
            try await client.updatePlaylist(id: playlist.id, songIndexesToRemove: [index])
        }
    }

    private func removeSelected() {
        guard let playlist, isFromServer else { return }
        let indexes = selected
        let songs = PlaylistEditing.removing(indexes, from: playlist.songs ?? [])
        self.playlist = PlaylistEditing.updated(playlist, songs: songs)
        selected = []
        mode = .normal
        write(before: playlist, success: "Removed \(indexes.count) song(s) from playlist", failure: "Error removing song") { client in
            try await client.updatePlaylist(id: playlist.id, songIndexesToRemove: indexes.sorted(by: >))
        }
    }

    /// The whole order, after each drop (D46). Flutter's remove and add-at-the-end puts the song last.
    private func saveOrder(_ songs: [Song]) {
        guard let playlist, isFromServer else { return }
        self.playlist = PlaylistEditing.updated(playlist, songs: songs)
        let ids = songs.map(\.id)
        write(before: playlist, success: nil, failure: "Error reordering song") { client in
            try await client.setPlaylistSongs(id: playlist.id, songIDs: ids)
        }
    }

    /// The change shows at once. On failure the message shows and the page goes back to the server's
    /// list, or to `before` (the page as it was) when the server can't be reached. The writes queued
    /// behind a failed one are dropped.
    private func write(
        before: Playlist,
        success: String?,
        failure: String,
        _ operation: @escaping (SubsonicClient) async throws -> Void
    ) {
        let previous = lastWrite
        let id = seed.id
        let generation = failures
        queued += 1
        lastWrite = Task {
            await previous?.value
            await send(generation: generation, id: id, before: before, success: success, failure: failure, operation)
            queued -= 1
            // A load held back while the writes went: now, from what the server has after them.
            if queued == 0, reloadsAfterWrites {
                reloadsAfterWrites = false
                await load()
            }
        }
    }

    private func send(
        generation: Int,
        id: String,
        before: Playlist,
        success: String?,
        failure: String,
        _ operation: @escaping (SubsonicClient) async throws -> Void
    ) async {
        guard generation == failures else {
            // Dropped. Said once, unless the failure's own message already did.
            if announcedDrop != generation {
                announcedDrop = generation
                toasts.show("\(failureText)\nYour other changes to this playlist were not saved.")
            }
            return
        }
        do {
            guard let client = account.client else { throw SubsonicError.network }
            try await operation(client)
            if let success { toasts.show(success) }
            // The Library's song counts, and Home's rows.
            await library.refreshPlaylists()
        } catch {
            failureText = "\(failure): \(error.localizedDescription)"
            // The writes behind this one are dropped below; the one message says so.
            if queued > 1 {
                announcedDrop = generation
                toasts.show("\(failureText)\nYour other changes to this playlist were not saved.")
            } else {
                toasts.show(failureText)
            }
            playlist = (try? await account.client?.playlist(id: id)) ?? before
            // After the restore, so a write made meanwhile is dropped too.
            failures += 1
        }
    }
}

/// The page's toolbar: glyphs side by side on one glass capsule, the height of the back button.
private struct ToolbarCapsule<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 0) { content }
            .padding(.horizontal, 4)
            .appGlass(in: .capsule)
    }
}

private struct CapsuleGlyph: View {
    static let width: CGFloat = 42

    let title: String
    let icon: String
    var color: Color = .primary

    var body: some View {
        Label(title, systemImage: icon)
            .labelStyle(.iconOnly)
            .font(.system(size: 17))
            .foregroundStyle(color)
            .frame(width: Self.width, height: 44)
            .contentShape(.rect)
    }
}

private struct CapsuleButton: View {
    let title: String
    let icon: String
    var color: Color = .primary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            CapsuleGlyph(title: title, icon: icon, color: color)
        }
        .buttonStyle(.plain)
    }
}

/// A song's title and artist, for the rows that have no cover: Flutter's plain `ListTile` text.
private struct SongLines: View {
    let song: Song

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(song.title)
                .font(.system(size: 16))
                .lineLimit(1)
            Text(song.artist ?? "")
                .font(.system(size: 14))
                .lineLimit(1)
        }
    }
}

/// The reorder page's rows, a `List` in edit mode for the system's handles. Each row has its own ID,
/// as a playlist can hold a song twice.
private struct PlaylistReorderList: View {
    private struct Entry: Identifiable {
        let id = UUID()
        let song: Song
    }

    let songs: [Song]
    let onMove: ([Song]) -> Void
    @State private var entries: [Entry]

    init(songs: [Song], onMove: @escaping ([Song]) -> Void) {
        self.songs = songs
        self.onMove = onMove
        _entries = State(initialValue: songs.map { Entry(song: $0) })
    }

    var body: some View {
        List {
            ForEach(entries) { entry in
                SongLines(song: entry.song)
                    .frame(minHeight: 72)
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 8))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("playlistReorderRow")
            }
            .onMove { from, to in
                entries.move(fromOffsets: from, toOffset: to)
                onMove(entries.map(\.song))
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.editMode, .constant(.active))
        .accessibilityIdentifier("playlistReorderList")
        // A failed reorder puts the old order back; a drop's own save leaves the same IDs.
        .onChange(of: songs.map(\.id)) { _, ids in
            if ids != entries.map(\.song.id) { entries = songs.map { Entry(song: $0) } }
        }
    }
}
