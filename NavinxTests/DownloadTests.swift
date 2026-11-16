import DeviceIdentity
import Foundation
import Lyrics
import PlaybackKit
import Synchronization
import SubsonicKit
import Testing
@testable import Navinx

/// Writes a file of the asked size for each song (by its `id`), fails the ones it's told to, and
/// can hold every download until released, to see the queue mid-way.
private final class FakeDownloads: DownloadTransport {
    struct State {
        var requests: [String] = []
        /// The same, with the address's host first.
        var hostedRequests: [String] = []
        var failing: [String: Int] = [:]
        var running = 0
        var mostAtOnce = 0
        var isHeld = false
        var areCoversHeld = false
        /// What a cover's answer is (a picture unless told otherwise).
        var coverBody = FakeDownloads.picture
        var cancelledFolders: [URL] = []
        var unclaimedCancels = 0
    }

    /// A 1×1 PNG.
    static let picture = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")!

    let state = Mutex(State())
    let size: Int

    init(size: Int = 70_000) { self.size = size }

    /// Fails `id`'s next `times` downloads.
    func fail(_ id: String, times: Int = 99) { state.withLock { $0.failing[id] = times } }
    func hold(_ held: Bool) { state.withLock { $0.isHeld = held } }
    /// Holds only the covers: a song's audio is on disk, and its cover not yet.
    func holdCovers(_ held: Bool) { state.withLock { $0.areCoversHeld = held } }
    var requests: [String] { state.withLock { $0.requests } }
    var hostedRequests: [String] { state.withLock { $0.hostedRequests } }
    var mostAtOnce: Int { state.withLock { $0.mostAtOnce } }
    var cancelledFolders: [URL] { state.withLock { $0.cancelledFolders } }
    var unclaimedCancels: Int { state.withLock { $0.unclaimedCancels } }
    /// A server's error, as Subsonic sends it: HTTP 200 with a JSON body.
    func answerCoversWithAnError() {
        state.withLock { $0.coverBody = Data(#"{"subsonic-response":{"status":"failed","error":{"code":70}}}"#.utf8) }
    }

    func cancelTasks(under folder: URL) { state.withLock { $0.cancelledFolders.append(folder) } }
    func cancelUnclaimedLeftovers() { state.withLock { $0.unclaimedCancels += 1 } }

    func download(from url: URL, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "id" }?.value ?? ""
        let endpoint = url.lastPathComponent
        let fails = state.withLock { state -> Bool in
            state.requests.append("\(endpoint):\(id)")
            state.hostedRequests.append("\(url.host() ?? ""):\(endpoint):\(id)")
            state.running += 1
            state.mostAtOnce = max(state.mostAtOnce, state.running)
            guard let left = state.failing[id], left > 0, endpoint == "download" else { return false }
            state.failing[id] = left - 1
            return true
        }
        defer { state.withLock { $0.running -= 1 } }
        while state.withLock({ $0.isHeld || ($0.areCoversHeld && endpoint == "getCoverArt") }) {
            try await Task.sleep(for: .milliseconds(5))
        }
        try await Task.sleep(for: .milliseconds(5))
        try Task.checkCancellation()
        if fails { throw URLError(.networkConnectionLost) }
        progress(1)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let coverBody = state.withLock { $0.coverBody }
        try (endpoint == "download" ? Data(count: size) : coverBody).write(to: destination)
    }
}

@MainActor
private struct DownloadRig {
    let model: DownloadModel
    let transport: FakeDownloads
    let root: URL
    let defaults: UserDefaults
    var messages: [String] { messageLog.items }
    private let messageLog = MessageLog()

    final class MessageLog {
        var items: [String] = []
    }

    init(root: URL? = nil, transport: FakeDownloads = FakeDownloads(), defaults: UserDefaults? = nil, online: Bool = true) throws {
        self.root = root ?? FileManager.default.temporaryDirectory.appending(path: "DownloadTests-\(UUID().uuidString)")
        self.transport = transport
        self.defaults = defaults ?? UserDefaults(suiteName: "DownloadTests.\(UUID().uuidString)")!
        // Its own covers list: `OfflineCovers.shared` is the whole process's, and other suites use it.
        model = DownloadModel(transport: transport, root: self.root, defaults: self.defaults, offlineCovers: OfflineCovers()) { song, _ in
            [LyricLine(text: "words of \(song.id)", start: 1)]
        }
        let log = messageLog
        model.onMessage = { log.items.append($0) }
        model.activate(profileID: "server", client: online ? try Self.client() : nil)
    }

    static func client(at address: String? = nil) throws -> SubsonicClient {
        try SubsonicClient(
            config: ServerConfig(serverURL: "http://music.invalid:4533", username: "u", password: "p"),
            baseURL: address.flatMap(URL.init(string:)),
            coverArtSalt: "salt"
        )
    }

    func waitUntilIdle() async {
        for _ in 0..<400 {
            if model.running == nil, model.records.queue.allSatisfy(model.failedThisRun.contains), model.songProgress.isEmpty {
                try? await Task.sleep(for: .milliseconds(20))
                if model.running == nil, model.songProgress.isEmpty { return }
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Until `condition` holds, up to 10 s: a fixed pause looked too early when the whole target ran.
    func wait(until condition: () -> Bool) async {
        for _ in 0..<1000 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    }
}

private func song(_ id: String, album: String = "al", size: Int? = nil) -> Song {
    var song = Song(id: id, title: "Song \(id)", album: "Album \(album)", albumID: album, artist: "Band", artistID: "ar", coverArt: "cover-\(album)", duration: 100)
    song.size = size
    song.suffix = "flac"
    return song
}

private func album(_ id: String, _ songs: [Song]) -> Album {
    Album(id: id, name: "Album \(id)", artist: "Band", artistID: "ar", coverArt: "al-\(id)", songCount: songs.count, songs: songs)
}

@MainActor
@Suite struct DownloadModelTests {
    @Test func anAlbumDownloadsWithCoversAndLyricsAndSurvivesARestart() async throws {
        let rig = try DownloadRig()
        let songs = [song("1"), song("2")]
        #expect(rig.model.download(album: album("al", songs), songs: songs) == 2)
        #expect(rig.model.state(of: "al").isActive)
        await rig.waitUntilIdle()
        #expect(rig.model.state(of: "al") == .downloaded)
        #expect(rig.model.downloadedIDs == ["1", "2"])
        #expect(rig.model.savedLyrics(songID: "1") == [LyricLine(text: "words of 1", start: 1)])
        #expect(rig.model.localFile(for: songs[0])?.lastPathComponent == "1.flac")
        // The album's own cover, and the songs' (shared) cover, once each.
        #expect(rig.transport.requests.filter { $0.hasPrefix("getCoverArt") }.sorted() == ["getCoverArt:al-al", "getCoverArt:cover-al"])
        #expect(rig.model.records.covers == ["al-al", "cover-al"])

        rig.model.saveNow()
        let again = try DownloadRig(root: rig.root)
        #expect(again.model.downloadedIDs == ["1", "2"])
        #expect(again.model.state(of: "al") == .downloaded)
        #expect(again.model.album(id: "al")?.songs.map(\.id) == ["1", "2"])
        #expect(again.transport.requests.isEmpty)
    }

    @Test func collectionsGoOneAtATimeInOrderAndSkipWhatsThere() async throws {
        let rig = try DownloadRig()
        rig.model.download(album: album("a", [song("1", album: "a")]), songs: [song("1", album: "a")])
        await rig.waitUntilIdle()
        rig.transport.hold(true)
        let first = [song("1", album: "a"), song("2", album: "a")]
        let second = [song("3", album: "b")]
        rig.model.download(playlist: Playlist(id: "p", name: "List"), songs: first)
        rig.model.download(album: album("b", second), songs: second)
        await rig.wait { rig.model.state(of: "p") == .downloading }
        #expect(rig.model.state(of: "p") == .downloading)
        #expect(rig.model.state(of: "b") == .queued)
        rig.transport.hold(false)
        await rig.waitUntilIdle()
        let songRequests = rig.transport.requests.filter { $0.hasPrefix("download") }
        #expect(songRequests == ["download:1", "download:2", "download:3"])
        #expect(rig.model.state(of: "p") == .downloaded)
        #expect(rig.model.state(of: "b") == .downloaded)
    }

    /// C46 (D163): Smart Downloads' batch gives way between songs, and takes up again afterwards.
    @Test func theUsersOwnDownloadGoesBeforeTheRestOfTheSmartBatch() async throws {
        let rig = try DownloadRig()
        rig.model.allowsAutomatic = { true }
        rig.defaults.set(1, forKey: DownloadModel.parallelKey)
        rig.transport.hold(true)
        rig.model.queueAutomatic((1...4).map { song("s\($0)") })
        for _ in 0..<200 where !rig.transport.requests.contains("download:s1") { try await Task.sleep(for: .milliseconds(5)) }
        let own = [song("own", album: "b")]
        rig.model.download(album: album("b", own), songs: own)
        #expect(rig.model.state(of: "b") == .queued)
        rig.transport.hold(false)
        await rig.waitUntilIdle()
        let order = rig.transport.requests.filter { $0.hasPrefix("download") }
        #expect(order == ["download:s1", "download:own", "download:s2", "download:s3", "download:s4"])
        #expect(rig.model.state(of: "b") == .downloaded)
        #expect(rig.model.isAutomatic("s4") && !rig.model.isAutomatic("own"))
        #expect(rig.model.records.queue.isEmpty)
    }

    /// C47 (the check's C2): "tap to remove" on what Smart Downloads fetched removes it, and it stays
    /// away until it's favourited or downloaded again.
    @Test func removingWhatSmartDownloadsFetchedRemovesItAndKeepsItAway() async throws {
        let rig = try DownloadRig()
        rig.model.allowsAutomatic = { true }
        rig.model.keepsAutomatic = { true }
        let songs = [song("1", album: "a"), song("2", album: "a")]
        rig.model.queueAutomatic(songs)
        await rig.waitUntilIdle()
        #expect(rig.model.state(of: "a", songs: songs) == .downloaded && rig.model.isAutomatic("1"))
        rig.model.remove(collectionID: "a", songs: songs)
        #expect(rig.model.downloadedIDs.isEmpty)
        // The next catch-up wants them again: nothing is queued.
        rig.model.queueAutomatic(songs, replacing: true)
        await rig.waitUntilIdle()
        #expect(rig.model.downloadedIDs.isEmpty && rig.model.records.queue.isEmpty)
        // Favourited again: that one comes back. Downloaded by hand: all of them, as the user's own.
        rig.model.forgetRemovals(["1"])
        rig.model.queueAutomatic(songs, replacing: true)
        await rig.waitUntilIdle()
        #expect(rig.model.downloadedIDs == ["1"])
        rig.model.download(album: album("a", songs), songs: songs)
        await rig.waitUntilIdle()
        #expect(rig.model.downloadedIDs == ["1", "2"])
        #expect(!rig.model.isAutomatic("1") && rig.model.records.removedByHand.isEmpty)
    }

    /// A deleted playlist is no request to remove a favourite: Smart Downloads' songs in it stay.
    @Test func aDeletedPlaylistLeavesSmartDownloadsSongsToTheCatchUp() async throws {
        let rig = try DownloadRig()
        rig.model.allowsAutomatic = { true }
        rig.model.keepsAutomatic = { true }
        rig.model.queueAutomatic([song("fav")])
        await rig.waitUntilIdle()
        rig.model.download(batch: "b", name: "B", songs: [song("own")])
        await rig.waitUntilIdle()
        #expect(rig.model.downloadedIDs == ["fav", "own"])
        rig.model.remove(collectionID: "list", songs: [song("fav"), song("own")], leavingSmartSongs: true)
        #expect(rig.model.downloadedIDs == ["fav"] && rig.model.records.removedByHand.isEmpty)
    }

    /// C47 (the check's C7): asked for by hand, a song Smart Downloads fetched is the user's.
    @Test func downloadAllMakesSmartDownloadsSongsTheUsers() async throws {
        let rig = try DownloadRig()
        rig.model.allowsAutomatic = { true }
        rig.model.queueAutomatic([song("1")])
        await rig.waitUntilIdle()
        #expect(rig.model.isAutomatic("1"))
        #expect(rig.model.download(batch: "favorites", name: "Favorites", songs: [song("1")]) == 0)
        #expect(!rig.model.isAutomatic("1"))
    }

    @Test func atMostTheParallelLimitAtOnce() async throws {
        let rig = try DownloadRig()
        rig.defaults.set(2, forKey: DownloadModel.parallelKey)
        let songs = (1...6).map { song("\($0)") }
        rig.model.download(album: album("al", songs), songs: songs)
        await rig.waitUntilIdle()
        #expect(rig.model.downloadedIDs.count == 6)
        // Two songs, plus perhaps a cover alongside.
        #expect(rig.transport.mostAtOnce <= 3)
    }

    @Test func aFailedSongIsTriedOnceMoreAtTheEnd() async throws {
        let rig = try DownloadRig()
        rig.transport.fail("2", times: 1)
        let songs = [song("1"), song("2"), song("3")]
        rig.model.download(album: album("al", songs), songs: songs)
        await rig.waitUntilIdle()
        #expect(rig.model.state(of: "al") == .downloaded)
        #expect(rig.transport.requests.filter { $0 == "download:2" }.count == 2)
        #expect(rig.messages.isEmpty)
    }

    @Test func anIncompleteCollectionSaysSoAndTriesAgainNextLaunch() async throws {
        let rig = try DownloadRig()
        rig.transport.fail("2")
        let songs = [song("1"), song("2")]
        rig.model.download(album: album("al", songs), songs: songs)
        await rig.waitUntilIdle()
        #expect(rig.messages == ["Download failed"])
        #expect(rig.model.state(of: "al") == .none)
        #expect(rig.model.downloadedIDs == ["1"])
        #expect(rig.transport.requests.filter { $0 == "download:2" }.count == 2)
        rig.model.saveNow()

        let transport = FakeDownloads()
        let again = try DownloadRig(root: rig.root, transport: transport)
        await again.waitUntilIdle()
        #expect(transport.requests.filter { $0.hasPrefix("download") } == ["download:2"])
        #expect(again.model.state(of: "al") == .downloaded)
    }

    @Test func theSizeCheck() async throws {
        let small = FakeDownloads(size: 1000)
        let rig = try DownloadRig(transport: small)
        // Smaller than the server's size, or than 64 KB without one: not downloaded.
        let songs = [song("1", size: 900), song("2", size: 2000), song("3")]
        rig.model.download(album: album("al", songs), songs: songs)
        await rig.waitUntilIdle()
        #expect(rig.model.downloadedIDs == ["1"])
    }

    @Test func aMissingFileMeansNotDownloaded() async throws {
        let rig = try DownloadRig()
        let songs = [song("1"), song("2")]
        rig.model.download(album: album("al", songs), songs: songs)
        await rig.waitUntilIdle()
        rig.model.saveNow()
        let file = try #require(rig.model.localFile(for: songs[0]))
        try FileManager.default.removeItem(at: file)
        // The player streams it instead.
        #expect(rig.model.localFile(for: songs[0]) == nil)

        let again = try DownloadRig(root: rig.root, online: false)
        #expect(again.model.downloadedIDs == ["2"])
        #expect(again.model.state(of: "al") == .none)
    }

    @Test func cancelStopsTheRunningCollectionAndKeepsWhatsDone() async throws {
        let rig = try DownloadRig()
        let songs = (1...6).map { song("\($0)") }
        rig.defaults.set(1, forKey: DownloadModel.parallelKey)
        rig.model.download(album: album("al", songs), songs: songs)
        for _ in 0..<200 where rig.model.downloadedIDs.count < 2 { try await Task.sleep(for: .milliseconds(5)) }
        rig.transport.hold(true)
        try await Task.sleep(for: .milliseconds(20))
        rig.model.cancel("al")
        rig.transport.hold(false)
        await rig.waitUntilIdle()
        let kept = rig.model.downloadedIDs.count
        #expect(kept >= 2 && kept < 6)
        #expect(rig.model.state(of: "al") == .none)
        #expect(rig.model.records.queue.isEmpty)
        try await Task.sleep(for: .milliseconds(100))
        #expect(rig.model.downloadedIDs.count == kept)
    }

    /// Flutter deleted shared songs, leaving another collection green over missing files.
    @Test func removingKeepsSongsAnotherCollectionNeeds() async throws {
        let rig = try DownloadRig()
        let albumSongs = [song("1"), song("2")]
        let listSongs = [song("2"), song("9", album: "other")]
        rig.model.download(album: album("al", albumSongs), songs: albumSongs)
        rig.model.download(playlist: Playlist(id: "p", name: "List"), songs: listSongs)
        await rig.waitUntilIdle()
        #expect(rig.model.state(of: "al") == .downloaded && rig.model.state(of: "p") == .downloaded)

        rig.model.remove(collectionID: "al", songs: albumSongs)
        #expect(rig.model.downloadedIDs == ["2", "9"])
        #expect(rig.model.state(of: "al") == .none)
        #expect(rig.model.state(of: "p") == .downloaded)
    }

    /// Flutter's song removal left its album green.
    @Test func removingOneSongTakesAwayTheCollectionsMark() async throws {
        let rig = try DownloadRig()
        let songs = [song("1"), song("2")]
        rig.model.download(album: album("al", songs), songs: songs)
        await rig.waitUntilIdle()
        rig.model.removeSong("1")
        #expect(rig.model.state(of: "al") == .none)
        #expect(!rig.model.isAlbumDownloaded(album("al", songs)))
    }

    @Test func aSongAddedToAPlaylistLaterTakesAwayItsMark() async throws {
        let rig = try DownloadRig()
        rig.model.download(playlist: Playlist(id: "p", name: "List"), songs: [song("1")])
        await rig.waitUntilIdle()
        #expect(rig.model.state(of: "p") == .downloaded)
        rig.model.refresh(collectionID: "p", songs: [song("1"), song("2")])
        #expect(rig.model.state(of: "p") == .none)
    }

    @Test func aSingleSongDownloadsWithItsOwnMessage() async throws {
        let rig = try DownloadRig()
        rig.model.downloadSong(song("5"))
        #expect(rig.model.isSongDownloading("5"))
        await rig.waitUntilIdle()
        #expect(rig.model.isDownloaded("5"))
        #expect(rig.messages == ["Downloaded \"Song 5\""])

        rig.transport.fail("6")
        rig.model.downloadSong(song("6"))
        await rig.waitUntilIdle()
        #expect(rig.messages.last == "Download failed")
    }

    /// The audit's P1: the same server reached on another address. What's still to fetch (the queue's
    /// and a song menu's) goes again from the new address; what's here isn't fetched again.
    @Test func anotherAddressStartsWhatsUnderWayAgainOnIt() async throws {
        let rig = try DownloadRig()
        rig.model.downloadSong(song("1"))
        await rig.waitUntilIdle()
        rig.transport.hold(true)
        let songs = [song("1"), song("2")]
        rig.model.download(album: album("al", songs), songs: songs)
        rig.model.downloadSong(song("3"))
        // Both under way (the album's run is on its cover), so the count below is taken after them.
        await rig.wait { ["getCoverArt:al-al", "download:3"].allSatisfy(rig.transport.requests.contains) }
        // A new client on the same address changes nothing.
        let before = rig.transport.requests.count
        rig.model.activate(profileID: "server", client: try DownloadRig.client(), catchesUp: false)
        try await Task.sleep(for: .milliseconds(50))
        #expect(rig.transport.requests.count == before)

        rig.model.activate(profileID: "server", client: try DownloadRig.client(at: "http://away.invalid:4533"), catchesUp: false)
        try await Task.sleep(for: .milliseconds(50))
        rig.transport.hold(false)
        await rig.waitUntilIdle()
        #expect(rig.model.downloadedIDs == ["1", "2", "3"])
        let away = rig.transport.hostedRequests.filter { $0.hasPrefix("away.invalid:download") }
        #expect(Set(away) == ["away.invalid:download:2", "away.invalid:download:3"])
        #expect(rig.transport.requests.filter { $0 == "download:1" }.count == 1)
        #expect(rig.messages.last == "Downloaded \"Song 3\"")
        #expect(rig.model.records.queue.isEmpty)
        #expect(rig.model.records.collections[DownloadModel.songCollectionID("3")] == nil)
    }

    /// A song whose file was whole (its cover or lyrics still coming) when another address started it
    /// again kept its file: the run there takes it in without fetching it again.
    @Test func aWholeFileStaysWhenAnotherAddressStartsItsSongAgain() async throws {
        let rig = try DownloadRig()
        rig.transport.holdCovers(true)
        let songs = [song("1", album: "a1")]
        rig.model.download(album: Album(id: "al", name: "No Cover", songs: songs), songs: songs)
        rig.model.downloadSong(song("5", album: "a5"))
        // Both files are on disk; their covers are held.
        for _ in 0..<400 where rig.transport.requests.filter({ $0.hasPrefix("getCoverArt") }).count < 2 {
            try await Task.sleep(for: .milliseconds(5))
        }
        rig.model.activate(profileID: "server", client: try DownloadRig.client(at: "http://away.invalid:4533"), catchesUp: false)
        try await Task.sleep(for: .milliseconds(50))
        rig.transport.holdCovers(false)
        await rig.waitUntilIdle()
        #expect(rig.model.downloadedIDs == ["1", "5"])
        #expect(rig.transport.requests.filter { $0.hasPrefix("download") }.sorted() == ["download:1", "download:5"])
        #expect(rig.model.records.queue.isEmpty)
    }

    /// A song menu's download left queued (the app closed) that fails when the queue runs it at the
    /// next launch: one toast, and it's gone, not tried and told again at every launch.
    @Test func aRestoredSongDownloadThatFailsIsToldOnceAndDropped() async throws {
        let rig = try DownloadRig()
        rig.transport.hold(true)
        rig.model.downloadSong(song("7"))
        rig.model.activate(profileID: "another", client: nil)
        rig.transport.hold(false)

        let failing = FakeDownloads()
        failing.fail("7")
        let again = try DownloadRig(root: rig.root, transport: failing)
        await again.waitUntilIdle()
        #expect(again.messages == ["Download failed"])
        #expect(again.model.records.queue.isEmpty && again.model.records.collections.isEmpty)
        again.model.saveNow()

        let third = try DownloadRig(root: rig.root)
        await third.waitUntilIdle()
        #expect(third.messages.isEmpty)
        #expect(!third.transport.requests.contains("download:7"))
    }

    /// The audit's P2: a song menu's download is recorded when asked for, so the app closed before it
    /// ends doesn't lose it: the next launch keeps the file iOS finished and takes it in.
    @Test func aSongsOwnDownloadSurvivesTheAppClosing() async throws {
        let rig = try DownloadRig()
        rig.transport.hold(true)
        rig.model.downloadSong(song("5"))
        let store = DownloadStore(profileID: "server", root: rig.root)
        let saved = store.load()
        let id = DownloadModel.songCollectionID("5")
        #expect(saved.queue == [id] && saved.collections[id]?.songs.map(\.id) == ["5"])
        // The app goes; iOS finishes the download meanwhile.
        rig.model.activate(profileID: "another", client: nil)
        rig.transport.hold(false)
        try Data(count: 70_000).write(to: store.songFile("5.flac"))

        let again = try DownloadRig(root: rig.root)
        await again.waitUntilIdle()
        #expect(again.model.isDownloaded("5"))
        #expect(!again.transport.requests.contains("download:5"))
        #expect(again.model.records.queue.isEmpty && again.model.records.collections.isEmpty)
    }

    /// The audit's P4: the player hears of every removal, so a removed song lined up next is lined up again.
    @Test func removalsAreToldToThePlayer() async throws {
        let rig = try DownloadRig()
        final class Count { var value = 0 }
        let count = Count()
        rig.model.onFilesRemoved = { count.value += 1 }
        rig.model.download(album: album("al", [song("1"), song("2")]), songs: [song("1"), song("2")])
        await rig.waitUntilIdle()
        rig.model.removeSong("1")
        #expect(count.value == 1)
        rig.model.remove(collectionID: "al")
        #expect(count.value == 2)
        rig.model.removeAll()
        #expect(count.value == 3)
    }

    @Test func aBatchSkipsWhatsThereAndLeavesNoCollection() async throws {
        let rig = try DownloadRig()
        rig.model.downloadSong(song("1"))
        await rig.waitUntilIdle()
        #expect(rig.model.download(batch: "favorites", name: "Favorites", songs: [song("1"), song("2")]) == 1)
        await rig.waitUntilIdle()
        #expect(rig.model.downloadedIDs == ["1", "2"])
        #expect(rig.model.records.collections["favorites"] == nil)
        #expect(rig.model.download(batch: "favorites", name: "Favorites", songs: [song("1")]) == 0)
    }

    @Test func nothingDownloadsOfflineAndTheQueueWaits() async throws {
        let rig = try DownloadRig(online: false)
        rig.model.download(album: album("al", [song("1")]), songs: [song("1")])
        try await Task.sleep(for: .milliseconds(50))
        #expect(rig.transport.requests.isEmpty)
        #expect(rig.model.records.queue == ["al"])
        rig.model.activate(profileID: "server", client: try DownloadRig.client())
        await rig.waitUntilIdle()
        #expect(rig.model.state(of: "al") == .downloaded)
    }

    @Test func deleteAllAndLogout() async throws {
        let rig = try DownloadRig()
        rig.model.download(album: album("al", [song("1")]), songs: [song("1")])
        await rig.waitUntilIdle()
        rig.model.saveNow()
        #expect(DownloadModel.hasDownloads(profileID: "server", root: rig.root))
        rig.model.removeAll()
        #expect(rig.model.downloadedIDs.isEmpty)
        #expect(!DownloadModel.hasDownloads(profileID: "server", root: rig.root))
    }

    /// Two fetches of one song wrote the same file, and a failing one deleted the other's.
    @Test func aSongAskedForTwiceIsFetchedOnce() async throws {
        let rig = try DownloadRig()
        rig.transport.hold(true)
        rig.model.downloadSong(song("1"))
        // The song's own Download is fetching it before the queue asks for it too.
        await rig.wait { rig.transport.requests.contains("download:1") }
        rig.model.download(batch: "favorites", name: "Favorites", songs: [song("1"), song("2")])
        // The other way round: the queue is fetching song 2, then the song's own Download asks.
        await rig.wait { rig.transport.requests.contains("download:2") }
        rig.model.downloadSong(song("2"))
        #expect(rig.model.isSongDownloading("2"))
        try await Task.sleep(for: .milliseconds(50))
        #expect(rig.transport.requests.filter { $0 == "download:1" }.count == 1)
        #expect(rig.transport.requests.filter { $0 == "download:2" }.count == 1)
        rig.transport.hold(false)
        await rig.waitUntilIdle()
        try await Task.sleep(for: .milliseconds(50))
        #expect(rig.model.downloadedIDs == ["1", "2"])
        // Over the whole run, not only while held: each song fetched once.
        #expect(rig.transport.requests.filter { $0.hasPrefix("download") }.sorted() == ["download:1", "download:2"])
        #expect(Set(rig.messages) == ["Downloaded \"Song 1\"", "Downloaded \"Song 2\""])
        for id in ["1", "2"] {
            let file = try #require(rig.model.localFile(for: song(id)))
            #expect(FileManager.default.fileExists(atPath: file.path))
        }
    }

    /// A song past its audio (fetching its cover) when everything was deleted was still recorded.
    @Test func deleteAllWhileASongFinishesLeavesNothing() async throws {
        let rig = try DownloadRig()
        rig.transport.holdCovers(true)
        rig.model.downloadSong(song("1"))
        for _ in 0..<200 where !rig.transport.requests.contains("getCoverArt:cover-al") {
            try await Task.sleep(for: .milliseconds(5))
        }
        rig.model.removeAll()
        rig.transport.holdCovers(false)
        // Past the save's 300 ms.
        try await Task.sleep(for: .milliseconds(500))
        #expect(rig.model.downloadedIDs.isEmpty)
        #expect(!DownloadModel.hasDownloads(profileID: "server", root: rig.root))
        let file = DownloadStore(profileID: "server", root: rig.root).songFile("1.flac")
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(rig.messages.isEmpty)
    }

    @Test func aRecordThisBuildCantReadIsSkippedNotTheList() async throws {
        let rig = try DownloadRig()
        rig.model.download(album: album("al", [song("1")]), songs: [song("1")])
        await rig.waitUntilIdle()
        rig.model.saveNow()
        let store = DownloadStore(profileID: "server", root: rig.root)
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: store.recordsFile)) as? [String: Any])
        var collections = try #require(json["collections"] as? [String: Any])
        let future: [String: Any] = ["id": "future", "kind": "someNewKind", "name": "New", "songs": [Any]()]
        collections["future"] = future
        json["collections"] = collections
        json["queue"] = ["future"]
        try JSONSerialization.data(withJSONObject: json).write(to: store.recordsFile)

        let again = try DownloadRig(root: rig.root, online: false)
        #expect(again.model.downloadedIDs == ["1"])
        #expect(again.model.state(of: "al") == .downloaded)
        #expect(again.model.records.collections["future"] == nil)
    }

    @Test func anUnreadableListIsMovedAsideNotOverwritten() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "DownloadTests-\(UUID().uuidString)")
        let store = DownloadStore(profileID: "server", root: root)
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: store.recordsFile)
        #expect(store.load() == DownloadRecords())
        #expect(!FileManager.default.fileExists(atPath: store.recordsFile.path))
        let names = try FileManager.default.contentsOfDirectory(atPath: store.directory.path)
        let aside = try #require(names.first { $0.hasPrefix("records-unreadable-") })
        #expect(try Data(contentsOf: store.directory.appending(path: aside)) == Data("not json".utf8))
    }

    @Test func removingOrphansKeepsOnlyTheSavedServers() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "DownloadTests-\(UUID().uuidString)")
        // Nothing there yet: nothing happens.
        DownloadStore.removeOrphans(keeping: [], root: root)
        let kept = UUID().uuidString
        let gone = UUID().uuidString
        for id in [kept, gone] {
            try FileManager.default.createDirectory(at: DownloadStore(profileID: id, root: root).songsDirectory, withIntermediateDirectories: true)
        }
        DownloadStore.removeOrphans(keeping: [kept], root: root)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == [kept])
    }

    @Test func eachServerHasItsOwn() async throws {
        let rig = try DownloadRig()
        rig.model.download(album: album("al", [song("1")]), songs: [song("1")])
        await rig.waitUntilIdle()
        rig.model.activate(profileID: "another", client: nil)
        #expect(rig.model.downloadedIDs.isEmpty)
        rig.model.activate(profileID: "server", client: nil)
        #expect(rig.model.downloadedIDs == ["1"])
    }

    @Test func downloadsPageListsEveryAlbumAndSong() async throws {
        let rig = try DownloadRig()
        rig.model.downloadSong(song("1", album: "x"))
        await rig.waitUntilIdle()
        rig.model.download(playlist: Playlist(id: "p", name: "List"), songs: [song("2", album: "y")])
        await rig.waitUntilIdle()
        #expect(rig.model.downloadedAlbums.map(\.id) == ["x", "y"])
        #expect(rig.model.offlineSongs.map(\.id) == ["1", "2"])
        let snapshot = rig.model.offlineSnapshot()
        #expect(snapshot.allAlbums.map(\.id) == ["x", "y"])
        #expect(snapshot.playlists.map(\.id) == ["p"])
        #expect(snapshot.artists.map(\.id) == ["ar"])
    }

    /// A second Download All while the first ran was erased when the first ended.
    @Test func aSecondRequestWhileTheFirstRunsIsKept() async throws {
        let rig = try DownloadRig()
        rig.transport.hold(true)
        #expect(rig.model.download(batch: "favorites", name: "Favorites", songs: [song("1"), song("2")]) == 2)
        await rig.wait { rig.model.state(of: "favorites") == .downloading }
        #expect(rig.model.state(of: "favorites") == .downloading)
        #expect(rig.model.download(batch: "favorites", name: "Favorites", songs: [song("1"), song("2"), song("3")]) == 3)
        rig.transport.hold(false)
        await rig.waitUntilIdle()
        #expect(rig.model.downloadedIDs == ["1", "2", "3"])
        #expect(rig.model.records.collections["favorites"] == nil)
        #expect(rig.model.records.queue.isEmpty)
        #expect(rig.transport.requests.filter { $0.hasPrefix("download") }.count == 3)
        #expect(rig.messages.isEmpty)
    }

    /// A server's error that came with HTTP 200 was kept as the cover, and showed the placeholder for good.
    @Test func aCoverThatIsntAPictureIsntKept() async throws {
        let rig = try DownloadRig()
        rig.transport.answerCoversWithAnError()
        rig.model.download(album: album("al", [song("1")]), songs: [song("1")])
        await rig.waitUntilIdle()
        #expect(rig.model.isDownloaded("1"))
        #expect(rig.model.records.covers.isEmpty)
        let store = DownloadStore(profileID: "server", root: rig.root)
        #expect(!FileManager.default.fileExists(atPath: store.coverFile("al-al").path))

        // One an earlier build kept is dropped at the next activation, and fetched again.
        rig.model.saveNow()
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: store.recordsFile)) as? [String: Any])
        json["covers"] = ["al-al"]
        try JSONSerialization.data(withJSONObject: json).write(to: store.recordsFile)
        try Data("<html>portal</html>".utf8).write(to: store.coverFile("al-al"))
        let again = try DownloadRig(root: rig.root)
        for _ in 0..<200 where !again.transport.requests.contains("getCoverArt:al-al") || !again.model.records.covers.contains("al-al") {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(again.transport.requests == ["getCoverArt:al-al"])
        #expect(again.model.records.covers == ["al-al"])
        #expect(ArtworkCache.isImage(at: store.coverFile("al-al")))
    }

    /// Song files with no record (iOS finished them after the app had gone) were invisible, unplayable
    /// and counted only in Delete All's size.
    @Test func songFilesWithNoRecordAreTakenInOrDeleted() async throws {
        let rig = try DownloadRig()
        rig.model.download(playlist: Playlist(id: "p", name: "List"), songs: [song("1")])
        await rig.waitUntilIdle()
        // The playlist now has a song 2 (not downloaded), and a song 3 is queued in another.
        rig.model.refresh(collectionID: "p", songs: [song("1"), song("2")])
        rig.transport.hold(true)
        rig.model.download(album: album("b", [song("3", album: "b")]), songs: [song("3", album: "b")])
        rig.model.saveNow()
        let store = DownloadStore(profileID: "server", root: rig.root)
        for name in ["2.flac", "3.flac", "9.flac"] {
            try Data(count: 70_000).write(to: store.songFile(name))
        }

        let again = try DownloadRig(root: rig.root, online: false)
        // Song 2's details are in its playlist; song 3's queued album takes its own file when it runs.
        #expect(again.model.downloadedIDs == ["1", "2"])
        #expect(again.model.localFile(for: song("2"))?.lastPathComponent == "2.flac")
        #expect(FileManager.default.fileExists(atPath: store.songFile("3.flac").path))
        // Nothing has song 9's details: it goes.
        #expect(!FileManager.default.fileExists(atPath: store.songFile("9.flac").path))
        rig.transport.hold(false)
    }

    /// Tasks left from an earlier run went on after Delete All or logout, and brought the files back.
    @Test func deleteAllAndLogoutStopTheTasksForThatServer() async throws {
        let rig = try DownloadRig()
        let folder = DownloadStore(profileID: "server", root: rig.root).directory
        rig.model.removeAll()
        #expect(rig.transport.cancelledFolders == [folder])
        let other = FakeDownloads()
        DownloadModel.removeDownloads(profileID: "other", root: rig.root, transport: other)
        #expect(other.cancelledFolders == [DownloadStore(profileID: "other", root: rig.root).directory])
    }

    /// What an earlier run left and nothing asked for since would land with no record.
    @Test func leftoversNobodyClaimsAreStoppedOnceTheQueueHasRun() async throws {
        let rig = try DownloadRig()
        // Nothing queued at activation: at once.
        #expect(rig.transport.unclaimedCancels == 1)
        rig.model.download(album: album("al", [song("1")]), songs: [song("1")])
        await rig.waitUntilIdle()
        for _ in 0..<100 where rig.transport.unclaimedCancels < 2 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(rig.transport.unclaimedCancels == 2)
        // Offline, nothing is stopped.
        let offline = try DownloadRig(online: false)
        #expect(offline.transport.unclaimedCancels == 0)
    }

    @Test func fileNamesKeepTheSongsOwnExtension() {
        var plain = Song(id: "a/b", title: "x")
        #expect(DownloadStore.fileName(for: plain) == "a_b.mp3")
        plain.suffix = "M4A"
        #expect(DownloadStore.fileName(for: plain) == "a_b.m4a")
    }
}

@Suite struct OfflineLogicTests {
    private func s(_ id: String, _ title: String, artist: String? = nil, album: String? = nil) -> Song {
        Song(id: id, title: title, album: album, artist: artist)
    }

    @Test func searchMatchesTitleArtistOrAlbumUpToFifty() {
        let songs = [s("1", "Hello", artist: "Band"), s("2", "Other", artist: "hello there"), s("3", "x", album: "Say HELLO"), s("4", "nope")]
        #expect(OfflineLogic.search(songs, query: " hello ").map(\.id) == ["1", "2", "3"])
        #expect(OfflineLogic.search(songs, query: "").isEmpty)
        let many = (0..<80).map { s("\($0)", "Song") }
        #expect(OfflineLogic.search(many, query: "song").count == 50)
    }

    @Test func homeKeepsOnlyWhatsDownloaded() {
        let feed = HomeFeed(
            mixes: [SongMix(name: "Mix", songs: [s("1", "a"), s("2", "b")]), SongMix(name: "Gone", songs: [s("3", "c")])],
            personalized: [s("1", "a"), s("3", "c")],
            replayPicks: [s("3", "c")],
            heavyRotation: [s("2", "b")]
        )
        let home = OfflineLogic.home(
            latestAlbums: [Album(id: "a1", name: "A"), Album(id: "a2", name: "B")],
            playlists: [Playlist(id: "p1", name: "P"), Playlist(id: "p2", name: "Q")],
            feed: feed,
            downloadedIDs: ["1", "2"],
            downloadedAlbumIDs: ["a2"],
            isPlaylistDownloaded: { $0.id == "p1" }
        )
        #expect(home.latestAlbums.map(\.id) == ["a2"])
        #expect(home.playlists.map(\.id) == ["p1"])
        #expect(home.feed.mixes.map(\.name) == ["Mix"])
        #expect(home.feed.personalized.map(\.id) == ["1"])
        #expect(home.feed.replayPicks.isEmpty)
        #expect(home.feed.heavyRotation.map(\.id) == ["2"])
    }

    @Test func aTappedListKeepsOnlyPlayableSongs() {
        let list = [s("1", "a"), s("2", "b"), s("3", "c")]
        let result = OfflineLogic.playable(list, tapped: 2, isDownloaded: { $0 != "2" })
        #expect(result.songs.map(\.id) == ["1", "3"])
        #expect(result.index == 1)
    }

    @Test func anOfflineAlbumShowsEverySongTheLibraryKnows() {
        var one = Song(id: "1", title: "a", albumID: "al")
        one.track = 2
        var two = Song(id: "2", title: "b", albumID: "al")
        two.track = 1
        let downloaded = Album(id: "al", name: "Al", songs: [one])
        let album = OfflineLogic.album(id: "al", downloaded: downloaded, isComplete: false, libraryAlbums: [Album(id: "al", name: "Al")], librarySongs: [one, two])
        #expect(album?.songs.map(\.id) == ["2", "1"])
        // A downloaded album's record is the whole album.
        let whole = OfflineLogic.album(id: "al", downloaded: downloaded, isComplete: true, libraryAlbums: [], librarySongs: [one, two])
        #expect(whole?.songs.map(\.id) == ["1"])
        #expect(OfflineLogic.album(id: "zz", downloaded: nil, isComplete: false, libraryAlbums: [], librarySongs: []) == nil)
    }

    @Test func libraryDownloadedRowCountsTheDownloads() {
        let rows = LibraryEntries.build(sort: .recents, source: .init(downloadedCount: 2))
        #expect(rows.map(\.id) == ["heartedSongs", "offlineSongs"])
        #expect(rows[1].subtitle == "2 songs saved offline")
    }
}

/// A server's favourite songs, as Smart Downloads read them (`getStarred2`); held on demand.
private final class StarredStub: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var songIDs: [String]
    private var isHeld = false
    private var calls = 0

    init(songs: [String]) { songIDs = songs }

    func hold(_ held: Bool) { lock.withLock { isHeld = held } }
    func star(_ ids: [String]) { lock.withLock { songIDs = ids } }
    var starredCalls: Int { lock.withLock { calls } }

    func get(_ url: URL, timeout: TimeInterval) async throws -> (Data, HTTPURLResponse) {
        var payload = ""
        if url.lastPathComponent == "getStarred2" {
            lock.withLock { calls += 1 }
            while lock.withLock({ isHeld }) { try await Task.sleep(for: .milliseconds(5)) }
            let songs = lock.withLock { songIDs }.map { #"{"id":"\#($0)","title":"Song \#($0)"}"# }.joined(separator: ",")
            payload = #","starred2":{"song":[\#(songs)]}"#
        }
        let body = #"{"subsonic-response":{"status":"ok","version":"1.16.1"\#(payload)}}"#
        return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

/// C47 (D164, the check's C3, C4 and C5): Smart Downloads against a server's favourites.
@MainActor
@Suite struct SmartDownloadsServerTests {
    /// Smart Downloads wired to the rig's downloads as the app wires them, on Wi-Fi.
    private func smartDownloads(_ rig: DownloadRig, answers: [String: Bool]) -> SmartDownloads {
        rig.defaults.set(answers, forKey: SmartDownloads.answersKey)
        let smart = SmartDownloads(downloads: rig.model, defaults: rig.defaults)
        smart.allowsNetwork = { true }
        rig.model.allowsAutomatic = { smart.mayDownload }
        rig.model.keepsAutomatic = { smart.isEnabled }
        rig.model.onConnect = { smart.connected() }
        rig.model.onProfileChange = { smart.serverChanged() }
        return smart
    }

    private func client(_ stub: StarredStub) throws -> SubsonicClient {
        try SubsonicClient(
            config: ServerConfig(serverURL: "http://music.invalid:4533", username: "u", password: "p"),
            coverArtSalt: "salt", transport: stub
        )
    }

    private func wait(_ condition: () -> Bool) async {
        for _ in 0..<400 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func aServerNotAnsweredForIsAskedAndDownloadsNothingUntilThen() async throws {
        let rig = try DownloadRig()
        let smart = smartDownloads(rig, answers: ["server": true])
        #expect(smart.isEnabled)
        // A server added later: its favourites wait for the answer.
        rig.model.activate(profileID: "added", client: try client(StarredStub(songs: ["a", "b"])))
        #expect(!smart.isEnabled)
        await wait { smart.question != nil }
        let plan = try #require(smart.question)
        #expect(plan.songCount == 2)
        #expect(rig.model.records.queue.isEmpty && rig.model.downloadedIDs.isEmpty)
        // "Not Now": off for this server only, and it isn't asked again.
        smart.decline(plan)
        #expect(smart.question == nil && !smart.isEnabled)
        #expect(rig.defaults.dictionary(forKey: SmartDownloads.answersKey) as? [String: Bool] == ["server": true, "added": false])
        rig.model.activate(profileID: "added", client: try client(StarredStub(songs: ["a", "b"])))
        try await Task.sleep(for: .milliseconds(150))
        #expect(smart.question == nil && rig.model.records.queue.isEmpty && rig.model.downloadedIDs.isEmpty)
    }

    @Test func turningItOnForTheNewServerReadsItsFavouritesAgain() async throws {
        let rig = try DownloadRig()
        let smart = smartDownloads(rig, answers: ["server": true])
        let stub = StarredStub(songs: ["a", "b"])
        rig.model.activate(profileID: "added", client: try client(stub))
        await wait { smart.question != nil }
        let plan = try #require(smart.question)
        // A song favourited elsewhere while the question stood open is in what "Turn On" downloads.
        stub.star(["a", "b", "c"])
        smart.turnOn(with: plan)
        #expect(smart.isEnabled && smart.question == nil)
        await wait { rig.model.downloadedIDs == ["a", "b", "c"] }
        #expect(rig.model.downloadedIDs == ["a", "b", "c"] && rig.model.isAutomatic("c"))
    }

    @Test func aBuildBeforeTheQuestionPerServerKeepsItsSwitchForTheServerInUse() throws {
        let rig = try DownloadRig()
        rig.defaults.set(true, forKey: SmartDownloads.enabledKey)
        let smart = SmartDownloads(downloads: rig.model, defaults: rig.defaults)
        #expect(smart.isEnabled)
        #expect(rig.defaults.dictionary(forKey: SmartDownloads.answersKey) as? [String: Bool] == ["server": true])
    }

    @Test func switchingServerDropsTheOldCatchUpAndRunsTheNewOnes() async throws {
        let rig = try DownloadRig()
        let smart = smartDownloads(rig, answers: ["server": true, "other": true])
        let old = StarredStub(songs: ["old1"])
        old.hold(true)
        // The first server's catch-up is still asking when the user switches.
        rig.model.activate(profileID: "server", client: try client(old))
        await wait { old.starredCalls > 0 }
        rig.model.activate(profileID: "other", client: try client(StarredStub(songs: ["new1"])))
        #expect(smart.isEnabled)
        old.hold(false)
        await wait { rig.model.downloadedIDs == ["new1"] }
        try await Task.sleep(for: .milliseconds(100))
        #expect(rig.model.downloadedIDs == ["new1"] && rig.model.isAutomatic("new1"))
    }

    @Test func aSongFavouritedWhileTheCatchUpReadsStaysDownloaded() async throws {
        let rig = try DownloadRig()
        let smart = smartDownloads(rig, answers: ["server": true])
        let stub = StarredStub(songs: ["s1"])
        stub.hold(true)
        rig.model.activate(profileID: "server", client: try client(stub))
        await wait { stub.starredCalls > 0 }
        // Favourited in the app after the server was asked: its answer doesn't list it.
        smart.handle(.starred(song("s2"), true))
        await wait { rig.model.downloadedIDs.contains("s2") }
        stub.hold(false)
        await wait { rig.model.downloadedIDs.contains("s1") }
        try await Task.sleep(for: .milliseconds(100))
        #expect(rig.model.downloadedIDs == ["s1", "s2"])
    }
}

/// Re-check item 4 (2026-11-15): a download left from an earlier run is joined only when it fetches
/// from the same address under the same mobile-data rule as the new request would.
@Suite struct LeftoverDownloadTests {
    private func request(_ address: String, wifiOnly: Bool = false) -> URLRequest {
        var request = URLRequest(url: URL(string: address + "/rest/download?id=s1")!)
        if wifiOnly { request.allowsCellularAccess = false }
        return request
    }

    @Test func theSameAddressAndRuleIsJoined() {
        let home = request("http://music.home.example:4533")
        #expect(BackgroundDownloader.canJoin(home, as: request("HTTP://Music.Home.Example:4533")))
        #expect(BackgroundDownloader.canJoin(
            request("https://music.example.com", wifiOnly: true), as: request("https://music.example.com", wifiOnly: true)
        ))
    }

    @Test func anotherAddressStartsAgain() {
        let home = request("http://music.home.example:4533")
        #expect(!BackgroundDownloader.canJoin(home, as: request("https://music.example.com")))
        #expect(!BackgroundDownloader.canJoin(home, as: request("https://music.home.example:4533")))
        #expect(!BackgroundDownloader.canJoin(home, as: request("http://music.home.example:8080")))
    }

    @Test func anotherMobileDataRuleStartsAgain() {
        let away = "https://music.example.com"
        #expect(!BackgroundDownloader.canJoin(request(away, wifiOnly: true), as: request(away)))
        #expect(!BackgroundDownloader.canJoin(request(away), as: request(away, wifiOnly: true)))
    }

    @Test func aTaskWithNoRequestIsNotJoined() {
        #expect(!BackgroundDownloader.canJoin(nil, as: request("https://music.example.com")))
    }
}

/// The follow-up from C56: the background downloads session can't be swapped for a new one, so a
/// certificate stored, renewed or removed resets it in place, its tasks kept.
@Suite struct DownloadSessionResetTests {
    @Test(.timeLimit(.minutes(1))) func aCertificateChangeResetsTheSessionAndKeepsItsTasks() async {
        let certificates = DeviceCertificates(store: KeychainDeviceKeys())
        let session = URLSession(configuration: .ephemeral)
        let task = session.downloadTask(with: URL(string: "https://music.example.com/rest/download?id=s1")!)
        let (resets, signal) = AsyncStream.makeStream(of: Void.self)
        let downloader = BackgroundDownloader(certificates: certificates, session: session) { signal.yield() }
        certificates.refresh()
        var waiting = resets.makeAsyncIterator()
        await waiting.next()
        // Not cancelled (a cancelled task is `.canceling`, then `.completed`).
        #expect(task.state == .suspended)
        withExtendedLifetime(downloader) {}
    }

    /// A change of account (every launch, sign-in, sign-out and switch) and the revocation's re-check reset
    /// the other sessions, never this one: downloads running across them are left alone.
    @Test(.timeLimit(.minutes(1))) func aChangeOfAccountLeavesTheSessionAlone() async {
        let certificates = DeviceCertificates(store: KeychainDeviceKeys())
        let session = URLSession(configuration: .ephemeral)
        let (resets, signal) = AsyncStream.makeStream(of: Void.self)
        let downloader = BackgroundDownloader(certificates: certificates, session: session) { signal.yield() }
        certificates.use(profile: UUID(), server: URL(string: "https://music.example.com"))
        certificates.use(profile: nil, server: nil)
        certificates.resetConnections()
        // A reset of its own, after any the downloader started: their completions come first.
        await session.reset()
        signal.finish()
        var count = 0
        for await _ in resets { count += 1 }
        #expect(count == 0)
        withExtendedLifetime(downloader) {}
    }
}
