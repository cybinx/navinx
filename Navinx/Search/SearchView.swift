import PlaybackKit
import SubsonicKit
import SwiftUI

/// The Search tab: Flutter `SearchScreen`, with system glass for its field, chips and top result,
/// and the server's own section under the results for an account that has it (C27).
struct SearchView: View {
    @Environment(LibraryModel.self) private var library
    @Environment(AccountModel.self) private var account
    @Environment(PlayerModel.self) private var player
    @Environment(DownloadModel.self) private var downloads
    @Environment(HubModel.self) private var hub
    @Environment(ToastCenter.self) private var toasts
    @Environment(AppNavigator.self) private var navigator

    /// Kept by `MainTabView`, so now playing can open a page here.
    @Binding var path: [LibraryRoute]
    @State private var query = ""
    @State private var result: SearchResult?
    /// The words `result` was found for; the field may have moved on while the next search waits.
    @State private var resultQuery = ""
    /// `result` came from the downloads, with no server.
    @State private var resultWasOffline = false
    @State private var isSearching = false
    /// The words whose search failed: the page says so, with a Retry, until the words change.
    @State private var failedQuery: String?
    @State private var filter: SearchFilter = .all
    @State private var recents = RecentSearches()
    /// Navidrome only lets an administrator scan, so the button is theirs alone (C30, D122).
    @State private var isAdmin = false
    @State private var isScanning = false

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var hasResults: Bool { result != nil && !trimmedQuery.isEmpty }

    var body: some View {
        NavigationStack(path: $path) {
            // Every state below is as wide as the page: a vertical scroll view is only as wide as what it
            // holds, and a narrower one painted its background as a band down the middle of the stack's own
            // white (light mode; both are black in dark).
            ScrollView {
                if hasResults { filterChips }
                if isSearching {
                    ProgressView()
                        .controlSize(.large)
                        .padding(.vertical, 48)
                        .frame(maxWidth: .infinity)
                } else if let failedQuery, failedQuery == trimmedQuery {
                    DetailMessage(icon: "exclamationmark.circle", text: "Error searching") {
                        Task { await performSearch(failedQuery) }
                    }
                    .padding(.top, 80)
                } else if let result, hasResults {
                    results(result)
                } else {
                    idle
                }
            }
            .keepsBottomRoom()
            .background(Palette.background)
            .navigationTitle("Search")
            .toolbarTitleDisplayMode(.inlineLarge)
            .searchable(
                text: $query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "What do you want to play?"
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            // Words are kept for "Recent Searches" when they are submitted or a result is opened,
            // not after every pause in typing, which filled the list with prefixes.
            .onSubmit(of: .search) {
                recents.add(trimmedQuery)
                if let failedQuery, failedQuery == trimmedQuery { Task { await performSearch(failedQuery) } }
            }
            .navigationDestination(for: LibraryRoute.self) { RouteDestination(route: $0, path: $path) }
        }
        .environment(\.openLibraryRoute) { path.append($0) }
        // Online and offline search different places: the connection coming back searches the server again.
        .task(id: SearchKey(query: trimmedQuery, hasServer: account.client != nil)) { await searchAfterPause() }
        // Siri's or a link's text (C39): searched as if typed, and kept as a recent search.
        .onChange(of: navigator.searchText, initial: true) {
            guard let text = navigator.searchText else { return }
            navigator.searchText = nil
            query = text
            recents.add(text)
        }
        .task(id: account.active) { isAdmin = await account.isAdmin() }
        // The server's section, kept by the hub's model so the library search's spinner doesn't restart it.
        // Again when the server's tab appears, for words typed before its first check had finished.
        .task(id: HubSearchKey(query: trimmedQuery, isShown: hub.isShown)) { await hub.searchAfterPause(trimmedQuery) }
    }

    // MARK: Searching

    /// Flutter `_onSearchChanged`: 250 ms after the last keystroke. Typing on cancels this one.
    private func searchAfterPause() async {
        let query = trimmedQuery
        guard !query.isEmpty else {
            result = nil
            failedQuery = nil
            isSearching = false
            return
        }
        // Coming back to the tab: the results on screen are already these words' (from the server,
        // or from the downloads when offline), so they stay without a new search.
        if result != nil, resultQuery == query, resultWasOffline == (account.client == nil) {
            isSearching = false
            return
        }
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        await performSearch(query)
    }

    /// One search for `query`; also the Retry. A search the field has moved on from is dropped.
    private func performSearch(_ query: String) async {
        failedQuery = nil
        guard let client = account.client else {
            // Offline: the downloaded songs (Flutter `_searchLocal`; Flutter's offline search failed silently).
            result = SearchResult(songs: OfflineLogic.search(downloads.offlineSongs, query: query))
            resultQuery = query
            resultWasOffline = true
            isSearching = false
            return
        }
        isSearching = true
        do {
            let found = try await client.search(query)
            guard !Task.isCancelled, query == trimmedQuery else { return }
            result = found
            resultQuery = query
            resultWasOffline = false
            isSearching = false
        } catch {
            guard !Task.isCancelled, query == trimmedQuery else { return }
            // Flutter shows no error here, but then the old results or the empty page stay under the words.
            result = nil
            failedQuery = query
            isSearching = false
        }
    }

    /// The words behind the results on screen go to "Recent Searches" when one of them is opened.
    private func saveRecent() {
        if hasResults { recents.add(resultQuery) }
    }

    private func open(_ route: LibraryRoute) {
        saveRecent()
        path.append(route)
    }

    // MARK: Chips

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(SearchFilter.allCases, id: \.self) { chip in
                        chipButton(chip)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .scrollClipDisabled()
        .frame(height: 44)
    }

    private func chipButton(_ chip: SearchFilter) -> some View {
        let button = Button { filter = chip } label: {
            Text(chip.title).font(.system(size: 13, weight: .semibold))
        }
        return button.filterChipStyle(selected: filter == chip)
    }

    // MARK: Nothing searched

    /// The recent searches, or with none a prompt (D210: "Browse all" and its tiles are gone).
    @ViewBuilder
    private var idle: some View {
        switch SearchIdleState(hasRecents: !recents.queries.isEmpty, searchesServer: account.client != nil) {
        case .recents:
            recentSearches
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 48)
        case .prompt(let detail):
            SearchMessage(title: SearchIdleState.promptTitle, detail: detail)
                .padding(.horizontal, 16)
                .padding(.vertical, 64)
                .frame(maxWidth: .infinity)
        }
    }

    private var recentSearches: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Recent Searches").font(.system(size: 16, weight: .bold))
                Spacer()
                Button("Clear") { recents.clear() }
                    .font(.system(size: 13))
                    .foregroundStyle(.gray)
                    .buttonStyle(.plain)
            }
            FlowLayout(spacing: 8, runSpacing: 8) {
                ForEach(recents.queries, id: \.self) { recent in
                    HStack(spacing: 8) {
                        Button(recent) {
                            recents.add(recent)
                            runSearch(recent)
                        }
                            .font(.system(size: 14))
                            .buttonStyle(.plain)
                        Button("Remove \(recent)", systemImage: "xmark") { recents.remove(recent) }
                            .labelStyle(.iconOnly)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .appGlass(in: .capsule)
                }
            }
        }
        .padding(.bottom, 24)
    }

    /// A recent search: the query goes in the field, and the field's change searches.
    private func runSearch(_ text: String) {
        // The same word again wouldn't change the field, so nothing would end the spinner; after a
        // failed search it is the retry.
        guard text != trimmedQuery else {
            if let failedQuery, failedQuery == text { Task { await performSearch(text) } }
            return
        }
        isSearching = true
        query = text
    }

    // MARK: Scanning

    private var scanButton: some View {
        Button {
            Task { await scanThenSearch() }
        } label: {
            HStack(spacing: 8) {
                if isScanning { ProgressView() }
                Text(isScanning ? "Scanning..." : "Scan Library")
                    .font(.system(size: 14, weight: .semibold))
            }
            .padding(.horizontal, 18)
            .frame(height: 40)
        }
        .buttonStyle(.glass)
        .disabled(isScanning)
        .padding(.top, 16)
        .accessibilityIdentifier("searchScanLibrary")
    }

    /// Scans the server's library, waits for it, then searches again for the same words.
    private func scanThenSearch() async {
        guard let client = account.client, !isScanning else { return }
        isScanning = true
        defer { isScanning = false }
        do {
            let finished = try await client.scanAndWait()
            guard finished else {
                toasts.show("The scan is still running. Search again in a moment.")
                return
            }
            let found = try await client.search(trimmedQuery)
            result = found
            resultQuery = trimmedQuery
            failedQuery = nil
        } catch is CancellationError {
        } catch {
            toasts.show("Couldn't scan the library")
        }
    }

    // MARK: Results

    @ViewBuilder
    private func results(_ result: SearchResult) -> some View {
        let sections = SearchSections(result: result, playlists: library.playlists, query: query, filter: filter)
        if sections.showsNothing {
            VStack(spacing: 0) {
                SearchMessage(title: "No results found for \"\(resultQuery)\"", detail: "Please check your spelling or try another query.")
                // Only when nothing matched under any filter; a filter with no matches isn't a missing song.
                if isAdmin, !account.isOffline, sections.isEmpty { scanButton }
                HubSearchSection(top: 24)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 64)
            .frame(maxWidth: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                if let top = sections.topResult {
                    sectionTitle("Top result").padding(.bottom, 12)
                    topCard(top, songs: sections.songs)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 24)
                }
                if !sections.songs.isEmpty {
                    sectionTitle("Songs").padding(.bottom, 10)
                    ForEach(sections.songs) { song in
                        SongRow(song: song) { play(song, among: sections.songs) }
                            .padding(.horizontal, 16)
                    }
                    .padding(.bottom, 0)
                    Color.clear.frame(height: 24)
                }
                if !sections.artists.isEmpty {
                    HorizontalSection(title: "Artists", posterSide: 140) {
                        ForEach(sections.artists) { artist in
                            CoverCard(
                                title: artist.name,
                                subtitle: "Artist",
                                coverArt: artist.artworkReference,
                                size: 140,
                                isRound: true,
                                onTap: { open(.artist(artist)) }
                            )
                        }
                    }
                    .padding(.bottom, 24)
                }
                if !sections.albums.isEmpty {
                    HorizontalSection(title: "Albums", posterSide: 150) {
                        ForEach(sections.albums) { album in
                            CoverCard(
                                title: album.name,
                                subtitle: album.artist,
                                coverArt: album.coverArt,
                                size: 150,
                                onTap: { open(.album(album)) }
                            )
                        }
                    }
                    .padding(.bottom, 24)
                }
                if !sections.playlists.isEmpty {
                    HorizontalSection(title: "Playlists", posterSide: 150) {
                        ForEach(sections.playlists) { playlist in
                            // "Playlist • Musly" in Flutter (D35).
                            CoverCard(title: playlist.name, subtitle: "Playlist • Navinx", size: 150, onTap: { open(.playlist(playlist)) }) {
                                PlaylistArtwork(playlist: playlist, size: 120, cornerRadius: 4)
                            }
                        }
                    }
                }
                // Under every filter, as Flutter.
                HubSearchSection()
                    .padding(.horizontal, 16)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 16)
            .padding(.bottom, 48)
        }
    }

    /// Online, the song and radio after it (Flutter); offline there's no radio, so the found songs.
    private func play(_ song: Song, among songs: [Song]) {
        saveRecent()
        if account.isOffline {
            player.playSong(song, playlist: songs)
        } else {
            player.playAsStation(song)
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 18, weight: .bold))
            .padding(.horizontal, 16)
    }

    @ViewBuilder
    private func topCard(_ top: SearchSections.TopResult, songs: [Song]) -> some View {
        switch top {
        case .artist(let artist):
            // Flutter's play button opens the artist too.
            BestMatchCard(
                title: artist.name,
                subtitle: "Artist",
                typeLabel: "Artist",
                coverArt: artist.artworkReference,
                isArtist: true,
                onTap: { open(.artist(artist)) },
                onPlay: { open(.artist(artist)) }
            )
        case .song(let song):
            BestMatchCard(
                title: song.title,
                subtitle: song.artist ?? "Unknown Artist",
                typeLabel: "Song",
                coverArt: song.coverArt,
                onTap: { play(song, among: songs) },
                onPlay: { play(song, among: songs) }
            )
        case .album(let album):
            BestMatchCard(
                title: album.name,
                subtitle: "Album • \(album.artist ?? "Unknown Artist")",
                typeLabel: "Album",
                coverArt: album.coverArt,
                onTap: { open(.album(album)) },
                onPlay: { open(.album(album)) }
            )
        }
    }
}

/// What the library search runs for: the words, and whether they go to the server or the downloads.
private struct SearchKey: Hashable {
    let query: String
    let hasServer: Bool
}

/// What the server's section is asked for: the words, and whether the server's tab is there.
private struct HubSearchKey: Hashable {
    let query: String
    let isShown: Bool
}

/// Search's own message under the magnifying glass: the prompt on an empty field, and "No results found".
private struct SearchMessage: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 40))
                .foregroundStyle(.gray)
                .padding(.bottom, 12)
            Text(title)
                .font(.system(size: 16, weight: .bold))
                .multilineTextAlignment(.center)
            Text(detail)
                .font(.system(size: 13))
                .foregroundStyle(.gray)
                .multilineTextAlignment(.center)
                .padding(.top, 4)
        }
    }
}

