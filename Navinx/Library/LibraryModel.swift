import Foundation
import Observation
import SubsonicKit

/// The library's lists: Flutter `LibraryProvider`'s load, sync and refresh. The last full sync is
/// saved per server (`LibraryCache`), so the lists show at once on the next launch.
@Observable
final class LibraryModel {
    private(set) var artists: [Artist] = []
    private(set) var latestAlbums: [Album] = []
    private(set) var playlists: [Playlist] = []
    private(set) var allAlbums: [Album] = []
    private(set) var allSongs: [Song] = []
    /// What Home's recommendations work from until the full sync has the songs.
    private(set) var randomSongs: [Song] = []
    private(set) var isLoading = false
    private(set) var isSyncingQuietly = false
    /// When the saved library was last brought up to date.
    private(set) var lastSynced: Date?

    /// How old a saved library may be before a full sync (Flutter: 6 hours).
    static let maximumAge: TimeInterval = 6 * 60 * 60

    private var client: SubsonicClient?
    private var cacheKey: String?
    /// Which account the lists are for (`AccountKey.mark`): a saved copy another account left under
    /// the same profile isn't shown, and the widgets and Spotlight take the lists only for it.
    private var accountMark: String?
    private(set) var isInitialized = false
    private var startTask: Task<Void, Never>?
    private var syncTask: Task<Void, Never>?
    /// The full sync a moment after the first load.
    @ObservationIgnored private var delayedSync: Task<Void, Never>?
    /// The opened playlists' saves, one after another.
    @ObservationIgnored private var playlistSave: Task<Void, Never>?
    /// The tab bar went (logout, another server): nothing more is asked or saved.
    @ObservationIgnored private var isStopped = false
    /// The lists the server gave since the last (re)load began: one that failed isn't saved over the
    /// saved copy's.
    @ObservationIgnored private var freshLists: Set<FreshList> = []
    nonisolated private enum FreshList { case latestAlbums, playlists, artists }
    private let syncDelay: Duration
    private let cache: LibraryCache

    init(syncDelay: Duration = .seconds(2), cache: LibraryCache = .standard) {
        self.syncDelay = syncDelay
        self.cache = cache
    }

    /// What offline mode shows besides the saved library, or instead of it if iOS has emptied the
    /// caches: the downloads' own albums, artists, playlists and songs (C10).
    @ObservationIgnored private var offlineSnapshot: (() -> LibrarySnapshot)?
    /// Playlists as last opened, with their songs, so offline the page can show them (C10).
    private(set) var openedPlaylists: [String: Playlist] = [:]

    /// Flutter `initialize`, for the signed-in server. With no client (offline mode) it shows the
    /// saved library and the downloads, and asks nothing (C10). `account` (`AccountKey.mark`): the saved
    /// copy under `cacheKey` is dropped first if another account saved it.
    func start(
        client: SubsonicClient?,
        cacheKey: String? = nil,
        account: String? = nil,
        offline: (() -> LibrarySnapshot)? = nil
    ) async {
        // The tabs came back after `stop()` (they left the screen without their account changing).
        isStopped = false
        self.client = client
        self.cacheKey = cacheKey
        accountMark = account
        offlineSnapshot = offline
        let cache = cache
        let task = Task {
            if let cacheKey, let account { await cache.claim(key: cacheKey, account: account) }
            await initialize(schedulesSync: true)
        }
        startTask = task
        await task.value
    }

    /// Offline mode is over: the server answered again. The lists stay while fresh ones load.
    func goOnline(client: SubsonicClient) async {
        await startTask?.value
        guard self.client == nil else { return }
        self.client = client
        isInitialized = false
        let task = Task { await initialize(schedulesSync: true, usesSavedCopy: false) }
        startTask = task
        await task.value
    }

    var isOffline: Bool { client == nil }

    /// The same account's login changed in place (signed in again with a new password, or another
    /// address in use): the next loads use `client`, and what's shown stays. Offline it's left to
    /// `goOnline`.
    func use(_ client: SubsonicClient) {
        guard self.client != nil, !isStopped else { return }
        self.client = client
    }

    /// The tab bar went (logout, another server): what's under way stops, so nothing more is asked
    /// with this server's login, and the saved library isn't written again after logout cleared it.
    /// If the tabs come back instead (`start` again), a sync still needed starts again.
    func stop() {
        isStopped = true
        startTask?.cancel()
        delayedSync?.cancel()
        syncTask?.cancel()
        playlistSave?.cancel()
        isSyncingQuietly = false
    }

    /// Keeps a playlist as the page loaded it, for offline.
    func remember(_ playlist: Playlist) {
        guard playlist.songs != nil, openedPlaylists[playlist.id] != playlist else { return }
        openedPlaylists[playlist.id] = playlist
        guard let cacheKey, !isStopped else { return }
        let cache = cache
        let generation = cache.generation
        let saved = Array(openedPlaylists.values)
        // After the one before, so an older list can't be written last.
        let previous = playlistSave
        playlistSave = Task {
            await previous?.value
            guard !Task.isCancelled, !isStopped else { return }
            await cache.savePlaylists(saved, key: cacheKey, generation: generation)
        }
    }

    /// Flutter `ensureLibraryLoaded`: the first page that needs the full lists (the Library tab,
    /// Listening History) waits for them.
    func loadLibraryIfNeeded() async {
        await startTask?.value
        guard client != nil, allAlbums.isEmpty || allSongs.isEmpty else { return }
        if isSyncingQuietly {
            await sync()
            return
        }
        isLoading = true
        await sync()
        isLoading = false
    }

    /// Flutter `refresh` (pull to refresh): loads it all again. Unlike Flutter, which emptied
    /// everything first, each list stays until its new one arrives, so a refresh with the server down
    /// leaves them as they were. The pull ends with the quick lists; the full sync carries on in the
    /// background, as at launch, and the saved copy is replaced once it has succeeded.
    func refresh() async {
        // Offline there's nothing to load it from, so what's shown stays.
        guard client != nil else { return }
        // A sync under way would end with the lists from before: it stops, and a new one runs below.
        syncTask?.cancel()
        delayedSync?.cancel()
        isInitialized = false
        await initialize(schedulesSync: false, usesSavedCopy: false)
        guard !isStopped else { return }
        delayedSync = Task { [weak self] in await self?.sync() }
    }

    /// Flutter `_scheduleBackgroundRefresh`'s rule.
    var needsSync: Bool {
        guard !allAlbums.isEmpty, !allSongs.isEmpty, let lastSynced else { return true }
        return Date.now.timeIntervalSince(lastSynced) > Self.maximumAge
    }

    private func initialize(schedulesSync: Bool, usesSavedCopy: Bool = true) async {
        guard !isInitialized else {
            // The tabs came back after `stop()` ended a sync: the sync still needed starts again.
            if schedulesSync { scheduleSyncIfNeeded() }
            return
        }
        guard let client else {
            await initializeOffline()
            return
        }
        isLoading = true
        freshLists = []
        if usesSavedCopy, let cacheKey, openedPlaylists.isEmpty {
            for playlist in await cache.loadPlaylists(key: cacheKey, account: accountMark) { openedPlaylists[playlist.id] = playlist }
        }
        if usesSavedCopy, let cacheKey, let saved = await cache.load(key: cacheKey, account: accountMark) {
            artists = saved.artists
            playlists = saved.playlists
            allAlbums = saved.allAlbums
            allSongs = saved.allSongs
            lastSynced = saved.savedAt
            // Flutter's fallback when nothing has been played recently.
            latestAlbums = saved.latestAlbums.isEmpty ? Array(saved.allAlbums.prefix(20)) : saved.latestAlbums
        }
        // Flutter's first load gives the spinner 5 seconds; lists arriving later still appear.
        let spinnerLimit = Task {
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled { isLoading = false }
        }
        await withDiscardingTaskGroup { group in
            group.addTask { await self.fetchLatestAlbums(client) }
            group.addTask { await self.fetchShuffledSongs(client) }
            group.addTask { await self.loadPlaylists(client) }
            group.addTask { await self.loadArtists(client) }
        }
        spinnerLimit.cancel()
        isLoading = false
        // Stopped mid-way (`stop()`): the lists it didn't get load again on the next `start`.
        guard !Task.isCancelled else { return }
        isInitialized = true
        shareWithWidgets()
        if schedulesSync { scheduleSyncIfNeeded() }
    }

    /// The full sync a moment from now, when the library needs one and none is running.
    private func scheduleSyncIfNeeded() {
        guard client != nil, needsSync, !isStopped, !Task.isCancelled else { return }
        if let syncTask, !syncTask.isCancelled { return }
        delayedSync?.cancel()
        let delay = syncDelay
        delayedSync = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled, !isSyncingQuietly else { return }
            await sync()
        }
    }

    /// The saved library, with the downloads added to it (they may be newer than the last sync).
    private func initializeOffline() async {
        isLoading = true
        var saved: LibrarySnapshot?
        if let cacheKey {
            saved = await cache.load(key: cacheKey, account: accountMark)
            for playlist in await cache.loadPlaylists(key: cacheKey, account: accountMark) { openedPlaylists[playlist.id] = playlist }
        }
        let downloads = offlineSnapshot?()
        artists = Self.mergeArtists(saved?.artists ?? [], downloads?.artists ?? [])
        playlists = Self.merge(saved?.playlists ?? [], downloads?.playlists ?? [])
        allAlbums = Self.merge(saved?.allAlbums ?? [], downloads?.allAlbums ?? [])
        allSongs = Self.merge(saved?.allSongs ?? [], downloads?.allSongs ?? [])
        let recent = saved?.latestAlbums ?? []
        latestAlbums = recent.isEmpty ? Array(allAlbums.prefix(20)) : recent
        lastSynced = saved?.savedAt
        isLoading = false
        isInitialized = true
        shareWithWidgets()
    }

    /// The Home Screen widgets' recent albums and playlists (C40); only the app's own library, not a
    /// test's.
    private func shareWithWidgets() {
        guard !isStopped, let accountMark, cache.directory == LibraryCache.standard.directory else { return }
        WidgetSnapshotWriter.shared?.libraryChanged(latestAlbums: latestAlbums, playlists: playlists, account: accountMark)
    }

    /// The first list, then what only the second has.
    private static func merge<T: Identifiable>(_ first: [T], _ second: [T]) -> [T] where T.ID == String {
        merge(first, second, by: \.id)
    }

    private static func merge<T>(_ first: [T], _ second: [T], by key: (T) -> String) -> [T] {
        let known = Set(first.map(key))
        return first + second.filter { !known.contains(key($0)) }
    }

    /// Every saved artist (a combined name's parts keep their own rows under one ID, `Artist.listKey`),
    /// then a downloads' artist only when its ID isn't saved: the downloads name an artist by the song's
    /// whole display string, which would sit beside the saved parts as an extra row.
    nonisolated static func mergeArtists(_ saved: [Artist], _ downloads: [Artist]) -> [Artist] {
        let savedIDs = Set(saved.map(\.id))
        return saved + downloads.filter { !savedIDs.contains($0.id) }
    }

    // Failures keep what's there, so the screen shows the saved lists or Flutter's empty states.

    private func fetchLatestAlbums(_ client: SubsonicClient) async {
        if let albums = try? await client.albumList(.recent, size: 20), !albums.isEmpty {
            latestAlbums = albums
            freshLists.insert(.latestAlbums)
        }
    }

    private func fetchShuffledSongs(_ client: SubsonicClient) async {
        if let songs = try? await client.randomSongs(size: 50) { randomSongs = songs }
    }

    private func loadPlaylists(_ client: SubsonicClient) async {
        if let lists = try? await client.playlists() {
            playlists = lists
            freshLists.insert(.playlists)
            // A playlist made, renamed or deleted (during the first load, `initialize` shares once more).
            if isInitialized { shareWithWidgets() }
        }
    }

    /// After a playlist's songs change.
    func refreshPlaylists() async {
        if let client { await loadPlaylists(client) }
    }

    func createPlaylist(name: String) async throws {
        guard let client else { throw SubsonicError.network }
        try await client.createPlaylist(name: name)
        await loadPlaylists(client)
    }

    func renamePlaylist(id: String, to name: String) async throws {
        guard let client else { throw SubsonicError.network }
        try await client.updatePlaylist(id: id, name: name)
        await loadPlaylists(client)
    }

    /// Flutter `deletePlaylist`: gone from the list at once, and back if the server refuses.
    func deletePlaylist(id: String) async throws {
        guard let client else { throw SubsonicError.network }
        let previous = playlists
        playlists.removeAll { $0.id == id }
        do {
            try await client.deletePlaylist(id: id)
        } catch {
            playlists = previous
            throw error
        }
        await loadPlaylists(client)
    }

    private func loadArtists(_ client: SubsonicClient) async {
        if let list = try? await client.artists() {
            artists = list
            freshLists.insert(.artists)
        }
    }

    #if DEBUG
    func syncNow() async { await sync() }
    #endif

    /// Runs the full sync, or waits for the one already running (not one a refresh has stopped).
    private func sync() async {
        guard !isStopped else { return }
        if let syncTask, !syncTask.isCancelled {
            await syncTask.value
            return
        }
        let task = Task { await runSync() }
        syncTask = task
        await task.value
        if syncTask == task { syncTask = nil }
    }

    /// Flutter `_refreshAllDataInBackground`: every album, 500 at a time; then every album's songs,
    /// 6 at a time. A first sync publishes songs after every 50 albums; a later one swaps them in
    /// when done, so a saved list doesn't shrink meanwhile. Only a complete sync is saved.
    private func runSync() async {
        guard let client else { return }
        // A logout's clear from here on wins over this sync's save.
        let generation = cache.generation
        isSyncingQuietly = true
        // A stopped sync publishes and saves nothing, and leaves the flag to the sync after it.
        defer { if !Task.isCancelled { isSyncingQuietly = false } }

        var albums: [Album] = []
        // Once each: an album added or removed meanwhile can move one across a page's edge.
        var albumIDs = Set<String>()
        var offset = 0
        let fetchBatch = 500
        while true {
            // A failed page abandons the sync and keeps the lists already there.
            guard let page = try? await client.albumList(.alphabeticalByName, size: fetchBatch, offset: offset),
                  !Task.isCancelled else { return }
            offset += page.count
            albums += page.filter { albumIDs.insert($0.id).inserted }
            if page.count < fetchBatch { break }
        }
        guard !albums.isEmpty else { return }
        allAlbums = albums

        let publishesAsItGoes = allSongs.isEmpty
        var seen = Set<String>()
        var songs: [Song] = []
        var isComplete = true
        for batchStart in stride(from: 0, to: albums.count, by: 6) {
            let batch = albums[batchStart..<min(batchStart + 6, albums.count)]
            let results = await withTaskGroup(of: (Int, [Song]?).self) { group in
                for (index, album) in batch.enumerated() {
                    let id = album.id
                    group.addTask { (index, try? await client.albumSongs(albumID: id)) }
                }
                var results: [(Int, [Song]?)] = []
                for await result in group { results.append(result) }
                return results
            }
            if Task.isCancelled { return }
            for (_, albumSongs) in results.sorted(by: { $0.0 < $1.0 }) {
                guard let albumSongs else {
                    isComplete = false
                    continue
                }
                songs += albumSongs.filter { seen.insert($0.id).inserted }
            }
            let done = batchStart + batch.count
            if publishesAsItGoes, done / 50 > batchStart / 50 { allSongs = songs }
        }
        guard isComplete || publishesAsItGoes else { return }
        allSongs = songs
        guard isComplete else { return }

        let now = Date.now
        lastSynced = now
        guard let cacheKey, !isStopped else { return }
        var snapshot = LibrarySnapshot(
            savedAt: now,
            artists: artists,
            latestAlbums: latestAlbums,
            playlists: playlists,
            allAlbums: albums,
            allSongs: songs
        )
        // A list the server didn't give this time (it failed) keeps the saved copy's.
        let fresh = freshLists
        if fresh.count < 3, let saved = await cache.load(key: cacheKey, account: accountMark) {
            if !fresh.contains(.artists) { snapshot.artists = saved.artists }
            if !fresh.contains(.latestAlbums) { snapshot.latestAlbums = saved.latestAlbums }
            if !fresh.contains(.playlists) { snapshot.playlists = saved.playlists }
        }
        guard !isStopped, !Task.isCancelled else { return }
        await cache.save(snapshot, key: cacheKey, generation: generation)
        // Spotlight, Siri and Shortcuts follow the new save (C39); a cleared cache (logout) indexes nothing.
        if !isStopped, let accountMark, cache.directory == LibraryCache.standard.directory {
            SpotlightIndex.refresh(profileID: cacheKey, account: accountMark)
        }
        shareWithWidgets()
    }
}
