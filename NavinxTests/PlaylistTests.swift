import Foundation
import SubsonicKit
import SwiftUI
import Testing
import UIKit
@testable import Navinx

private func song(_ id: String, title: String? = nil, artist: String? = nil, duration: Int? = nil) -> Song {
    Song(id: id, title: title ?? id, artist: artist, duration: duration)
}

struct PaletteTests {
    /// SwiftUI resolves colours off the main thread during an animated render (it crashed the app
    /// removing a playlist row, C9). If the closure is main-actor-isolated again, this crashes too.
    @Test func dynamicColoursResolveOffTheMainThread() async {
        let color = Color(light: UIColor.white, dark: UIColor.black)
        let resolved = await Task.detached {
            UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
        }.value
        var white: CGFloat = 1
        resolved.getWhite(&white, alpha: nil)
        #expect(white == 0)
    }
}

struct PlaylistEditingTests {
    @Test func removingGoesByPlaceSoARepeatedSongLosesOnlyThatRow() {
        let songs = [song("a"), song("b"), song("a"), song("c")]
        #expect(PlaylistEditing.removing([2], from: songs).map(\.id) == ["a", "b", "c"])
        #expect(PlaylistEditing.removing([0, 3], from: songs).map(\.id) == ["b", "a"])
    }

    /// Flutter leaves the selection pointing at the wrong rows here.
    @Test func theSelectionFollowsItsRowsWhenOneGoes() {
        #expect(PlaylistEditing.selection([0, 2, 4], afterRemoving: 2) == [0, 3])
        #expect(PlaylistEditing.selection([1], afterRemoving: 3) == [1])
    }

    @Test func updatedBringsTheCountAndLengthUpToDate() {
        let playlist = Playlist(id: "p", name: "Mix", songCount: 9, duration: 999)
        let updated = PlaylistEditing.updated(playlist, songs: [song("a", duration: 60), song("b", duration: 90), song("c")])
        #expect(updated.songCount == 3)
        #expect(updated.duration == 150)
        #expect(updated.name == "Mix")
    }

    @Test func rowIDsAreUniqueAndStayWithTheirSong() {
        let before = PlaylistEditing.rowIDs([song("a"), song("b"), song("a")])
        #expect(Set(before).count == 3)
        // Removing the first row leaves "b" with the same ID.
        let after = PlaylistEditing.rowIDs([song("b"), song("a")])
        #expect(after[0] == before[1])
    }

    @Test func aFilterGivesPlacesInTheWholeList() {
        let songs = [song("1", title: "Alpha"), song("2", title: "Beta", artist: "ALPHA band"), song("3", title: "Gamma")]
        #expect(DetailLogic.filteredIndexes(songs, query: " alpha ") == [0, 1])
        #expect(DetailLogic.filteredIndexes(songs, query: "") == [0, 1, 2])
        #expect(DetailLogic.filter(songs, query: "gam").map(\.id) == ["3"])
    }
}

struct SongCollectionTests {
    @Test(arguments: [(3900, "1 hr 5 min"), (7200, "2 hr"), (2520, "42 min"), (0, "0 min")])
    func durationSummary(seconds: Int, text: String) {
        #expect(SongCollectionLogic.durationSummary([song("a", duration: seconds), song("b")]) == text)
    }

    private func profile(_ id: String, plays: Int, at time: TimeInterval) -> ListeningRecord {
        var profile = ListeningRecord(song: song(id))
        profile.playCount = plays
        profile.lastPlayed = Date(timeIntervalSince1970: time)
        return profile
    }

    @Test func historyIsPlayedSongsStillInTheLibraryLatestFirst() {
        let profiles = [
            "old": profile("old", plays: 2, at: 100),
            "new": profile("new", plays: 1, at: 300),
            "skipped": profile("skipped", plays: 0, at: 400),
            "gone": profile("gone", plays: 5, at: 500),
        ]
        let history = SongCollectionLogic.history(profiles: profiles, allSongs: [song("old"), song("new"), song("skipped")])
        #expect(history.map(\.id) == ["new", "old"])
    }

    @Test func historyStopsAtAHundred() {
        let ids = (0..<150).map { "s\($0)" }
        let profiles = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($0.element, profile($0.element, plays: 1, at: Double($0.offset))) })
        let history = SongCollectionLogic.history(profiles: profiles, allSongs: ids.map { song($0) })
        #expect(history.count == 100)
        #expect(history.first?.id == "s149")
    }

    /// History's "Nothing played" only when the phone itself has no plays (C54 part 4).
    @Test func historysEmptyPageTellsTheCasesApart() {
        // Nothing played here: said at once, loaded library or not.
        #expect(SongCollectionLogic.emptyPage(hasPlays: false, libraryReady: true) == .nothingPlayed)
        #expect(SongCollectionLogic.emptyPage(hasPlays: false, libraryReady: false) == .nothingPlayed)
        // Plays, but the library is still loading: the spinner.
        #expect(SongCollectionLogic.emptyPage(hasPlays: true, libraryReady: false) == .loading)
        // Plays, but none of those songs in the loaded library: the page's text for any empty list.
        #expect(SongCollectionLogic.emptyPage(hasPlays: true, libraryReady: true) == .noSongs)
        #expect(SongCollectionLogic.EmptyPage.noSongs.text == "No songs available. Please load your library first.")
        #expect(SongCollectionLogic.EmptyPage.nothingPlayed.text == "Nothing played on this iPhone yet.")
        #expect(SongCollectionLogic.EmptyPage.loading.text == nil)
    }

    @Test func playsCountOnlyWithAPlay() {
        #expect(!SongCollectionLogic.hasPlays([:]))
        #expect(!SongCollectionLogic.hasPlays(["s": profile("s", plays: 0, at: 1)]))
        #expect(SongCollectionLogic.hasPlays(["s": profile("s", plays: 0, at: 1), "t": profile("t", plays: 1, at: 2)]))
    }
}

struct AlbumIndexTests {
    private let albums = ["Zebra", " apple", "Avocado", "99 Songs", "Éclair", "Banana"].enumerated().map {
        Album(id: String($0.offset), name: $0.element)
    }

    @Test func aLetterFindsTheFirstAlbumInTheListsOrder() {
        #expect(AlbumIndex.firstAlbum("A", in: albums)?.name == " apple")
        #expect(AlbumIndex.firstAlbum("Z", in: albums)?.name == "Zebra")
        #expect(AlbumIndex.firstAlbum("Q", in: albums) == nil)
    }

    @Test func theHashIsForWhateverDoesNotStartWithALetter() {
        #expect(AlbumIndex.firstAlbum("#", in: albums)?.name == "99 Songs")
        #expect(AlbumIndex.firstAlbum("#", in: [Album(id: "1", name: "Éclair")])?.name == "Éclair")
    }

    @Test func theIndexHasFluttersLetters() {
        #expect(AlbumIndex.letters.count == 27)
        #expect(AlbumIndex.letters.first == "A" && AlbumIndex.letters.last == "#")
    }
}

@MainActor
struct PinnedPlaylistsTests {
    private func model() -> PinnedPlaylistsModel {
        let name = "PinnedPlaylistsTests-\(UUID().uuidString)"
        return PinnedPlaylistsModel(defaults: UserDefaults(suiteName: name)!)
    }

    private func client(_ transport: some HTTPTransport) throws -> SubsonicClient {
        try SubsonicClient(
            config: ServerConfig(serverURL: "http://stub.test", username: "u", password: "p"),
            coverArtSalt: "salt",
            transport: transport
        )
    }

    @Test func toggleAndRemove() {
        let favorites = model()
        favorites.toggle("p")
        #expect(favorites.isFavorite("p"))
        favorites.toggle("p")
        #expect(!favorites.isFavorite("p"))
        favorites.toggle("p")
        favorites.remove("p")
        #expect(!favorites.isFavorite("p"))
    }

    @Test func theyLastBetweenLaunches() {
        let defaults = UserDefaults(suiteName: "PinnedPlaylistsTests-\(UUID().uuidString)")!
        PinnedPlaylistsModel(defaults: defaults).toggle("p")
        #expect(PinnedPlaylistsModel(defaults: defaults).isFavorite("p"))
    }

    @Test func homeRowsAreOffByDefault() {
        // Flutter's key and default for C11's switch.
        #expect(PinnedPlaylistsModel.showOnHomeKey == "home_show_favorite_playlists")
        let defaults = UserDefaults(suiteName: "PinnedPlaylistsTests-\(UUID().uuidString)")!
        #expect(!defaults.bool(forKey: PinnedPlaylistsModel.showOnHomeKey))
    }

    @Test func rowsAreFavouritesWithSongsLatestChangeFirst() async throws {
        let favorites = model()
        let old = Playlist(id: "old", name: "Old", changed: Date(timeIntervalSince1970: 100))
        let new = Playlist(id: "new", name: "New", changed: Date(timeIntervalSince1970: 300))
        let created = Playlist(id: "created", name: "Created", created: Date(timeIntervalSince1970: 200))
        let empty = Playlist(id: "empty", name: "Empty", changed: Date(timeIntervalSince1970: 400))
        let other = Playlist(id: "other", name: "Other", changed: Date(timeIntervalSince1970: 500))
        let playlists = [old, created, empty, new, other]
        ["old", "new", "created", "empty"].forEach(favorites.toggle)

        // Nothing has been fetched yet, so no rows.
        #expect(favorites.homeRows(playlists).isEmpty)

        let stub = PlaylistStub(emptyIDs: ["empty"])
        try await favorites.loadSongs(playlists, client: client(stub))
        #expect(favorites.homeRows(playlists).map(\.id) == ["new", "created", "old"])
        #expect(!stub.requested.contains("other"))
    }

    /// Flutter's rule: fetched once, and again only for a newer `changed`.
    @Test func songsAreFetchedAgainOnlyForANewerChange() async throws {
        let favorites = model()
        favorites.toggle("p")
        let stub = PlaylistStub()
        let client = try client(stub)
        let first = Playlist(id: "p", name: "Mix", changed: Date(timeIntervalSince1970: 100))
        await favorites.loadSongs([first], client: client)
        await favorites.loadSongs([first], client: client)
        #expect(stub.requested == ["p"])

        let second = Playlist(id: "p", name: "Renamed", changed: Date(timeIntervalSince1970: 200))
        // Until the newer version arrives, its row waits rather than showing old songs.
        #expect(favorites.homeRows([second]).isEmpty)
        await favorites.loadSongs([second], client: client)
        #expect(stub.requested == ["p", "p"])
        #expect(favorites.homeRows([second]).first?.name == "Renamed")
        #expect(favorites.loadKey([first]) != favorites.loadKey([second]))
    }
}

/// Answers `getPlaylist` with one song, unless told the playlist is empty, and notes what was asked.
private final class PlaylistStub: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [String] = []
    let emptyIDs: Set<String>

    init(emptyIDs: Set<String> = []) {
        self.emptyIDs = emptyIDs
    }

    var requested: [String] { lock.withLock { ids } }

    func get(_ url: URL, timeout: TimeInterval) async throws -> (Data, HTTPURLResponse) {
        let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "id" }?.value ?? ""
        lock.withLock { ids.append(id) }
        let songs = emptyIDs.contains(id) ? "" : #""entry":[{"id":"s","title":"Song"}]"#
        let body = #"{"subsonic-response":{"status":"ok","version":"1.16.1","playlist":{"id":"\#(id)","name":"x",\#(songs)}}}"#
            .replacingOccurrences(of: #""x",}"#, with: #""x"}"#)
        return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

/// A server whose playlist writes can fail, and a list that shows what it holds.
private final class WritableServer: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var names = ["p1": "Mix"]
    private var failsWrites = false

    func failWrites() { lock.withLock { failsWrites = true } }

    func get(_ url: URL, timeout: TimeInterval) async throws -> (Data, HTTPURLResponse) {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        let endpoint = url.lastPathComponent.replacingOccurrences(of: ".view", with: "")
        let inner: String? = try lock.withLock {
            switch endpoint {
            case "createPlaylist", "updatePlaylist", "deletePlaylist":
                if failsWrites { throw URLError(.cannotConnectToHost) }
                if endpoint == "createPlaylist" { names["new"] = value("name") }
                if endpoint == "updatePlaylist", let name = value("name"), let id = value("playlistId") { names[id] = name }
                if endpoint == "deletePlaylist", let id = value("id") { names[id] = nil }
                return nil
            case "getPlaylists":
                let rows = names.sorted { $0.key < $1.key }.map { #"{"id":"\#($0.key)","name":"\#($0.value)"}"# }
                return #""playlists":{"playlist":[\#(rows.joined(separator: ","))]}"#
            case "getAlbumList2": return #""albumList2":{}"#
            case "getRandomSongs": return #""randomSongs":{}"#
            case "getArtists": return #""artists":{}"#
            default: throw URLError(.badURL)
            }
        }
        let body = inner.map { #"{"subsonic-response":{"status":"ok","version":"1.16.1",\#($0)}}"# }
            ?? #"{"subsonic-response":{"status":"ok","version":"1.16.1"}}"#
        return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

@MainActor
struct PlaylistWritesTests {
    private func library(_ server: WritableServer) async throws -> LibraryModel {
        let model = LibraryModel(
            syncDelay: .seconds(3600),
            cache: LibraryCache(directory: URL.temporaryDirectory.appending(path: "PlaylistWrites-\(UUID().uuidString)"))
        )
        let client = try SubsonicClient(
            config: ServerConfig(serverURL: "http://stub.test", username: "u", password: "p"),
            coverArtSalt: "salt",
            transport: server
        )
        await model.start(client: client)
        return model
    }

    @Test func createAndRenameShowInTheList() async throws {
        let model = try await library(WritableServer())
        try await model.createPlaylist(name: "Road Trip")
        #expect(model.playlists.contains { $0.name == "Road Trip" })
        try await model.renamePlaylist(id: "p1", to: "Renamed")
        #expect(model.playlists.contains { $0.id == "p1" && $0.name == "Renamed" })
    }

    @Test func deleteTakesItOffTheList() async throws {
        let model = try await library(WritableServer())
        try await model.deletePlaylist(id: "p1")
        #expect(model.playlists.isEmpty)
    }

    @Test func aRefusedDeletePutsItBack() async throws {
        let server = WritableServer()
        let model = try await library(server)
        server.failWrites()
        await #expect(throws: (any Error).self) { try await model.deletePlaylist(id: "p1") }
        #expect(model.playlists.map(\.id) == ["p1"])
    }
}
