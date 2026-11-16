import Foundation
import SubsonicKit
import Testing
import UIKit
@testable import Navinx

/// Answers `getAlbumList2` in pages and `getAlbum` with two songs per album (one shared).
private struct LibraryStub: HTTPTransport {
    let albumCount: Int
    /// Every call fails, or only `getAlbum`'s.
    var isDown = false
    var albumsFail = false
    /// Each answer's wait, to see a sync mid-way.
    var delay: Duration?
    /// Each later page of every album starts this many albums early (one moved across a page's edge).
    var overlap = 0
    /// Told of each request as it arrives, before its wait: a test can act once a load is under way.
    var asked: (@Sendable () -> Void)?

    func get(_ url: URL, timeout: TimeInterval) async throws -> (Data, HTTPURLResponse) {
        asked?()
        if let delay { try await Task.sleep(for: delay) }
        if isDown || (albumsFail && url.lastPathComponent.hasPrefix("getAlbum") && !url.lastPathComponent.hasPrefix("getAlbumList")) {
            throw URLError(.cannotConnectToHost)
        }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        let inner: String
        switch url.lastPathComponent.replacingOccurrences(of: ".view", with: "") {
        case "getAlbumList2":
            let type = value("type") ?? ""
            let size = Int(value("size") ?? "") ?? 0
            let offset = Int(value("offset") ?? "") ?? 0
            let upper = type == "recent" ? min(albumCount, size) : min(offset + size, albumCount)
            let lower = type == "recent" ? 0 : max(offset - overlap, 0)
            let albums = lower < upper ? (lower..<upper).map { #"{"id":"a\#($0)","name":"Album \#($0)"}"# } : []
            inner = #""albumList2":{"album":[\#(albums.joined(separator: ","))]}"#
        case "getAlbum":
            let id = value("id") ?? ""
            inner = #""album":{"id":"\#(id)","name":"x","song":[{"id":"\#(id)-s","title":"Song"},{"id":"shared","title":"Shared"}]}"#
        case "getPlaylists":
            inner = #""playlists":{"playlist":[{"id":"p1","name":"Mix","songCount":3}]}"#
        case "getArtists":
            inner = #""artists":{"index":[{"name":"A","artist":[{"id":"r1","name":"Artist"}]}]}"#
        default:
            throw URLError(.badURL)
        }
        let body = #"{"subsonic-response":{"status":"ok","version":"1.16.1",\#(inner)}}"#
        return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

private func makeClient(
    albumCount: Int, isDown: Bool = false, albumsFail: Bool = false, delay: Duration? = nil, overlap: Int = 0,
    asked: (@Sendable () -> Void)? = nil
) throws -> SubsonicClient {
    try SubsonicClient(
        config: ServerConfig(serverURL: "http://stub.test", username: "u", password: "p"),
        coverArtSalt: "salt",
        transport: LibraryStub(
            albumCount: albumCount, isDown: isDown, albumsFail: albumsFail, delay: delay, overlap: overlap, asked: asked
        )
    )
}

private func makeCache() -> LibraryCache {
    LibraryCache(directory: URL.temporaryDirectory.appending(path: "LibraryCacheTests-\(UUID().uuidString)"))
}

@MainActor
struct SavedLibraryTests {
    private func model(_ cache: LibraryCache) -> LibraryModel {
        LibraryModel(syncDelay: .seconds(3600), cache: cache)
    }

    private func snapshot(savedAt: Date) -> LibrarySnapshot {
        LibrarySnapshot(
            savedAt: savedAt,
            artists: [Artist(id: "r", name: "Saved Artist")],
            latestAlbums: [],
            playlists: [Playlist(id: "p", name: "Saved Playlist")],
            allAlbums: (0..<25).map { Album(id: "a\($0)", name: "Saved \($0)") },
            allSongs: [Song(id: "s", title: "Saved Song")]
        )
    }

    @Test func aCompleteSyncIsThereOnTheNextLaunchEvenOffline() async throws {
        let cache = makeCache()
        let first = model(cache)
        await first.start(client: try makeClient(albumCount: 3), cacheKey: "k")
        await first.loadLibraryIfNeeded()
        #expect(first.allSongs.count == 4)

        let second = model(cache)
        await second.start(client: try makeClient(albumCount: 0, isDown: true), cacheKey: "k")
        #expect(second.allAlbums.count == 3)
        #expect(second.allSongs.count == 4)
        #expect(second.latestAlbums.count == 3)
        #expect(second.playlists.map(\.name) == ["Mix"])
        #expect(second.artists.map(\.name) == ["Artist"])
        #expect(!second.needsSync)
    }

    /// Offline, a downloaded song's whole artist string under a split artist's ID added a third row.
    @Test func offlineASplitArtistKeepsItsPartsWithoutTheDownloadsWholeName() async throws {
        let cache = makeCache()
        var saved = snapshot(savedAt: .now)
        saved.artists = [Artist(id: "sg", name: "Simon"), Artist(id: "sg", name: "Garfunkel")]
        await cache.save(saved, key: "k")
        let downloads = LibrarySnapshot(
            savedAt: .distantPast,
            artists: [Artist(id: "sg", name: "Simon & Garfunkel"), Artist(id: "new", name: "Only Downloaded")],
            latestAlbums: [], playlists: [], allAlbums: [], allSongs: []
        )
        let offline = model(cache)
        await offline.start(client: nil, cacheKey: "k", offline: { downloads })
        #expect(offline.artists.map(\.name) == ["Simon", "Garfunkel", "Only Downloaded"])
    }

    @Test func eachServerHasItsOwnCopy() async throws {
        let cache = makeCache()
        await cache.save(snapshot(savedAt: .now), key: "one")
        let other = model(cache)
        await other.start(client: try makeClient(albumCount: 0, isDown: true), cacheKey: "two")
        #expect(other.allAlbums.isEmpty)
    }

    @Test func aSavedLibraryNeedsASyncAfterSixHours() async throws {
        let cache = makeCache()
        await cache.save(snapshot(savedAt: .now.addingTimeInterval(-5 * 3600)), key: "fresh")
        await cache.save(snapshot(savedAt: .now.addingTimeInterval(-7 * 3600)), key: "stale")
        let fresh = model(cache)
        await fresh.start(client: try makeClient(albumCount: 0, isDown: true), cacheKey: "fresh")
        #expect(!fresh.needsSync)
        let stale = model(cache)
        await stale.start(client: try makeClient(albumCount: 0, isDown: true), cacheKey: "stale")
        #expect(stale.needsSync)
        #expect(stale.allSongs.map(\.title) == ["Saved Song"])
    }

    @Test func nothingPlayedRecentlyFallsBackToTwentyAlbums() async throws {
        let cache = makeCache()
        await cache.save(snapshot(savedAt: .now), key: "k")
        let library = model(cache)
        await library.start(client: try makeClient(albumCount: 0, isDown: true), cacheKey: "k")
        #expect(library.latestAlbums.count == 20)
    }

    @Test func aFailedSyncKeepsTheSavedCopyAndTheLists() async throws {
        let cache = makeCache()
        let savedAt = Date.now.addingTimeInterval(-7 * 3600)
        await cache.save(snapshot(savedAt: savedAt), key: "k")
        let library = model(cache)
        await library.start(client: try makeClient(albumCount: 2, albumsFail: true), cacheKey: "k")
        // The album list answers, but every album's songs fail.
        await library.syncNow()
        #expect(library.allSongs.map(\.title) == ["Saved Song"])
        #expect(library.needsSync)
        let saved = try #require(await cache.load(key: "k"))
        #expect(saved.savedAt == savedAt)
    }

    /// A save in flight at logout wrote the library back after logout cleared it.
    @Test func aClearWinsOverASaveThatStartedBeforeIt() async throws {
        let cache = makeCache()
        let generation = cache.generation
        cache.removeAll()
        await cache.save(snapshot(savedAt: .now), key: "k", generation: generation)
        await cache.savePlaylists([Playlist(id: "p", name: "P", songs: [])], key: "k", generation: generation)
        #expect(await cache.load(key: "k") == nil)
        #expect(await cache.loadPlaylists(key: "k").isEmpty)
        await cache.save(snapshot(savedAt: .now), key: "k", generation: cache.generation)
        #expect(await cache.load(key: "k") != nil)
    }

    @Test func aStoppedLibraryKeepsNoPlaylistOnDisk() async throws {
        let cache = makeCache()
        let library = model(cache)
        await library.start(client: try makeClient(albumCount: 1), cacheKey: "k")
        library.stop()
        library.remember(Playlist(id: "p", name: "P", songs: [Song(id: "s", title: "t")]))
        try await Task.sleep(for: .milliseconds(100))
        #expect(await cache.loadPlaylists(key: "k").isEmpty)
    }

    /// Edit Server put another account under the same profile: its library stayed the old one's.
    @Test func anotherAccountsCopyUnderTheSameProfileIsDropped() async throws {
        let cache = makeCache()
        let first = model(cache)
        await first.start(client: try makeClient(albumCount: 3), cacheKey: "k", account: "one")
        await first.loadLibraryIfNeeded()
        first.remember(Playlist(id: "p", name: "P", songs: [Song(id: "s", title: "t")]))
        try await Task.sleep(for: .milliseconds(100))
        #expect(await cache.load(key: "k", account: "one") != nil)
        #expect(await cache.load(key: "k", account: "two") == nil)

        let second = model(cache)
        await second.start(client: try makeClient(albumCount: 0, isDown: true), cacheKey: "k", account: "two")
        #expect(second.allAlbums.isEmpty)
        #expect(second.allSongs.isEmpty)
        #expect(second.openedPlaylists.isEmpty)
        #expect(second.needsSync)
        // Gone for the first account too: nothing of it stays under the profile.
        #expect(await cache.load(key: "k") == nil)
        #expect(await cache.loadPlaylists(key: "k").isEmpty)
    }

    /// A copy saved before the account mark (an earlier build) is still the profile's.
    @Test func aCopyFromBeforeTheMarkIsKept() async throws {
        let cache = makeCache()
        await cache.save(snapshot(savedAt: .now), key: "k")
        let library = model(cache)
        await library.start(client: try makeClient(albumCount: 0, isDown: true), cacheKey: "k", account: "one")
        #expect(library.allSongs.map(\.title) == ["Saved Song"])
        #expect(await cache.load(key: "k", account: "one") != nil)
        #expect(await cache.load(key: "k", account: "two") == nil)
    }

    @Test func removingForgetsIt() async throws {
        let cache = makeCache()
        await cache.save(snapshot(savedAt: .now), key: "k")
        cache.remove(key: "k")
        #expect(await cache.load(key: "k") == nil)
        await cache.save(snapshot(savedAt: .now), key: "k")
        cache.removeAll()
        #expect(await cache.load(key: "k") == nil)
    }
}

@MainActor
struct LibraryModelTests {
    @Test func loadsListsThenEverySongOnce() async throws {
        let model = LibraryModel(syncDelay: .seconds(3600))
        await model.start(client: try makeClient(albumCount: 13))
        #expect(model.latestAlbums.count == 13)
        #expect(model.playlists.map(\.name) == ["Mix"])
        #expect(model.artists.map(\.name) == ["Artist"])
        #expect(model.allSongs.isEmpty)

        await model.loadLibraryIfNeeded()
        #expect(model.allAlbums.count == 13)
        // One song per album, plus the shared one once.
        #expect(model.allSongs.count == 14)
        #expect(!model.isLoading)
        #expect(!model.isSyncingQuietly)
    }

    @Test func pagesThroughAlbumsAtFiveHundred() async throws {
        let model = LibraryModel(syncDelay: .seconds(3600))
        await model.start(client: try makeClient(albumCount: 1001))
        await model.loadLibraryIfNeeded()
        #expect(model.allAlbums.count == 1001)
        #expect(Set(model.allAlbums.map(\.id)).count == 1001)
    }

    @Test func refreshReloadsEverything() async throws {
        let model = LibraryModel(syncDelay: .seconds(3600))
        await model.start(client: try makeClient(albumCount: 2))
        await model.refresh()
        #expect(model.latestAlbums.count == 2)
        // The full sync carries on after the pull, in the background.
        await model.syncNow()
        #expect(model.allAlbums.count == 2)
        #expect(model.allSongs.count == 3)
    }

    /// A pull with the server down left Library and Home empty until the next launch. And signed in
    /// again with a new password, the library kept asking with the old one.
    @Test func aRefreshThatFailsKeepsTheListsAndTheSavedCopy() async throws {
        let cache = makeCache()
        let model = LibraryModel(syncDelay: .seconds(3600), cache: cache)
        await model.start(client: try makeClient(albumCount: 3), cacheKey: "k")
        await model.loadLibraryIfNeeded()
        let saved = try #require(await cache.load(key: "k"))
        model.use(try makeClient(albumCount: 0, isDown: true))
        await model.refresh()
        await model.syncNow()
        #expect(model.latestAlbums.count == 3)
        #expect(model.playlists.map(\.name) == ["Mix"])
        #expect(model.artists.map(\.name) == ["Artist"])
        #expect(model.allAlbums.count == 3)
        #expect(model.allSongs.count == 4)
        #expect(!model.isLoading)
        let after = try #require(await cache.load(key: "k"))
        #expect(after.savedAt == saved.savedAt)
    }

    /// A refresh during a sync waited for it, and that sync didn't fill the emptied lists.
    @Test func refreshDuringASyncEndsWithEveryList() async throws {
        let model = LibraryModel(syncDelay: .seconds(3600))
        await model.start(client: try makeClient(albumCount: 30, delay: .milliseconds(5)))
        let running = Task { await model.syncNow() }
        for _ in 0..<400 where model.allAlbums.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        await model.refresh()
        await running.value
        await model.syncNow()
        #expect(model.allAlbums.count == 30)
        #expect(model.allSongs.count == 31)
        #expect(!model.isSyncingQuietly)
    }

    /// After logout the sync went on with the old login, and saved the library again.
    @Test func stoppingEndsTheSyncAndSavesNothing() async throws {
        let cache = makeCache()
        let model = LibraryModel(syncDelay: .seconds(3600), cache: cache)
        await model.start(client: try makeClient(albumCount: 30, delay: .milliseconds(5)), cacheKey: "k")
        let running = Task { await model.syncNow() }
        for _ in 0..<400 where model.allAlbums.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        model.stop()
        await running.value
        #expect(model.allSongs.isEmpty)
        #expect(!model.isSyncingQuietly)
        #expect(await cache.load(key: "k") == nil)
    }

    /// The tabs left the screen during a sync and came back: the sync never ran again.
    @Test func aSyncStoppedByTheTabsLeavingStartsAgainOnTheirReturn() async throws {
        let model = LibraryModel(syncDelay: .milliseconds(10))
        let client = try makeClient(albumCount: 30, delay: .milliseconds(5))
        await model.start(client: client)
        for _ in 0..<400 where model.allAlbums.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        model.stop()
        #expect(model.allSongs.count < 31)
        await model.start(client: client)
        for _ in 0..<1000 where model.allSongs.count < 31 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(model.allSongs.count == 31)
        #expect(!model.needsSync)
    }

    /// Stopped during the first load, the library counted itself loaded, so the quick lists never came.
    /// Stopped once its first request is on its way (a signal, not a fixed time: under a full suite a short
    /// sleep can outlast the answer), with every answer 30 s away, so it's always stopped mid-way.
    @Test func aFirstLoadStoppedMidWayLoadsAgainOnTheNextStart() async throws {
        let model = LibraryModel(syncDelay: .seconds(3600))
        let (requests, request) = AsyncStream.makeStream(of: Void.self)
        let slow = try makeClient(albumCount: 3, delay: .seconds(30)) { request.yield() }
        let first = Task { await model.start(client: slow) }
        var arriving = requests.makeAsyncIterator()
        await arriving.next()
        model.stop()
        await first.value
        #expect(model.playlists.isEmpty)
        #expect(!model.isInitialized)
        await model.start(client: try makeClient(albumCount: 3))
        #expect(model.playlists.map(\.name) == ["Mix"])
        #expect(model.latestAlbums.count == 3)
        #expect(model.artists.map(\.name) == ["Artist"])
        #expect(model.isInitialized)
    }

    @Test func anAlbumOnTwoPagesIsListedOnce() async throws {
        let model = LibraryModel(syncDelay: .seconds(3600))
        await model.start(client: try makeClient(albumCount: 1001, overlap: 1))
        await model.loadLibraryIfNeeded()
        #expect(model.allAlbums.count == 1001)
        #expect(Set(model.allAlbums.map(\.id)).count == 1001)
    }

    @Test func withoutAClientStaysEmpty() async {
        let model = LibraryModel(syncDelay: .seconds(3600))
        await model.start(client: nil)
        await model.loadLibraryIfNeeded()
        #expect(model.allAlbums.isEmpty)
        #expect(!model.isLoading)
    }
}

struct LibraryEntriesTests {
    private let source = LibraryEntries.Source(
        playlists: [Playlist(id: "p2", name: "zebra", songCount: 2), Playlist(id: "p1", name: "Apple")],
        downloadedCount: 1
    )

    private func ids(_ sort: LibrarySort = .recents, _ source: LibraryEntries.Source? = nil) -> [String] {
        LibraryEntries.build(sort: sort, source: source ?? self.source).map(\.id)
    }

    @Test func likedThenDownloadedThenThePlaylists() {
        #expect(ids() == ["heartedSongs", "offlineSongs", "playlist-p2", "playlist-p1"])
        // With no playlists, the two pinned rows still show.
        #expect(ids(.recents, .init()) == ["heartedSongs", "offlineSongs"])
    }

    @Test func theBackgroundBuildMatches() async {
        for sort in LibrarySort.allCases {
            let built = await LibraryEntries.buildInBackground(sort: sort, source: source)
            #expect(built.map(\.id) == ids(sort))
        }
    }

    @Test func rowIDsStayTheSameAcrossSortsAndCounts() {
        var changed = source
        changed.downloadedCount = 9
        changed.playlists[0].songCount = 5
        #expect(Set(ids(.alphabetical, changed)) == Set(ids()))
    }

    @MainActor @Test func aToolbarPushHappensOnce() {
        var path: [LibraryRoute] = []
        path.pushOnce(.settings)
        path.pushOnce(.settings)
        #expect(path == [.settings])
        path.pushOnce(.history)
        #expect(path == [.settings, .history])
    }

    @Test func theSortsAreThoseThatApplyToPlaylists() {
        #expect(LibrarySort.allCases.map(\.title) == ["Recents", "Recently added", "Alphabetical", "Creator"])
    }

    private func date(_ day: Double) -> Date { Date(timeIntervalSince1970: day * 86400) }

    private var dated: LibraryEntries.Source {
        func playlist(_ id: String, owner: String?, created: Double?, changed: Double?) -> Playlist {
            var playlist = Playlist(id: id, name: id)
            playlist.owner = owner
            playlist.created = created.map(date)
            playlist.changed = changed.map(date)
            return playlist
        }
        return LibraryEntries.Source(playlists: [
            playlist("p1", owner: "zed", created: 1, changed: 5),
            playlist("p2", owner: nil, created: nil, changed: nil),
            playlist("p3", owner: "Amy", created: 3, changed: 9),
            playlist("P0", owner: "amy", created: 2, changed: 1),
        ])
    }

    /// The playlists' IDs only: the pinned rows always lead.
    private func sortedIDs(_ sort: LibrarySort) -> [String] {
        let all = ids(sort, dated)
        #expect(all.prefix(2) == ["heartedSongs", "offlineSongs"])
        return Array(all.dropFirst(2))
    }

    @Test func recentsPutTheLatestChangedFirstAndUndatedLast() {
        #expect(sortedIDs(.recents) == ["playlist-p3", "playlist-p1", "playlist-P0", "playlist-p2"])
    }

    @Test func latestAdditionsIsNewestFirstWithUndatedLast() {
        #expect(sortedIDs(.latestAdditions) == ["playlist-p3", "playlist-P0", "playlist-p1", "playlist-p2"])
    }

    @Test func alphabeticalIgnoresCase() {
        #expect(sortedIDs(.alphabetical) == ["playlist-P0", "playlist-p1", "playlist-p2", "playlist-p3"])
    }

    @Test func creatorSortsByOwnerThenNameIgnoringCase() {
        #expect(sortedIDs(.creator) == ["playlist-P0", "playlist-p3", "playlist-p1", "playlist-p2"])
    }

    @Test func rowTexts() {
        let all = LibraryEntries.build(sort: .recents, source: source)
        #expect(all.map(\.title) == ["Liked Songs", "Downloaded Songs", "zebra", "Apple"])
        #expect(all.map(\.subtitle) == ["Playlist • Favorites", "1 song saved offline", "Playlist • 2 songs", "Playlist • 0 songs"])
        #expect(CountText.songs(0) == "No songs")
        #expect(CountText.songs(1) == "1 song")
        #expect(CountText.songs(7) == "7 songs")
    }

    @Test func offlineGreysLikedSongsOnly() {
        let kinds = LibraryEntries.build(sort: .recents, source: source).map(\.kind)
        #expect(kinds.map { LibraryEntries.isGreyed($0, isOffline: true) } == [true, false, false, false])
        #expect(kinds.allSatisfy { !LibraryEntries.isGreyed($0, isOffline: false) })
    }
}

struct ArtworkTests {
    @Test func flutterSizes() {
        #expect(ArtworkCache.pixels(size: 54, scale: 3) == (600, 162))
        #expect(ArtworkCache.pixels(size: 240, scale: 3) == (720, 720))
        #expect(ArtworkCache.pixels(size: 500, scale: 3) == (1000, 1000))
        #expect(ArtworkCache.pixels(size: 10, scale: 2) == (600, 64))
        // A size from the server can be anything: no crash, and a size in range.
        #expect(ArtworkCache.pixels(size: .infinity, scale: 3) == (600, 600))
        #expect(ArtworkCache.pixels(size: .nan, scale: 3) == (600, 600))
        #expect(ArtworkCache.pixels(size: 1e30, scale: 3) == (1000, 1000))
        #expect(ArtworkCache.pixels(size: -5, scale: 3) == (600, 64))
    }

    /// Offline, a cover not downloaded showed the placeholder though the cache had it.
    @Test func offlineFormsTheCacheKeyTheServerAddressHad() throws {
        let client = try SubsonicClient(
            config: ServerConfig(serverURL: "http://stub.test/music", username: "a user", password: "p&w"),
            coverArtSalt: "salt"
        )
        let online = try #require(client.coverArtURL("al-1", size: 600))
        let key = ArtworkCache.cacheKey(online)
        // No login in the key.
        let names = URLComponents(url: key, resolvingAgainstBaseURL: false)?.queryItems?.map(\.name)
        #expect(names == ["u", "id", "size"])
        let profileID = "artwork-test-\(UUID().uuidString)"
        #expect(ArtworkCache.shared.offlineURL("al-1", size: 600, profileID: profileID) == nil)
        ArtworkCache.shared.remember(client, profileID: profileID)
        #expect(ArtworkCache.shared.offlineURL("al-1", size: 600, profileID: profileID) == key)
        // Any other address is its own key.
        let other = try #require(URL(string: "https://images.example/cover.jpg?s=1&t=2"))
        #expect(ArtworkCache.cacheKey(other) == other)
    }

    @Test func onlyAPictureIsACover() throws {
        let folder = URL.temporaryDirectory.appending(path: "ArtworkTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let picture = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        let good = folder.appending(path: "good.jpg")
        try #require(picture.pngData()).write(to: good)
        let error = folder.appending(path: "error.jpg")
        try Data(#"{"subsonic-response":{"status":"failed"}}"#.utf8).write(to: error)
        #expect(ArtworkCache.isImage(at: good))
        #expect(!ArtworkCache.isImage(at: error))
        #expect(!ArtworkCache.isImage(at: folder.appending(path: "missing.jpg")))
    }

    @Test func decodesNoLargerThanAsked() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 800, height: 400)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 800, height: 400))
        }
        let data = try #require(image.pngData())
        let decoded = try #require(ArtworkCache.decode(data, maxPixel: 100))
        #expect(max(decoded.size.width, decoded.size.height) * decoded.scale == 100)
        #expect(ArtworkCache.decode(Data("not an image".utf8), maxPixel: 100) == nil)
    }

    @Test func mosaicSlots() {
        func songs(_ covers: String...) -> [Song] {
            covers.enumerated().map { Song(id: "s\($0.offset)", title: "t", coverArt: $0.element) }
        }
        #expect(PlaylistArtwork.mosaic([]) == [])
        #expect(PlaylistArtwork.mosaic(songs("a", "a")) == ["a"])
        #expect(PlaylistArtwork.mosaic(songs("a", "b")) == ["a", "b", "b", "a"])
        #expect(PlaylistArtwork.mosaic(songs("a", "b", "c")) == ["a", "b", "c", "a"])
        #expect(PlaylistArtwork.mosaic(songs("a", "b", "c", "d", "e")) == ["a", "b", "c", "d"])
    }
}

struct AccountKeyTests {
    private let id = UUID()

    private func profile(_ address: String, _ username: String, lan: String? = nil) -> ServerProfile {
        ServerProfile(id: id, serverURL: address, homeNetworkURL: lan, username: username)
    }

    @Test func theSameAccountWrittenAnotherWayIsOneKey() {
        let key = profile("https://music.example", "anna").accountKey
        #expect(profile("HTTPS://Music.Example/", "anna").accountKey == key)
        #expect(profile("music.example", " Anna ").accountKey == key)
        // A home-network address (and a password, which isn't in the profile) changes nothing.
        #expect(profile("https://music.example", "anna", lan: "http://home.example:4533").accountKey == key)
        var renamed = profile("https://music.example", "anna")
        renamed.name = "Home"
        #expect(renamed.accountKey == key)
    }

    @Test func anotherUsernameOrMainAddressIsAnotherAccount() {
        let key = profile("https://music.example", "anna").accountKey
        #expect(profile("https://music.example", "ben").accountKey != key)
        #expect(profile("https://other.example", "anna").accountKey != key)
        #expect(profile("https://music.example/navidrome", "anna").accountKey != key)
        // The profile itself is kept (its downloads and approval hang on it).
        #expect(profile("https://other.example", "ben").accountKey.profileID == id)
        let other = ServerProfile(serverURL: "https://music.example", username: "anna").accountKey
        #expect(other != key)
    }

    /// No address or username in what's written.
    @Test func theMarkHoldsNoLogin() {
        let mark = profile("https://music.example", "anna").accountKey.mark
        #expect(mark.hasPrefix(id.uuidString))
        #expect(!mark.contains("music"))
        #expect(!mark.contains("anna"))
    }
}
