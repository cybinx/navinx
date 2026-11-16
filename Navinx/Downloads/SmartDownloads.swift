import Foundation
import Observation
import PlaybackKit
import SubsonicKit

/// Smart Downloads (C37, D144): one switch, off until the user turns it on, **answered once for each
/// server** (C47, D164). Favourite songs, the songs of favourite albums and the songs added to
/// downloaded playlists download by themselves, on Wi-Fi only and silently, through their own batch
/// after the user's own downloads. What they fetched goes again once nothing wants it (un-favourited
/// anywhere, taken out of the playlist); a song the user downloaded, or that a downloaded album or
/// playlist has, always stays (`SmartDownloadLogic`).
///
/// The catch-up asks the server what's wanted: when the switch goes on, at every connection (at most
/// once a minute), on a return to the foreground and when Wi-Fi comes back (at most every 15 minutes).
/// Nothing runs offline, with the switch off, or while the app is closed. Flutter's seed was "Auto
/// Download Favorites" (hidden by D65): one song at its star, on any network, kept when un-starred.
@Observable
final class SmartDownloads {
    /// A new key: Flutter's `offline_auto_download_favorites` meant favourite songs alone. Since C47:
    /// on for at least one server (before it, the one switch for the whole app).
    static let enabledKey = "smart_downloads_enabled"
    /// Each server's answer, by profile ID (C47).
    static let answersKey = "smart_downloads_servers"

    /// On for the server in use.
    private(set) var isEnabled = false
    /// Counting the songs for the switch-on question.
    private(set) var isPreparing = false
    /// The question for a server the user hasn't answered for, once its songs are counted (C47). The
    /// app shows it over whatever is on screen; until it's answered nothing downloads for that server.
    private(set) var question: Plan?

    /// What the switch-on question shows. Saying yes reads the favourites again: this count may be
    /// minutes old by then.
    struct Plan: Identifiable {
        let id = UUID()
        let songCount: Int
        let bytes: Int64
        fileprivate let profileID: String?
    }

    private typealias Found = SmartDownloadLogic.Found

    /// Wi-Fi (set by the app).
    @ObservationIgnored var allowsNetwork: () -> Bool = { false }
    /// The song playing, whose file waits until it stops before going.
    @ObservationIgnored var currentSongID: () -> String? = { nil }

    @ObservationIgnored private let downloads: DownloadModel
    @ObservationIgnored private let defaults: UserDefaults
    /// Each server's answer; nil until a server is in use (a build before C47 saved none).
    @ObservationIgnored private var answers: [String: Bool]?
    /// The favourite songs as last read from the server and changed here since; nil until a catch-up
    /// has read them.
    @ObservationIgnored private var starredSongIDs: Set<String>?
    /// Nothing is removed until a catch-up has read this server's favourites, and its answer is one
    /// to act on (`SmartDownloadLogic.confirmsRemoval`).
    @ObservationIgnored private var mayRemove = false
    @ObservationIgnored private var catchUpTask: Task<Void, Never>?
    @ObservationIgnored private var catchUpGeneration = 0
    @ObservationIgnored private var lastCatchUp: (profileID: String?, at: Date)?
    /// The stars changed in the app while the running catch-up reads the server: its answer is older
    /// than they are, so they go on top of it (C47).
    @ObservationIgnored private var changesDuringRead: [SmartDownloadLogic.StarChange] = []
    /// Songs to remove once they stop playing.
    @ObservationIgnored private var pendingRemovals: Set<String> = []
    /// While a catch-up refreshes the downloaded playlists, their changes are its own to apply.
    @ObservationIgnored private var playlistReads = 0

    init(downloads: DownloadModel, defaults: UserDefaults = .standard) {
        self.downloads = downloads
        self.defaults = defaults
        answers = defaults.dictionary(forKey: Self.answersKey) as? [String: Bool]
        serverChanged()
    }

    /// Whether their batch may run now.
    var mayDownload: Bool { isEnabled && allowsNetwork() }

    // MARK: The server in use

    /// Another server or account, or none (`DownloadModel` says so before anything of the new one
    /// runs): everything known about the old one is dropped, so its favourites never decide what the
    /// new one keeps, and the new one gets its own catch-up (C47, the check's C3).
    func serverChanged() {
        catchUpGeneration += 1
        catchUpTask?.cancel()
        catchUpTask = nil
        starredSongIDs = nil
        mayRemove = false
        pendingRemovals = []
        changesDuringRead = []
        lastCatchUp = nil
        question = nil
        let profileID = downloads.profileID
        if answers == nil {
            answers = SmartDownloadLogic.answers(
                saved: nil, wasOn: defaults.bool(forKey: Self.enabledKey), profileID: profileID
            )
            if let answers { defaults.set(answers, forKey: Self.answersKey) }
        }
        isEnabled = profileID.flatMap { answers?[$0] } ?? false
    }

    private func setAnswer(_ value: Bool) {
        guard let profileID = downloads.profileID else { return }
        var all = answers ?? [:]
        all[profileID] = value
        answers = all
        defaults.set(all, forKey: Self.answersKey)
        defaults.set(all.values.contains(true), forKey: Self.enabledKey)
        isEnabled = value
    }

    // MARK: The switch

    /// Reads what the switch would download, for the question. Nil when the server can't be asked.
    func prepare() async -> Plan? {
        guard let client = downloads.activeClient, !isPreparing else { return nil }
        isPreparing = true
        defer { isPreparing = false }
        let profileID = downloads.profileID
        guard let found = try? await find(client: client, profileID: profileID),
              downloads.profileID == profileID else { return nil }
        let songs = SmartDownloadLogic.songsToFetch(
            found.songs, downloaded: downloads.downloadedIDs, isEnabled: true, skipping: downloads.records.removedByHand
        )
        return Plan(songCount: songs.count, bytes: SmartDownloadLogic.totalSize(songs), profileID: profileID)
    }

    /// The user said yes, for this server. The favourites are read again: the question may have
    /// stood open for a while, and stars changed meanwhile (the check's C4).
    func turnOn(with plan: Plan) {
        guard downloads.profileID == plan.profileID else { return }
        question = nil
        setAnswer(true)
        lastCatchUp = nil
        catchUp(minimumGap: 0)
    }

    /// "Not Now" on a server's question: off for that server, until switched on in Settings.
    func decline(_ plan: Plan) {
        question = nil
        guard downloads.profileID == plan.profileID else { return }
        setAnswer(false)
    }

    /// Stops what's queued and keeps what's here (D144). For the server in use.
    func turnOff() {
        setAnswer(false)
        catchUpGeneration += 1
        catchUpTask?.cancel()
        catchUpTask = nil
        starredSongIDs = nil
        mayRemove = false
        pendingRemovals = []
        changesDuringRead = []
        downloads.cancelAutomatic()
    }

    // MARK: When it runs

    /// Signed in online (every connection change). A server not answered for yet is asked first.
    func connected() {
        if let profileID = downloads.profileID, let answers, SmartDownloadLogic.needsAsking(answers, profileID: profileID) {
            ask()
        } else {
            catchUp(minimumGap: 60)
        }
    }

    /// Counts the new server's songs, then puts the question; with nothing to download there is
    /// nothing to ask, as in Settings.
    private func ask() {
        guard question == nil, !isPreparing else { return }
        Task {
            guard let plan = await prepare(), let profileID = downloads.profileID, plan.profileID == profileID,
                  let answers, SmartDownloadLogic.needsAsking(answers, profileID: profileID) else { return }
            if plan.songCount == 0 {
                turnOn(with: plan)
            } else {
                question = plan
            }
        }
    }

    /// Back from the background.
    func returnedToForeground() { catchUp(minimumGap: 15 * 60) }

    /// Wi-Fi came or went: the batch stops or carries on, and a catch-up is due on Wi-Fi.
    func networkChanged() {
        downloads.automaticConditionsChanged()
        if allowsNetwork() { catchUp(minimumGap: 15 * 60) }
    }

    /// The player's events: a song's star (every way the app stars one goes through the player), and a
    /// song that stopped playing, whose file may now go.
    func handle(_ event: ListenEvent) {
        switch event {
        case .starred(let song, let isStarred):
            songStarChanged(song, isStarred: isStarred)
        case .finished(let song, _, _, _):
            if pendingRemovals.contains(song.id) { removeUnwanted(among: [song.id]) }
        default:
            break
        }
    }

    /// The album page's heart, which the server has taken.
    func albumStarChanged(_ album: Album, isStarred: Bool) {
        guard isEnabled else { return }
        if isStarred {
            let profileID = downloads.profileID
            Task {
                var songs = album.songs
                if songs.isEmpty, let client = downloads.activeClient {
                    songs = (try? await client.album(id: album.id))?.songs ?? []
                }
                guard isEnabled, !songs.isEmpty, downloads.profileID == profileID else { return }
                note(.album(id: album.id, songs: songs, isStarred: true))
                var albums = downloads.smartAlbums
                albums[album.id] = songs.map(\.id)
                downloads.setSmartAlbums(albums)
                // Favourited again: a download removed by hand before comes back.
                downloads.forgetRemovals(Set(songs.map(\.id)))
                downloads.queueAutomatic(songs)
            }
        } else {
            note(.album(id: album.id, songs: [], isStarred: false))
            var albums = downloads.smartAlbums
            let ids = albums.removeValue(forKey: album.id) ?? album.songs.map(\.id)
            downloads.setSmartAlbums(albums)
            dropFromBatch(Set(ids))
            removeUnwanted(among: Set(ids))
        }
    }

    /// A downloaded playlist's page brought a changed list.
    func playlistChanged(songs: [Song], old: [Song]) {
        guard isEnabled, playlistReads == 0 else { return }
        downloads.queueAutomatic(songs)
        let gone = Set(old.map(\.id)).subtracting(songs.map(\.id))
        dropFromBatch(gone)
        removeUnwanted(among: gone)
    }

    private func songStarChanged(_ song: Song, isStarred: Bool) {
        guard isEnabled else { return }
        note(.song(song, isStarred: isStarred))
        if isStarred {
            starredSongIDs?.insert(song.id)
            downloads.forgetRemovals([song.id])
            downloads.queueAutomatic([song])
        } else {
            starredSongIDs?.remove(song.id)
            guard !albumSongIDs.contains(song.id) else { return }
            dropFromBatch([song.id])
            removeUnwanted(among: [song.id])
        }
    }

    private func note(_ change: SmartDownloadLogic.StarChange) {
        if catchUpTask != nil { changesDuringRead.append(change) }
    }

    // MARK: The catch-up

    private func catchUp(minimumGap: TimeInterval) {
        guard isEnabled, catchUpTask == nil, let client = downloads.activeClient else { return }
        let profileID = downloads.profileID
        if let last = lastCatchUp, last.profileID == profileID, Date.now.timeIntervalSince(last.at) < minimumGap { return }
        lastCatchUp = (profileID, .now)
        catchUpGeneration += 1
        let generation = catchUpGeneration
        changesDuringRead = []
        catchUpTask = Task {
            let found = try? await find(client: client, profileID: profileID)
            guard generation == catchUpGeneration else { return }
            catchUpTask = nil
            let changes = changesDuringRead
            changesDuringRead = []
            // Switched off or to another server meanwhile: what it found isn't for these records.
            guard isEnabled, !Task.isCancelled, downloads.profileID == profileID else { return }
            guard let found else {
                // The server didn't answer: the next connection or return tries again, not in 15 minutes.
                lastCatchUp = nil
                return
            }
            apply(SmartDownloadLogic.applying(changes, to: found))
        }
    }

    /// Everything the switch wants, from the server: favourite songs and albums (each album asked for
    /// only if its songs aren't all here, one after another), and the downloaded playlists as they are
    /// now (their saved lists brought up to date). Throws if the favourites can't be read, or if the
    /// server in use changed meanwhile (`profileID` is the one it reads for).
    private func find(client: SubsonicClient, profileID: String?) async throws -> Found {
        let starred = try await client.starred()
        var found = Found(songs: starred.songs, starredSongIDs: Set(starred.songs.map(\.id)))
        let known = downloads.smartAlbums
        let toFetch = Set(SmartDownloadLogic.albumsToFetch(
            starred: starred.albums, known: known, downloaded: downloads.downloadedIDs
        ).map(\.id))
        for album in starred.albums {
            try Task.checkCancellation()
            if toFetch.contains(album.id), let full = try? await client.album(id: album.id) {
                found.albums[album.id] = full.songs.map(\.id)
                found.songs += full.songs
            } else if let ids = known[album.id] {
                // All here, or the server didn't answer: as last known. An album never fetched had no
                // song downloaded for it, so nothing of it is at stake.
                found.albums[album.id] = ids
            }
        }
        playlistReads += 1
        defer { playlistReads -= 1 }
        for playlist in downloads.downloadedPlaylists {
            try Task.checkCancellation()
            let fresh = try? await client.playlist(id: playlist.id)
            // Another server's records are loaded by now: its playlists aren't this read's to touch.
            guard downloads.profileID == profileID else { throw CancellationError() }
            let songs = fresh.map { $0.songs ?? [] } ?? playlist.songs ?? []
            if fresh != nil { downloads.refresh(collectionID: playlist.id, songs: songs) }
            found.songs += songs
            found.playlistSongIDs.formUnion(songs.map(\.id))
        }
        return found
    }

    private func apply(_ found: Found) {
        // An answer with no favourite songs at all removes nothing the first time it's seen (the
        // check's C10); what it lists still downloads.
        mayRemove = SmartDownloadLogic.confirmsRemoval(starredSongIDs: found.starredSongIDs, previous: starredSongIDs)
        starredSongIDs = found.starredSongIDs
        downloads.setSmartAlbums(found.albums)
        // A download removed by hand stays away only while it's still wanted here.
        downloads.keepRemovals(among: found.wantedIDs)
        downloads.queueAutomatic(found.songs, replacing: true)
        removeUnwanted(among: nil)
    }

    // MARK: Removing

    private var albumSongIDs: Set<String> { Set(downloads.smartAlbums.values.flatMap { $0 }) }

    /// Songs no longer wanted leave the batch before they download.
    private func dropFromBatch(_ ids: Set<String>) {
        guard !ids.isEmpty, let queued = downloads.records.collections[SmartDownloadLogic.batchID]?.songs else { return }
        let kept = queued.filter { !ids.contains($0.id) || wanted.contains($0.id) }
        if kept.count != queued.count { downloads.queueAutomatic(kept, replacing: true) }
    }

    private var wanted: Set<String> { (starredSongIDs ?? []).union(albumSongIDs) }

    /// Removes what Smart Downloads fetched and nothing wants (only once this server's favourites
    /// are known); the song playing waits until it stops.
    private func removeUnwanted(among candidates: Set<String>?) {
        guard mayRemove, starredSongIDs != nil else { return }
        var ids = SmartDownloadLogic.removable(
            records: downloads.records, wanted: wanted, isEnabled: isEnabled, candidates: candidates
        )
        pendingRemovals.subtract(candidates ?? ids)
        if let current = currentSongID(), ids.remove(current) != nil { pendingRemovals.insert(current) }
        downloads.removeAutomatic(ids)
    }
}
