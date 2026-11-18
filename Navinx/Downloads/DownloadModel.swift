import Foundation
import Lyrics
import Observation
import Synchronization
import SubsonicKit
import UIKit

/// The signed-in server's downloads: Flutter `OfflineService`. Albums and playlists queue as
/// collections, one at a time, a few songs at once; a song from its menu goes straight away.
///
/// Fixes from Flutter (D51, D58): "Downloaded" shows only while every song is really there;
/// removing a collection keeps the songs another downloaded album or playlist needs; the saved
/// list is checked against the files at launch; a collection that ends incomplete says so and
/// tries again on the next launch; cancelling stops the files under way too.
@Observable
final class DownloadModel {
    enum State: Equatable {
        case none
        /// Waiting behind another collection.
        case queued
        case downloading
        /// Every song is there.
        case downloaded

        /// Queued or running: Flutter's spinner, "Downloading — tap to cancel".
        var isActive: Bool { self == .queued || self == .downloading }
    }

    /// Flutter's setting (C11's row), 1–5.
    static let parallelKey = "parallel_downloads_count"

    private(set) var records = DownloadRecords()
    private(set) var profileID: String?
    /// The collection downloading now.
    private(set) var running: String?
    /// How far each song under way has got, 0–1.
    private(set) var songProgress: [String: Double] = [:]
    /// Collections that ended incomplete this run: they show Download again, and retry next launch.
    private(set) var failedThisRun: Set<String> = []

    // Worked out once per change, as every row asks.
    private(set) var downloadedIDs: Set<String> = []
    private(set) var offlineSongs: [Song] = []
    private(set) var songsByAlbum: [String: [Song]] = [:]

    /// Messages for the toast (set by the app).
    @ObservationIgnored var onMessage: ((String) -> Void)?
    /// Smart Downloads (C37): whether their batch may run now (the switch on, and Wi-Fi). Checked
    /// whenever the queue picks its next collection; `automaticConditionsChanged` when it changes.
    @ObservationIgnored var allowsAutomatic: () -> Bool = { false }
    /// Whether the songs Smart Downloads fetched are theirs to keep or remove (the switch on): then
    /// removing an album or playlist leaves them for the next catch-up to decide.
    @ObservationIgnored var keepsAutomatic: () -> Bool = { false }
    /// Signed in to a server online (every `activate` with a client): Smart Downloads' catch-up.
    @ObservationIgnored var onConnect: (() -> Void)?
    /// Another server's records are loaded, or none (signed out): before anything of the new one runs.
    @ObservationIgnored var onProfileChange: (() -> Void)?
    /// A downloaded playlist's page brought a changed list: the new list, then the old one.
    @ObservationIgnored var onPlaylistChanged: (([Song], [Song]) -> Void)?
    /// Song files were removed (Remove Download, Delete All, Smart Downloads' tidy): a song the
    /// player lined up next from its file is lined up again (the audit's P4).
    @ObservationIgnored var onFilesRemoved: (() -> Void)?

    @ObservationIgnored private var client: SubsonicClient?
    @ObservationIgnored private var store: DownloadStore?
    @ObservationIgnored private let transport: any DownloadTransport
    @ObservationIgnored private let root: URL
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let fetchLyrics: @Sendable (Song, SubsonicClient) async -> [LyricLine]
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var runGeneration = 0
    /// The song menu's downloads under way, by song. Each has its own number, so one stopped and
    /// started again (another address) doesn't tidy away its successor's entry.
    @ObservationIgnored private var singleTasks: [String: SingleDownload] = [:]
    @ObservationIgnored private var singleCount = 0
    /// Each song's fetch under way, by song: one at a time, as two would write the same file.
    @ObservationIgnored private var transfers: [String: Task<Bool, Never>] = [:]
    /// The fetches stopped by another address (`restartOnNewAddress`): one whose file is already whole
    /// leaves it for the run that starts again, which then skips the transfer.
    @ObservationIgnored private var stoppedForAddress: Set<Task<Bool, Never>> = []
    @ObservationIgnored private var coversInFlight: Set<String> = []
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    /// The lists' update after songs finish during a run, once for several.
    @ObservationIgnored private var recomputeTask: Task<Void, Never>?
    /// Where the covers are told about (tests give their own, as `.shared` is the whole process's).
    @ObservationIgnored private let offlineCovers: OfflineCovers

    init(
        transport: any DownloadTransport = BackgroundDownloader.shared,
        root: URL = DownloadStore.rootDirectory,
        defaults: UserDefaults = .standard,
        offlineCovers: OfflineCovers = .shared,
        lyrics: (@Sendable (Song, SubsonicClient) async -> [LyricLine])? = nil
    ) {
        self.transport = transport
        self.root = root
        self.defaults = defaults
        self.offlineCovers = offlineCovers
        fetchLyrics = lyrics ?? { song, client in
            await LyricsLoader(client: client, lrclib: .shared, usesLRCLib: { LyricsSettings.usesLRCLib })
                .remoteLines(client: client, songID: song.id, artist: song.artist, title: song.title)
        }
    }

    // MARK: Which server

    /// The signed-in server, online (`client`) or offline (nil). Loads its records the first time
    /// and, online, carries on with its queue (Flutter: queued collections resume at launch).
    /// `catchesUp` false (a Siri or Shortcuts request with no window, D156): no Smart Downloads catch-up.
    func activate(profileID: String, client: SubsonicClient?, catchesUp: Bool = true) {
        if self.profileID != profileID {
            stopEverything()
            flushSave()
            self.profileID = profileID
            let store = DownloadStore(profileID: profileID, root: root)
            self.store = store
            records = store.load()
            let tidied = store.tidy(&records)
            failedThisRun = []
            recompute()
            if tidied { save() }
            dropUnreadableCovers()
            onProfileChange?()
        }
        let oldAddress = self.client?.baseURL
        self.client = client
        if client == nil {
            stopEverything()
        } else {
            // The same server on another address (home, away): what's under way bound the old one, and
            // would hang or fail there, so it starts again on the new one. Songs already here stay.
            if let oldAddress, oldAddress != client?.baseURL { restartOnNewAddress() }
            runQueueIfNeeded()
            // Nothing to run: what an earlier run left (a song's own download, cut off with the app) is
            // no one's, and its file would land with no record.
            if runTask == nil { transport.cancelUnclaimedLeftovers() }
            if catchesUp { onConnect?() }
        }
    }

    /// The server in use, while online.
    var activeClient: SubsonicClient? { client }

    /// Signed out or switching away: downloads stop and wait for that server's next sign-in.
    func deactivate() {
        stopEverything()
        flushSave()
        profileID = nil
        store = nil
        client = nil
        records = DownloadRecords()
        failedThisRun = []
        recompute()
        onProfileChange?()
    }

    /// Whether a server has a downloaded song, for the unreachable screen's offline mode.
    static func hasDownloads(profileID: String, root: URL = DownloadStore.rootDirectory) -> Bool {
        DownloadStore(profileID: profileID, root: root).hasSongs()
    }

    /// Logout (Flutter `deleteAllDownloads`): that server's downloads go, and the tasks still under way
    /// for them (left from an earlier run too) stop, so none brings a file back.
    static func removeDownloads(
        profileID: String,
        root: URL = DownloadStore.rootDirectory,
        transport: any DownloadTransport = BackgroundDownloader.shared
    ) {
        let store = DownloadStore(profileID: profileID, root: root)
        transport.cancelTasks(under: store.directory)
        store.removeAll()
    }

    // MARK: What's there

    func isDownloaded(_ songID: String) -> Bool { downloadedIDs.contains(songID) }

    /// The song's file, for the player. None if the file has gone, so the song streams instead.
    func localFile(for song: Song) -> URL? {
        guard let record = records.songs[song.id], let store else { return nil }
        let file = store.songFile(record.file)
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    func savedLyrics(songID: String) -> [LyricLine]? {
        guard isDownloaded(songID) else { return nil }
        return store?.lyrics(songID: songID)
    }

    func downloadedCount(_ songs: [Song]) -> Int {
        Set(songs.map(\.id)).filter(downloadedIDs.contains).count
    }

    func allDownloaded(_ songs: [Song]) -> Bool {
        !songs.isEmpty && songs.allSatisfy { downloadedIDs.contains($0.id) }
    }

    /// A collection's button. `songs` is the page's list, when it has one (it may have changed
    /// since the download).
    func state(of id: String, songs: [Song]? = nil) -> State {
        if running == id { return .downloading }
        if records.queue.contains(id), !failedThisRun.contains(id), client != nil { return .queued }
        return allDownloaded(songs ?? records.collections[id]?.songs ?? []) ? .downloaded : .none
    }

    /// For album cards, which know only the album's song count.
    func isAlbumDownloaded(_ album: Album) -> Bool {
        if let songs = records.collections[album.id]?.songs, !songs.isEmpty { return allDownloaded(songs) }
        guard let count = album.songCount, count > 0 else { return false }
        return (songsByAlbum[album.id]?.count ?? 0) >= count
    }

    /// The record a song menu's download keeps while it runs (the audit's P2): a one-song collection
    /// in the queue, so the next launch takes the task over (or its file, if iOS finished it) and the
    /// tidy keeps the file. Older builds read it as a batch like Favorites' and run it the same way.
    static func songCollectionID(_ songID: String) -> String { "\(songCollectionPrefix)\(songID)" }
    private static let songCollectionPrefix = "song:"

    func isSongDownloading(_ songID: String) -> Bool {
        singleTasks[songID] != nil || songProgress[songID] != nil
    }

    /// Every album with a downloaded song, by name (Flutter kept only the 20 played last).
    var downloadedAlbums: [Album] {
        songsByAlbum.compactMap { id, songs in album(id: id, songs: songs) }
            .sorted { ($0.name.lowercased(), $0.id) < ($1.name.lowercased(), $1.id) }
    }

    /// An album as saved, or put together from its downloaded songs.
    func album(id: String) -> Album? {
        if let album = records.collections[id]?.fullAlbum { return album }
        return songsByAlbum[id].flatMap { album(id: id, songs: $0) }
    }

    private func album(id: String, songs: [Song]) -> Album? {
        if let saved = records.collections[id]?.fullAlbum { return saved }
        guard let first = songs.first else { return nil }
        return Album(
            id: id,
            name: first.album ?? "Unknown Album",
            artist: first.artist,
            artistID: first.artistID,
            coverArt: first.coverArt,
            songCount: songs.count,
            duration: songs.reduce(0) { $0 + ($1.duration ?? 0) },
            year: first.year,
            genre: first.genre,
            songs: songs
        )
    }

    /// A downloaded playlist as saved.
    func playlist(id: String) -> Playlist? {
        records.collections[id]?.fullPlaylist
    }

    var downloadedPlaylists: [Playlist] {
        records.collections.values.compactMap(\.fullPlaylist).sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    /// Bytes on disk, measured away from the main thread.
    func totalSize() async -> Int64 { await store?.measuredSize() ?? 0 }

    // MARK: Asking for downloads

    /// Flutter `queuePlaylistDownload` for an album. Returns the toast's song count.
    @discardableResult
    func download(album: Album, songs: [Song]) -> Int {
        enqueue(CollectionRecord(album: album, songs: songs))
        return songs.count
    }

    @discardableResult
    func download(playlist: Playlist, songs: [Song]) -> Int {
        enqueue(CollectionRecord(playlist: playlist, songs: songs))
        return songs.count
    }

    /// Favorites' Download All: through the same queue, so it says "Queued" at once and skips the
    /// songs already there (Flutter fetched them one by one first, and fetched every one again).
    @discardableResult
    func download(batch id: String, name: String, songs: [Song]) -> Int {
        let missing = songs.filter { !isDownloaded($0.id) }
        guard !missing.isEmpty else {
            if claim(songs) { save() }
            return 0
        }
        claim(songs)
        enqueue(CollectionRecord(batchID: id, name: name, songs: missing))
        return missing.count
    }

    private func enqueue(_ collection: CollectionRecord) {
        guard store != nil else { return }
        if collection.id != SmartDownloadLogic.batchID { claim(collection.songs) }
        records.collections[collection.id] = collection
        failedThisRun.remove(collection.id)
        if !records.queue.contains(collection.id) { records.queue.append(collection.id) }
        save()
        runQueueIfNeeded()
    }

    /// The user asked for these songs by hand: the ones Smart Downloads fetched become the user's
    /// (so un-favouriting no longer removes them, the check's C7), and a download removed by hand
    /// before may come back. True if anything changed.
    @discardableResult
    private func claim(_ songs: [Song]) -> Bool {
        var changed = false
        for song in songs {
            if records.songs[song.id]?.automatic == true {
                records.songs[song.id]?.automatic = nil
                changed = true
            }
            if records.removedByHand.remove(song.id) != nil { changed = true }
        }
        return changed
    }

    /// A page loaded its songs from the server: a downloaded collection keeps its list up to date,
    /// so a song added since shows it as not downloaded (Flutter's stayed green).
    func refresh(collectionID id: String, songs: [Song]) {
        guard var collection = records.collections[id], collection.kind != .songs,
              collection.songs.map(\.id) != songs.map(\.id) else { return }
        let old = collection.songs
        collection.songs = songs
        records.collections[id] = collection
        save()
        if collection.kind == .playlist { onPlaylistChanged?(songs, old) }
    }

    // MARK: Smart Downloads (C37, D144)

    /// Whether Smart Downloads fetched the song (and so may remove it).
    func isAutomatic(_ songID: String) -> Bool { records.songs[songID]?.automatic == true }

    /// The smart downloads' batch: `songs` join it (`replacing`: become it, the catch-up's whole list),
    /// skipping what's here. It runs after the user's own downloads, on Wi-Fi only. A batch that
    /// failed is tried again.
    func queueAutomatic(_ songs: [Song], replacing: Bool = false) {
        guard store != nil else { return }
        let id = SmartDownloadLogic.batchID
        let existing = replacing ? [] : (records.collections[id]?.songs ?? [])
        let list = SmartDownloadLogic.songsToFetch(
            existing + songs, downloaded: downloadedIDs, isEnabled: true, skipping: records.removedByHand
        )
        guard !list.isEmpty else {
            if records.collections[id] != nil { cancel(id) }
            return
        }
        if records.collections[id]?.songs == list, records.queue.contains(id), !failedThisRun.contains(id) {
            runQueueIfNeeded()
            return
        }
        enqueue(CollectionRecord(batchID: id, name: "Smart Downloads", songs: list))
    }

    /// Smart Downloads switched off: their batch stops; what they fetched stays.
    func cancelAutomatic() { cancel(SmartDownloadLogic.batchID) }

    /// The files Smart Downloads chose to remove (`SmartDownloadLogic.removable`). Only songs they
    /// fetched themselves go, whatever is asked.
    func removeAutomatic(_ songIDs: Set<String>) {
        let ids = songIDs.filter(isAutomatic)
        guard !ids.isEmpty else { return }
        for id in ids { removeFiles(id) }
        recompute()
        save()
        onFilesRemoved?()
    }

    /// Favourited again: these songs' downloads, removed by hand before, may be fetched again.
    func forgetRemovals(_ songIDs: Set<String>) {
        guard !records.removedByHand.isDisjoint(with: songIDs) else { return }
        records.removedByHand.subtract(songIDs)
        save()
    }

    /// A catch-up read what's wanted now: a removal by hand is remembered only for those songs.
    func keepRemovals(among wanted: Set<String>) {
        guard !records.removedByHand.isSubset(of: wanted) else { return }
        records.removedByHand.formIntersection(wanted)
        save()
    }

    /// The favourite albums' song IDs as Smart Downloads last fetched them.
    var smartAlbums: [String: [String]] { records.smartAlbums }

    func setSmartAlbums(_ albums: [String: [String]]) {
        guard records.smartAlbums != albums, store != nil else { return }
        records.smartAlbums = albums
        save()
    }

    /// The switch or the network changed: the smart batch stops if it may no longer run (the files
    /// under way too), or starts if it may now.
    func automaticConditionsChanged() {
        if running == SmartDownloadLogic.batchID, !allowsAutomatic() {
            restartQueue()
        } else {
            runQueueIfNeeded()
        }
    }

    /// Flutter `cancelPlaylistDownload`, with no question. Songs already fetched stay; the files
    /// under way stop (Flutter finished them).
    func cancel(_ id: String) {
        records.queue.removeAll { $0 == id }
        failedThisRun.remove(id)
        if records.collections[id]?.kind == .songs { records.collections[id] = nil }
        if running == id {
            restartQueue()
        }
        save()
    }

    /// Remove downloads: the collection's songs go, except those another downloaded album or
    /// playlist still has (Flutter deleted those too).
    ///
    /// The user tapped "Downloaded — tap to remove": Smart Downloads' own songs go too, and with the
    /// switch on they stay away until downloaded or favourited again (C47, the check's C2; before,
    /// they were kept and Remove did nothing on a favourite album).
    /// `leavingSmartSongs`: the collection only went away (its playlist was deleted), which is no
    /// request to remove a favourite: Smart Downloads' own songs are left for the next catch-up.
    func remove(collectionID id: String, songs: [Song] = [], leavingSmartSongs: Bool = false) {
        let listed = (records.collections[id]?.songs ?? []) + songs
        forgetAddressStops(of: listed.map(\.id))
        cancel(id)
        records.collections[id] = nil
        let needed = SmartDownloadLogic.neededByCollections(records)
        let isSmartOn = keepsAutomatic()
        for songID in Set(listed.map(\.id)) where !needed.contains(songID) && records.songs[songID] != nil {
            if leavingSmartSongs, isSmartOn, isAutomatic(songID) { continue }
            removeFiles(songID)
            if isSmartOn, !leavingSmartSongs { records.removedByHand.insert(songID) }
        }
        recompute()
        save()
        onFilesRemoved?()
    }

    /// The song menu's Download: straight away, with its own toast.
    func downloadSong(_ song: Song) {
        guard client != nil, let store, singleTasks[song.id] == nil, !isDownloaded(song.id) else { return }
        records.removedByHand.remove(song.id)
        // The server's folder first: a finished file isn't let in without it (`BackgroundDownloader`).
        store.prepare()
        // Written at once: the app may be closed before the song is done.
        let id = Self.songCollectionID(song.id)
        records.collections[id] = CollectionRecord(batchID: id, name: song.title, songs: [song])
        failedThisRun.remove(id)
        if !records.queue.contains(id) { records.queue.append(id) }
        save(now: true)
        startSingle(song)
    }

    private struct SingleDownload {
        let number: Int
        let task: Task<Void, Never>
    }

    private func startSingle(_ song: Song) {
        guard let client else { return }
        singleCount += 1
        let number = singleCount
        songProgress[song.id] = 0
        let task = Task {
            let ok = await fetch(song, client: client)
            // Stopped and started again meanwhile: the new one carries on, and this one is no one's.
            guard singleTasks[song.id]?.number == number else { return }
            singleTasks[song.id] = nil
            songProgress[song.id] = nil
            guard !Task.isCancelled else { return }
            // Done either way: its record goes (a failure isn't tried again, as before).
            let id = Self.songCollectionID(song.id)
            records.queue.removeAll { $0 == id }
            records.collections[id] = nil
            if ok { recompute() }
            save(now: true)
            onMessage?(ok ? "Downloaded \"\(song.title)\"" : "Download failed")
        }
        singleTasks[song.id] = SingleDownload(number: number, task: task)
    }

    /// Whether the collection is a song menu's download running on its own this run: the queue
    /// leaves it to that.
    private func isRunningOnItsOwn(_ collectionID: String) -> Bool {
        guard collectionID.hasPrefix(Self.songCollectionPrefix),
              let songID = records.collections[collectionID]?.songs.first?.id else { return false }
        return singleTasks[songID] != nil
    }

    /// Another address: the running collection and the song menu's downloads stop and start again on
    /// it, from what's still missing (the audit's P1).
    private func restartOnNewAddress() {
        stoppedForAddress.formUnion(transfers.values)
        let songs = singleTasks.keys.sorted().compactMap { records.collections[Self.songCollectionID($0)]?.songs.first }
        for song in songs {
            singleTasks[song.id]?.task.cancel()
            startSingle(song)
        }
        if runTask != nil { restartQueue() }
    }

    /// The song menu's Remove Download (Flutter `deleteSong`). An album or playlist with it no
    /// longer shows as downloaded.
    func removeSong(_ songID: String) {
        forgetAddressStops(of: [songID])
        singleTasks.removeValue(forKey: songID)?.task.cancel()
        songProgress[songID] = nil
        cancel(Self.songCollectionID(songID))
        // With Smart Downloads on, a favourite removed by hand isn't fetched again at the next catch-up.
        if keepsAutomatic(), records.songs[songID] != nil { records.removedByHand.insert(songID) }
        removeFiles(songID)
        recompute()
        save()
        onFilesRemoved?()
    }

    /// Delete All Downloads: everything for this server.
    func removeAll() {
        stopEverything()
        saveTask?.cancel()
        saveTask = nil
        if let store {
            // Tasks left from an earlier run of the app would bring their files back.
            transport.cancelTasks(under: store.directory)
            store.removeAll()
        }
        records = DownloadRecords()
        failedThisRun = []
        recompute()
        onFilesRemoved?()
    }

    private func removeFiles(_ songID: String) {
        guard let record = records.songs.removeValue(forKey: songID) else { return }
        store?.removeFiles(of: record)
    }

    // MARK: The queue

    private var parallelLimit: Int {
        let value = defaults.integer(forKey: Self.parallelKey)
        return value == 0 ? 3 : min(max(value, 1), 5)
    }

    private func runQueueIfNeeded() {
        guard runTask == nil, client != nil, let store, nextCollection != nil else { return }
        // The server's folder first: a finished file isn't let in without it (`BackgroundDownloader`).
        store.prepare()
        runGeneration += 1
        let generation = runGeneration
        runTask = Task {
            await runQueue()
            guard runGeneration == generation else { return }
            runTask = nil
            // The queue has run: a task left from an earlier run that it didn't take is no one's.
            if !Task.isCancelled { transport.cancelUnclaimedLeftovers() }
        }
    }

    /// The user's own collections first, oldest first; Smart Downloads' batch last, and only while it
    /// may run (the switch on, Wi-Fi).
    private var nextCollection: CollectionRecord? {
        if let own = nextOwnCollection { return own }
        let id = SmartDownloadLogic.batchID
        guard records.queue.contains(id), !failedThisRun.contains(id), allowsAutomatic() else { return nil }
        return records.collections[id]
    }

    /// The oldest collection the user asked for that's still waiting. Smart Downloads' batch gives
    /// way to it between songs (C46, D163).
    private var nextOwnCollection: CollectionRecord? {
        let id = records.queue.first {
            $0 != SmartDownloadLogic.batchID && !failedThisRun.contains($0) && !isRunningOnItsOwn($0)
        }
        return id.flatMap { records.collections[$0] }
    }

    /// Stops the running collection and starts on what's left.
    private func restartQueue() {
        runTask?.cancel()
        runTask = nil
        running = nil
        runQueueIfNeeded()
    }

    private func stopEverything() {
        runTask?.cancel()
        runTask = nil
        running = nil
        singleTasks.values.forEach { $0.task.cancel() }
        singleTasks = [:]
        // Kept until each ends, so a new fetch of the same song waits for the old one to let go.
        transfers.values.forEach { $0.cancel() }
        // Removed, Delete All, logout, another server: nothing stopped is kept.
        stoppedForAddress = []
        songProgress = [:]
    }

    /// A removal: these songs' fetches stopped by another address don't keep their files.
    private func forgetAddressStops(of songIDs: [String]) {
        for id in songIDs { if let transfer = transfers[id] { stoppedForAddress.remove(transfer) } }
    }

    /// Whether a fetch stopped by another address keeps its file: whole, and still wanted by a
    /// collection in the queue (the run that starts again takes it in).
    private func keepsFileAfterAddressStop(_ song: Song, file: URL) -> Bool {
        guard let transfer = transfers[song.id], stoppedForAddress.contains(transfer),
              DownloadStore.isValid(file, expectedSize: song.size) else { return false }
        return records.queue.contains { id in records.collections[id]?.songs.contains { $0.id == song.id } == true }
    }

    /// Flutter's queue processor: one collection at a time; failed songs get one more try at the end.
    private func runQueue() async {
        while !Task.isCancelled, let collection = nextCollection, let client {
            running = collection.id
            await saveCover(collection.coverArt, client: client)
            let automatic = collection.id == SmartDownloadLogic.batchID
            var missing = Self.unique(collection.songs).filter { !isDownloaded($0.id) }
            var gaveWay = false
            for _ in 0..<2 where !missing.isEmpty {
                missing = await fetchAll(missing, client: client, automatic: automatic)
                if Task.isCancelled { return }
                // The user asked for an album or a playlist while Smart Downloads' batch ran: theirs
                // goes first (D153). The batch stopped after the songs it was on, and takes up again
                // from what's missing once the user's own are done.
                if automatic, nextOwnCollection != nil {
                    gaveWay = true
                    break
                }
            }
            running = nil
            recompute()
            if gaveWay { continue }
            // Asked again while this ran (a second Download All), or its page brought a new list: the
            // record isn't the one this run had, so it isn't finished, and runs again from what's there.
            guard records.collections[collection.id] == collection else { continue }
            if missing.isEmpty {
                records.queue.removeAll { $0 == collection.id }
                if collection.kind == .songs { records.collections[collection.id] = nil }
            } else if collection.id.hasPrefix(Self.songCollectionPrefix) {
                // A song menu's download the queue took up (a launch, say): one toast and gone, as
                // `startSingle`'s own failure, not tried and told again at every launch.
                records.queue.removeAll { $0 == collection.id }
                records.collections[collection.id] = nil
                onMessage?("Download failed")
            } else {
                failedThisRun.insert(collection.id)
                // Smart Downloads are silent (D144): the next catch-up tries again.
                if !automatic { onMessage?("Download failed") }
            }
            save(now: true)
        }
    }

    /// Up to `parallelLimit` at once. Returns the songs that failed. Smart Downloads' batch
    /// (`automatic`) starts no further song once one of the user's own collections waits, and returns
    /// the songs it didn't get to as well.
    private func fetchAll(_ songs: [Song], client: SubsonicClient, automatic: Bool = false) async -> [Song] {
        let limit = parallelLimit
        return await withTaskGroup(of: (Song, Bool).self) { group in
            var pending = songs.makeIterator()
            for _ in 0..<limit {
                guard let song = pending.next() else { break }
                group.addTask { (song, await self.fetch(song, client: client, automatic: automatic)) }
            }
            var failed: [Song] = []
            for await (song, ok) in group {
                if !ok { failed.append(song) }
                if !Task.isCancelled, !(automatic && nextOwnCollection != nil), let next = pending.next() {
                    group.addTask { (next, await self.fetch(next, client: client, automatic: automatic)) }
                }
            }
            if automatic, !Task.isCancelled { while let left = pending.next() { failed.append(left) } }
            return failed
        }
    }

    /// One fetch per song: asked twice (its menu, then its album, or the other way round), two would
    /// write the same file, and a failing one would delete the other's. The second waits for the
    /// first, and fetches itself only if that one ended without the song.
    /// `automatic`: for Smart Downloads, so on Wi-Fi only and marked as theirs. A song the user asked
    /// for while Smart Downloads were fetching it becomes the user's.
    private func fetch(_ song: Song, client: SubsonicClient, automatic: Bool = false) async -> Bool {
        var waited: Task<Bool, Never>?
        while let other = transfers[song.id], other != waited {
            waited = other
            _ = await other.value
            guard !Task.isCancelled else { return false }
        }
        guard store != nil, !Task.isCancelled else { return false }
        if isDownloaded(song.id) {
            if !automatic, isAutomatic(song.id) { records.songs[song.id]?.automatic = nil }
            return true
        }
        let transfer = Task { await self.fetchFiles(song, client: client, automatic: automatic) }
        transfers[song.id] = transfer
        let ok = await withTaskCancellationHandler {
            await transfer.value
        } onCancel: {
            transfer.cancel()
        }
        stoppedForAddress.remove(transfer)
        if transfers[song.id] == transfer { transfers[song.id] = nil }
        return ok
    }

    /// Flutter `downloadSong`: the original file (`download`, no transcoding), then its cover and
    /// lyrics, which don't fail the song if they fail. A file already there (a background download
    /// that finished while the app was closed) is taken as it is.
    private func fetchFiles(_ song: Song, client: SubsonicClient, automatic: Bool) async -> Bool {
        guard let store, !Task.isCancelled else { return false }
        if isDownloaded(song.id) { return true }
        let name = DownloadStore.fileName(for: song)
        let file = store.songFile(name)
        if !DownloadStore.isValid(file, expectedSize: song.size) {
            songProgress[song.id] = 0
            let id = song.id
            let lastPercent = Mutex(-1)
            do {
                try await transport.download(from: client.downloadURL(songID: id), to: file, wifiOnly: automatic) { [weak self] fraction in
                    let percent = Int(fraction * 100)
                    let isNew = lastPercent.withLock { last in
                        defer { last = percent }
                        return percent != last
                    }
                    guard isNew else { return }
                    Task { @MainActor in
                        if self?.songProgress[id] != nil { self?.songProgress[id] = fraction }
                    }
                }
            } catch {
                if singleTasks[id] == nil { songProgress[id] = nil }
                return false
            }
            if singleTasks[id] == nil { songProgress[id] = nil }
            guard DownloadStore.isValid(file, expectedSize: song.size) else {
                try? FileManager.default.removeItem(at: file)
                return false
            }
        }
        // Signed out or switched while it ran: this server's records aren't loaded any more.
        guard self.store?.directory == store.directory else { return false }
        var lines: [LyricLine] = []
        if !Task.isCancelled {
            await saveCover(song.coverArt, client: client)
            lines = await fetchLyrics(song, client)
        }
        guard self.store?.directory == store.directory else { return false }
        // Stopped meanwhile (cancelled, removed, Delete All, logout): not downloaded, and its file
        // isn't left behind. Nor is a file that has gone meanwhile recorded. Stopped by another address,
        // a whole file stays for the run that starts again there.
        guard !Task.isCancelled, FileManager.default.fileExists(atPath: file.path) else {
            if !keepsFileAfterAddressStop(song, file: file) { try? FileManager.default.removeItem(at: file) }
            return false
        }
        store.saveLyrics(lines, songID: song.id)
        records.songs[song.id] = SongRecord(song: song, file: name, downloadedAt: .now, automatic: automatic ? true : nil)
        recomputeSoon(adding: song.id)
        // In the background (iOS handing over finished downloads) the app may be suspended before a
        // later save, and the song lost from the list: there it's written within a second, once for the
        // songs that finish meanwhile. The collection's end and a song's own download write at once.
        if UIApplication.shared.applicationState == .active {
            save()
        } else {
            saveWithin(.seconds(1))
        }
        return true
    }

    /// The 600 px cover, once per cover (Flutter's `art_<coverArt>.jpg`).
    private func saveCover(_ coverArt: String?, client: SubsonicClient) async {
        guard let coverArt, !coverArt.isEmpty, let store, !records.covers.contains(coverArt),
              !coversInFlight.contains(coverArt), let url = client.coverArtURL(coverArt, size: 600) else { return }
        coversInFlight.insert(coverArt)
        defer { coversInFlight.remove(coverArt) }
        let file = store.coverFile(coverArt)
        guard (try? await transport.download(from: url, to: file, progress: { _ in })) != nil else { return }
        // A server answers an error, and a portal its page, with HTTP 200 too: only a picture is a cover.
        guard await store.isPicture(coverArt: coverArt) else {
            try? FileManager.default.removeItem(at: file)
            return
        }
        guard self.store?.directory == store.directory, !Task.isCancelled else { return }
        records.covers.insert(coverArt)
        offlineCovers.add(coverArt)
    }

    /// Covers an earlier build saved that aren't pictures (a server's error) go, and are fetched again
    /// online. Away from the main thread, as it opens every cover.
    private func dropUnreadableCovers() {
        guard let store, !records.covers.isEmpty else { return }
        let covers = records.covers
        Task {
            let unreadable = await store.unreadableCovers(covers)
            guard !unreadable.isEmpty, self.store?.directory == store.directory else { return }
            records.covers.subtract(unreadable)
            offlineCovers.set(store: store, covers: records.covers)
            for cover in unreadable { try? FileManager.default.removeItem(at: store.coverFile(cover)) }
            save()
            guard let client else { return }
            for cover in unreadable.sorted() { await saveCover(cover, client: client) }
            save()
        }
    }

    // MARK: Saving

    private func recompute() {
        recomputeTask?.cancel()
        recomputeTask = nil
        downloadedIDs = Set(records.songs.keys)
        // Each song's keys worked out once, not in every comparison.
        offlineSongs = records.songs.values
            .map { (song: $0.song, album: $0.song.album?.lowercased() ?? "", title: $0.song.title.lowercased()) }
            .sorted { ($0.album, $0.song.track ?? 0, $0.title, $0.song.id) < ($1.album, $1.song.track ?? 0, $1.title, $1.song.id) }
            .map(\.song)
        songsByAlbum = Dictionary(grouping: offlineSongs.filter { $0.albumID != nil }) { $0.albumID ?? "" }
        offlineCovers.set(store: store, covers: records.covers)
    }

    /// A song finished during a run: its mark at once, the sorted lists a moment later, once for the
    /// songs that finish meanwhile (the collection's end brings them up to date at once).
    private func recomputeSoon(adding songID: String) {
        downloadedIDs.insert(songID)
        guard recomputeTask == nil else { return }
        recomputeTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            recomputeTask = nil
            recompute()
        }
    }

    /// Soon after the last change; at once when it matters.
    private func save(now: Bool = false) {
        guard let store else { return }
        saveTask?.cancel()
        if now {
            saveTask = nil
            store.save(records)
            return
        }
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, self.store?.directory == store.directory else { return }
            store.save(records)
            saveTask = nil
        }
    }

    /// Within `delay` of the first change, not pushed back by the next ones (a run in the background,
    /// where songs finish one after another).
    private func saveWithin(_ delay: Duration) {
        guard let store, saveTask == nil else { return }
        saveTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, self.store?.directory == store.directory else { return }
            store.save(records)
            saveTask = nil
        }
    }

    /// Writes a save that's waiting, before the records change hands.
    private func flushSave() {
        guard saveTask != nil, let store else { return }
        saveTask?.cancel()
        saveTask = nil
        store.save(records)
    }

    /// Writes what's waiting (the app going to the background).
    func saveNow() { save(now: true) }

    private static func unique(_ songs: [Song]) -> [Song] {
        var seen = Set<String>()
        return songs.filter { seen.insert($0.id).inserted }
    }

    // MARK: Offline library

    /// What the Library and Home show offline when the saved library is gone (it's in the caches,
    /// which iOS can empty): the downloads' own albums, artists, playlists and songs.
    func offlineSnapshot() -> LibrarySnapshot {
        let albums = downloadedAlbums
        var artists: [String: Artist] = [:]
        for song in offlineSongs {
            guard let id = song.artistID, artists[id] == nil else { continue }
            artists[id] = Artist(id: id, name: song.artist ?? "Unknown Artist")
        }
        return LibrarySnapshot(
            savedAt: .distantPast,
            artists: artists.values.sorted { $0.name.lowercased() < $1.name.lowercased() },
            latestAlbums: Array(albums.prefix(20)),
            playlists: downloadedPlaylists,
            allAlbums: albums,
            allSongs: offlineSongs
        )
    }
}
