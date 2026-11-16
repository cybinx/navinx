import Foundation
import SubsonicKit
import Testing
@testable import Navinx

private func album(_ id: String, artist: String? = nil, artistID: String? = nil, year: Int? = nil, created: Date? = nil) -> Album {
    Album(id: id, name: "Album \(id)", artist: artist, artistID: artistID, year: year, created: created)
}

private func song(_ id: String, artist: String? = nil, cover: String? = nil, albumID: String? = nil) -> Song {
    var song = Song(id: id, title: "Song \(id)")
    song.artist = artist
    song.coverArt = cover
    song.albumID = albumID
    return song
}

/// Answers with canned album lists, artists and random songs, and records what was asked. Types in
/// `failing` fail once, so a retry works; `delay` holds an answer back.
private final class NewTabStub: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [String] = []
    private var _failing: Set<String>
    private var _lists: [String: [String]]
    private let artists: [String: [String]]
    private let songCount: Int
    private let delay: Duration?

    init(
        lists: [String: [String]] = [:],
        artists: [String: [String]] = [:],
        songCount: Int = 0,
        failing: Set<String> = [],
        delay: Duration? = nil
    ) {
        _lists = lists
        self.artists = artists
        self.songCount = songCount
        _failing = failing
        self.delay = delay
    }

    var calls: [String] { lock.withLock { _calls } }

    func setList(_ type: String, _ ids: [String]) {
        lock.withLock { _lists[type] = ids }
    }

    func setFailing(_ type: String) {
        lock.withLock { _ = _failing.insert(type) }
    }

    private func answer(type: String, record: String) -> (fails: Bool, ids: [String]) {
        lock.withLock {
            _calls.append(record)
            return (_failing.remove(type) != nil, _lists[type] ?? [])
        }
    }

    func get(_ url: URL, timeout: TimeInterval) async throws -> (Data, HTTPURLResponse) {
        if let delay { try await Task.sleep(for: delay) }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String { items.first { $0.name == name }?.value ?? "" }
        let inner: String
        switch url.lastPathComponent.replacingOccurrences(of: ".view", with: "") {
        case "getAlbumList2":
            let type = value("type")
            let offset = Int(value("offset")) ?? 0
            let size = Int(value("size")) ?? 0
            let (fails, ids) = answer(type: type, record: "\(type) size=\(size) offset=\(offset)")
            if fails { throw URLError(.cannotConnectToHost) }
            let albums = ids.dropFirst(offset).prefix(size).map { #"{"id":"\#($0)","name":"\#($0)"}"# }
            inner = #""albumList2":{"album":[\#(albums.joined(separator: ","))]}"#
        case "getArtist":
            let id = value("id")
            let (fails, _) = answer(type: "artist:\(id)", record: "artist \(id)")
            if fails { throw URLError(.cannotConnectToHost) }
            let albums = (artists[id] ?? []).map { #"{"id":"\#($0)","name":"\#($0)"}"# }
            inner = #""artist":{"id":"\#(id)","name":"\#(id)","album":[\#(albums.joined(separator: ","))]}"#
        case "getRandomSongs":
            let size = Int(value("size")) ?? 0
            let (fails, _) = answer(type: "random", record: "random size=\(size)")
            if fails { throw URLError(.cannotConnectToHost) }
            let songs = (0..<min(size, songCount)).map { #"{"id":"s\#($0)","title":"Song \#($0)"}"# }
            inner = #""randomSongs":{"song":[\#(songs.joined(separator: ","))]}"#
        default:
            inner = ""
        }
        let body = #"{"subsonic-response":{"status":"ok","version":"1.16.1"\#(inner.isEmpty ? "" : ",\(inner)")}}"#
        return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

private func client(_ stub: NewTabStub) -> SubsonicClient {
    let config = ServerConfig(serverURL: "https://example.test", username: "u", password: "p")
    return try! SubsonicClient(config: config, coverArtSalt: "salt", transport: stub)
}

@Suite struct NewFeedRulesTests {
    @Test func theNewestComeFirstByYearThenDateAdded() {
        let early = Date(timeIntervalSince1970: 100)
        let late = Date(timeIntervalSince1970: 200)
        let sorted = [
            album("noYear"),
            album("2020early", year: 2020, created: early),
            album("2021", year: 2021),
            album("2020late", year: 2020, created: late),
        ].sorted(by: NewFeed.isNewer)
        #expect(sorted.map(\.id) == ["2021", "2020late", "2020early", "noYear"])
    }

    @Test func artistsRankByHowHighTheirAlbumsAre() {
        let frequent = [
            album("1", artist: "Alpha", artistID: "a"),
            album("2", artist: "Beta", artistID: "b"),
            album("3", artist: "Beta", artistID: "b"),
            album("4", artist: "Gamma", artistID: "c"),
        ]
        // Alpha 4, Beta 3 + 2, Gamma 1.
        #expect(NewFeed.topArtists(frequent: frequent).map(\.id) == ["b", "a", "c"])
    }

    @Test func compilationsAndAlbumsWithNoArtistIDDoNotRank() {
        let frequent = [
            album("1", artist: "Various Artists", artistID: "va"),
            album("2", artist: "  various ", artistID: "v"),
            album("3", artist: "No ID"),
            album("4", artist: "Empty ID", artistID: ""),
            album("5", artistID: "noName"),
            album("6", artist: "Alpha", artistID: "a"),
        ]
        #expect(NewFeed.topArtists(frequent: frequent).map(\.id) == ["a"])
    }

    @Test func onlyTheTopEightArtistsAreLookedUp() {
        let frequent = (0..<12).map { album("\($0)", artist: "Artist \($0)", artistID: "a\($0)") }
        #expect(NewFeed.topArtists(frequent: frequent).map(\.id) == (0..<8).map { "a\($0)" })
    }

    @Test func freshAlbumsSkipThePlayedTakeTwoPerArtistAndSortNewestFirst() {
        let frequent = [album("played")]
        let top = [(id: "a", name: "Alpha"), (id: "b", name: "Beta"), (id: "c", name: "Gamma")]
        let result = NewFeed.freshAlbums(frequent: frequent, top: top, catalogues: [
            [album("a1", year: 2001), album("played", year: 2030), album("a3", year: 2003), album("a2", year: 2002)],
            [album("played", year: 2030)],
            [album("c1", year: 2010)],
        ])
        #expect(result.albums.map(\.id) == ["c1", "a3", "a2"])
        // Beta has nothing fresh, so it isn't named.
        #expect(result.artists == ["Alpha", "Gamma"])
    }

    @Test func anAlbumOfTwoTopArtistsIsListedOnce() {
        let top = [(id: "a", name: "Alpha"), (id: "b", name: "Beta")]
        let shared = album("shared", year: 2020)
        let result = NewFeed.freshAlbums(frequent: [], top: top, catalogues: [
            [shared, album("a1", year: 2019)],
            [shared, album("b1", year: 2018), album("b2", year: 2017)],
        ])
        #expect(result.albums.map(\.id) == ["shared", "a1", "b1", "b2"])
        #expect(result.artists == ["Alpha", "Beta"])
    }

    @Test func freshAlbumsStopAtFourteen() {
        let top = (0..<8).map { (id: "a\($0)", name: "Artist \($0)") }
        let catalogues = (0..<8).map { index in (0..<3).map { album("\(index)-\($0)") } }
        let result = NewFeed.freshAlbums(frequent: [], top: top, catalogues: catalogues)
        #expect(result.albums.count == 14)
        #expect(result.artists.count == 8)
    }

    @Test(arguments: [
        ([], nil),
        (["A"], "New from A"),
        (["A", "B"], "New from A and B"),
        (["A", "B", "C"], "New from A, B and more"),
    ] as [([String], String?)])
    func theFreshSubtitleNamesUpToTwoArtists(names: [String], subtitle: String?) {
        #expect(ArtistNewArrivals(artists: names).subtitle == subtitle)
    }

    @Test func rediscoverLeavesOutWhatWasPlayedLately() {
        let picks = NewFeed.rediscoverPicks(starred: [album("old"), album("recent")], recent: [album("recent")])
        #expect(picks.map(\.id) == ["old"])
    }

    @Test func rediscoverTopsUpAfterItsPicksWithoutRepeats() {
        let topped = NewFeed.rediscoverTopUp(
            [album("star")],
            frequent: [album("star"), album("recent"), album("played")],
            recent: [album("recent")]
        )
        #expect(topped.map(\.id) == ["star", "played"])
    }

    @Test func theLineUnderAnAlbumHasWhicheverPartsItHas() {
        #expect(NewFeed.artistAndYear(album("x", artist: "A", year: 1999)) == "A · 1999")
        #expect(NewFeed.artistAndYear(album("x", artist: "A")) == "A")
        #expect(NewFeed.artistAndYear(album("x", year: 1999)) == "1999")
        #expect(NewFeed.artistAndYear(album("x")).isEmpty)
    }

    @Test func theMosaicTakesFourCoversFromDifferentAlbums() {
        let songs = [
            song("1", cover: "c1", albumID: "a"),
            song("2", cover: "c1-again", albumID: "a"),
            song("noCover", albumID: "z"),
            song("emptyCover", cover: "", albumID: "y"),
            song("3", cover: "c3", albumID: "b"),
            song("4", cover: "c4"),
            song("5", cover: "c5", albumID: "d"),
            song("6", cover: "c6", albumID: "e"),
        ]
        #expect(NewFeed.mixCovers(songs) == ["c1", "c3", "c4", "c5"])
    }

    @Test(arguments: [
        ([], ""),
        (["A", "A"], "A"),
        (["A", "B"], "A and B"),
        (["A", "", "B", "C", "D"], "A, B, C and more"),
    ] as [([String], String)])
    func theMixLineNamesThreeArtists(names: [String], line: String) {
        let songs = names.enumerated().map { song("\($0.offset)", artist: $0.element) }
        #expect(NewFeed.mixArtists(songs) == line)
    }
}

@Suite struct NewFeedFetchTests {
    @Test func theHeroAsksForSixAndLatestAdditionsSkipsThem() async throws {
        let ids = (0..<30).map { "n\($0)" }
        let stub = NewTabStub(lists: ["newest": ids])
        let hero = try await NewFeed.hero(client(stub))
        let recent = try await NewFeed.latestAdditions(client(stub))
        #expect(hero.map(\.id) == Array(ids[0..<6]))
        #expect(recent.map(\.id) == Array(ids[6..<26]))
        #expect(stub.calls == ["newest size=6 offset=0", "newest size=20 offset=6"])
    }

    @Test func theMixAsksFor25Songs() async throws {
        let stub = NewTabStub(songCount: 40)
        let songs = try await NewFeed.mix(client(stub))
        #expect(songs.count == 25)
        #expect(stub.calls == ["random size=25"])
    }

    @Test func rediscoverDoesNotAskForMostPlayedWithEnoughPicks() async throws {
        let stub = NewTabStub(lists: ["starred": (0..<20).map { "s\($0)" }, "recent": ["s0"]])
        let picks = try await NewFeed.rediscover(client(stub))
        #expect(picks.count == 14)
        #expect(!picks.contains { $0.id == "s0" })
        #expect(Set(stub.calls) == ["starred size=200 offset=0", "recent size=60 offset=0"])
    }

    @Test func rediscoverAsksForMostPlayedBelowSixPicks() async throws {
        let stub = NewTabStub(lists: ["starred": ["s0", "s1"], "recent": ["s1", "f0"], "frequent": ["f0", "f1", "s0"]])
        let picks = try await NewFeed.rediscover(client(stub))
        #expect(picks.map(\.id) == ["s0", "f1"])
        #expect(stub.calls.contains("frequent size=40 offset=0"))
    }

    @Test func noPlaysMeansNoLookups() async throws {
        let stub = NewTabStub()
        let fresh = try await NewFeed.artistNewArrivals(client(stub))
        #expect(fresh == ArtistNewArrivals())
        #expect(stub.calls == ["frequent size=60 offset=0"])
    }

    @Test func aMostPlayedListThatFailsFailsTheSection() async {
        let stub = NewTabStub(failing: ["frequent"])
        await #expect(throws: (any Error).self) { try await NewFeed.artistNewArrivals(client(stub)) }
    }
}

@MainActor @Suite struct SectionLoadTests {
    private func load(_ stub: NewTabStub, timeout: Duration = .seconds(30)) -> SectionLoad<[Album]> {
        SectionLoad(timeout: timeout) { try await $0.albumList(.newest, size: 6) }
    }

    @Test func itStartsOnThePlaceholderAndEndsWithTheContent() async {
        let stub = NewTabStub(lists: ["newest": ["a"]])
        let section = load(stub)
        guard case .placeholder = section.phase else { Issue.record("not the placeholder"); return }
        await section.load(client: client(stub))
        guard case .content(let albums) = section.phase else { Issue.record("no content"); return }
        #expect(albums.map(\.id) == ["a"])
    }

    @Test func aFailureShowsTheErrorAndRetryWorks() async {
        let stub = NewTabStub(lists: ["newest": ["a"]], failing: ["newest"])
        let section = load(stub)
        // A first load that fails has nothing to keep: the error page says it.
        #expect(await section.load(client: client(stub)) == false)
        guard case .failed = section.phase else { Issue.record("no error"); return }
        await section.load(client: client(stub))
        guard case .content = section.phase else { Issue.record("no content after retry"); return }
    }

    @Test func aFailedReloadKeepsTheShownContent() async {
        let stub = NewTabStub(lists: ["newest": ["a"]])
        let section = load(stub)
        #expect(await section.load(client: client(stub)) == false)
        stub.setFailing("newest")
        // Said, so the page can tell the reload failed.
        #expect(await section.load(client: client(stub)) == true)
        guard case .content(let albums) = section.phase else { Issue.record("the content went away"); return }
        #expect(albums.map(\.id) == ["a"])
    }

    @Test func aReloadKeepsTheContentUntilNewDataArrives() async throws {
        let stub = NewTabStub(lists: ["newest": ["a"]], delay: .milliseconds(150))
        let section = load(stub)
        await section.load(client: client(stub))
        stub.setList("newest", ["b"])
        let reload = Task { await section.load(client: client(stub)) }
        try await Task.sleep(for: .milliseconds(30))
        guard case .content(let during) = section.phase else { Issue.record("content went away"); return }
        #expect(during.map(\.id) == ["a"])
        await reload.value
        guard case .content(let after) = section.phase else { Issue.record("no content"); return }
        #expect(after.map(\.id) == ["b"])
    }

    @Test func onlyTheLatestLoadCounts() async throws {
        let stub = NewTabStub(lists: ["newest": ["old"]], delay: .milliseconds(150))
        let section = load(stub)
        let first = Task { await section.load(client: client(stub)) }
        try await Task.sleep(for: .milliseconds(30))
        let fast = NewTabStub(lists: ["newest": ["new"]])
        await section.load(client: client(fast))
        await first.value
        guard case .content(let albums) = section.phase else { Issue.record("no content"); return }
        #expect(albums.map(\.id) == ["new"])
    }

    @Test func aSlowSectionTimesOut() async {
        let stub = NewTabStub(lists: ["newest": ["a"]], delay: .seconds(30))
        let section = load(stub, timeout: .milliseconds(50))
        await section.load(client: client(stub))
        guard case .failed = section.phase else { Issue.record("no timeout"); return }
    }

    @Test func noClientShowsTheError() async {
        let section = load(NewTabStub())
        await section.load(client: nil)
        guard case .failed = section.phase else { Issue.record("no error"); return }
    }
}

@MainActor @Suite struct NewModelTests {
    @Test func aFailingSectionLeavesTheOthersAlone() async {
        let stub = NewTabStub(lists: ["newest": ["a"]], songCount: 3, failing: ["frequent"])
        let model = NewModel()
        #expect(await model.refresh(client: client(stub)) == NewModel.KeptAfterFailure())
        guard case .failed = model.fresh.phase else { Issue.record("fresh should fail"); return }
        guard case .content(let hero) = model.hero.phase else { Issue.record("hero should load"); return }
        guard case .content(let mix) = model.mix.phase else { Issue.record("mix should load"); return }
        #expect(hero.map(\.id) == ["a"])
        #expect(mix.count == 3)
        // Then the albums fail while shown: the refresh says so, and the mix that loaded doesn't count.
        stub.setFailing("newest")
        #expect(await model.refresh(client: client(stub)) == NewModel.KeptAfterFailure(albums: true, songs: false))
    }

    @Test func refreshReloadsEverySection() async {
        let stub = NewTabStub()
        let model = NewModel()
        await model.refresh(client: client(stub))
        let first = stub.calls.count
        await model.refresh(client: client(stub))
        #expect(stub.calls.count == first * 2)
        #expect(stub.calls.contains("random size=25"))
    }
}
