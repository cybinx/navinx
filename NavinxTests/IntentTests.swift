import Foundation
import Testing
import SubsonicKit
@testable import Navinx
import SharedKit

// Siri, Shortcuts, Spotlight and the links (C39): the link parser, the entity look-ups against a saved
// library, and the "ready to play" path called twice.

struct NavinxLinkTests {
    @Test func readsEveryKindOfLink() {
        #expect(NavinxLink.destination(from: URL(string: "navinx://album/al-1")!) == .album(id: "al-1"))
        #expect(NavinxLink.destination(from: URL(string: "navinx://artist/ar-2")!) == .artist(id: "ar-2"))
        #expect(NavinxLink.destination(from: URL(string: "NAVINX://playlist/p%203")!) == .playlist(id: "p 3"))
        #expect(NavinxLink.destination(from: URL(string: "navinx://search")!) == .search(nil))
        #expect(NavinxLink.destination(from: URL(string: "navinx://search?q=Kind%20of%20Blue")!) == .search("Kind of Blue"))
        #expect(NavinxLink.destination(from: URL(string: "navinx://search?q=%20")!) == .search(nil))
        #expect(NavinxLink.destination(from: URL(string: "navinx://favorites")!) == .favorites)
        #expect(NavinxLink.destination(from: URL(string: "navinx://downloads")!) == .downloads)
    }

    @Test func refusesWhatIsntALink() {
        for text in ["navinx://album", "navinx://album/1/2", "navinx://favorites/1", "navinx://settings",
                     "https://album/1", "navinx://"] {
            #expect(NavinxLink.destination(from: URL(string: text)!) == nil, "\(text)")
        }
    }

    @Test func makesLinksItReadsBack() {
        let all: [AppDestination] = [.album(id: "a b"), .artist(id: "x"), .playlist(id: "p1"), .search("rock & roll"),
                                     .search(nil), .favorites, .downloads]
        for destination in all {
            #expect(NavinxLink.destination(from: NavinxLink.url(for: destination)) == destination)
        }
    }
}

struct LibraryMatchingTests {
    private let snapshot = LibrarySnapshot(
        savedAt: .now,
        artists: [Artist(id: "1", name: "Björk"), Artist(id: "2", name: "Bjork Tribute"), Artist(id: "3", name: "Miles Davis")],
        latestAlbums: [Album(id: "r1", name: "Kind of Blue", artist: "Miles Davis", artistID: "3")],
        playlists: [Playlist(id: "p1", name: "Running"), Playlist(id: "p2", name: "Late Night Running")],
        allAlbums: [Album(id: "a1", name: "Blue Train"), Album(id: "r1", name: "Kind of Blue", artistID: "3"),
                    Album(id: "a2", name: "Blue")],
        allSongs: []
    )

    @Test func theSameNameFirstThenItsStartThenTheRest() {
        let lists = SavedLibrary.lists(from: snapshot)
        #expect(LibraryMatching.rank(lists.albums, name: \.name, matching: " blue ").map(\.id) == ["a2", "a1", "r1"])
        // Accents and case don't matter.
        #expect(LibraryMatching.rank(lists.artists, name: \.name, matching: "BJORK").map(\.id) == ["1", "2"])
        #expect(LibraryMatching.rank(lists.playlists, name: \.name, matching: "running").map(\.id) == ["p1", "p2"])
        #expect(LibraryMatching.rank(lists.playlists, name: \.name, matching: "jazz").isEmpty)
        #expect(LibraryMatching.rank(lists.playlists, name: \.name, matching: "  ").isEmpty)
    }

    @Test func albumsAreOncePerIDAndArtistsFollowTheLatestAlbums() {
        let lists = SavedLibrary.lists(from: snapshot)
        #expect(lists.albums.map(\.id) == ["a1", "r1", "a2"])
        #expect(LibraryMatching.recentArtists(lists).map(\.name) == ["Miles Davis"])
    }

    /// A combined name's artists share the server's ID: each name is its own entity, and opens by that ID.
    @Test func eachNameOfACombinedArtistIsItsOwn() {
        let split = LibrarySnapshot(
            savedAt: .now,
            artists: [Artist(id: "sg", name: "Simon"), Artist(id: "sg", name: "Garfunkel"), Artist(id: "3", name: "Miles Davis")],
            latestAlbums: [Album(id: "b", name: "Bookends", artistID: "sg"), Album(id: "r1", name: "Kind of Blue", artistID: "3")],
            playlists: [],
            allAlbums: [],
            allSongs: []
        )
        let lists = SavedLibrary.lists(from: split)
        #expect(LibraryMatching.recentArtists(lists).map(\.name) == ["Simon", "Garfunkel", "Miles Davis"])
        let entities = lists.artists.map(ArtistEntity.init)
        #expect(Set(entities.map(\.id)).count == 3)
        #expect(entities.map(\.artistID) == ["sg", "sg", "3"])
    }

    /// A saved Shortcut's artist: by its key, its bare server ID, or (renamed since) the key's server ID.
    @Test func aSavedArtistResolvesAfterItsNameChanges() {
        let entities = [ArtistEntity(artistID: "sg", name: "Simon"), ArtistEntity(artistID: "sg", name: "Garfunkel"),
                        ArtistEntity(artistID: "3", name: "Miles Davis")]
        let found = ArtistQuery.resolve(["sg|Garfunkel", "3", "3|Miles Davis Quintet", "gone|Nobody"], among: entities)
        #expect(found.map(\.id) == ["sg|Garfunkel", "3|Miles Davis", "3|Miles Davis"])
    }

    @Test func theServersFindsAreKeptLast() {
        let albums = [Album(id: "x", name: "Something Else"), Album(id: "y", name: "Blue")]
        #expect(LibraryMatching.rank(albums, name: \.name, matching: "blue", keepsUnmatched: true).map(\.id) == ["y", "x"])
    }
}

@MainActor
struct PlaybackReadinessTests {
    private let a = UUID()
    private let b = UUID()
    private let config = ServerConfig(serverURL: "https://music.example", username: "u", password: "p")

    @Test func applyingTheSameConnectionTwiceOnlyConnectsAgain() {
        let signedIn = PlaybackConnection(profileID: a, state: .authenticated, config: config)
        let first = PlaybackConnection.steps(from: signedIn, to: signedIn, windowless: false)
        #expect(first == [.connect(full: true), .sweepOrphans])
        #expect(PlaybackConnection.steps(from: signedIn, to: signedIn, windowless: false) == first)
    }

    @Test func withNoWindowOnlyWhatPlayingNeeds() {
        let signedIn = PlaybackConnection(profileID: a, state: .authenticated, config: config)
        #expect(PlaybackConnection.steps(from: signedIn, to: signedIn, windowless: true) == [.connect(full: false)])
        let offline = PlaybackConnection(profileID: a, state: .offlineMode)
        #expect(PlaybackConnection.steps(from: offline, to: offline, windowless: true) == [.connectOffline])
    }

    @Test func theOldServersResetComesBeforeTheNewConnect() {
        let onA = PlaybackConnection(profileID: a, state: .authenticated, config: config)
        let onB = PlaybackConnection(profileID: b, state: .authenticated, config: config)
        let out = PlaybackConnection(profileID: nil, state: .unauthenticated)
        #expect(PlaybackConnection.steps(from: onA, to: onB, windowless: false) == [.resetPlayer, .connect(full: true), .sweepOrphans])
        #expect(PlaybackConnection.steps(from: onA, to: out, windowless: false) == [.resetPlayer, .deactivateDownloads])
        // Signing in from nothing isn't a change of server.
        #expect(PlaybackConnection.steps(from: out, to: onA, windowless: false) == [.connect(full: true), .sweepOrphans])
        // Checking the saved server: nothing yet.
        let checking = PlaybackConnection(profileID: a, state: .authenticating)
        #expect(PlaybackConnection.steps(from: out, to: checking, windowless: false).isEmpty)
    }

    /// Edit Server to another account keeps the profile ID: still another account's player to reset.
    @Test func anotherAccountUnderTheSameProfileResetsThePlayer() {
        let before = PlaybackConnection(profileID: a, state: .authenticated, config: config, account: "a-one")
        let edited = PlaybackConnection(profileID: a, state: .authenticated, config: config, account: "a-two")
        #expect(PlaybackConnection.steps(from: before, to: edited, windowless: false) == [.resetPlayer, .connect(full: true), .sweepOrphans])
        // A new password is the same account.
        let newPassword = ServerConfig(serverURL: "https://music.example", username: "u", password: "q")
        let relogged = PlaybackConnection(profileID: a, state: .authenticated, config: newPassword, account: "a-one")
        #expect(PlaybackConnection.steps(from: before, to: relogged, windowless: false) == [.connect(full: true), .sweepOrphans])
    }

    @Test func readyTwiceSignsInOnceAndAppliesEachTime() async {
        let (account, pings) = Self.signedInAccount()
        var applied = 0
        let readiness = PlaybackReadiness(account: account) { applied += 1 }
        readiness.isBeforeFirstUnlock = { false }
        #expect(await readiness.ensureReady() == .online)
        #expect(await readiness.ensureReady() == .online)
        #expect(applied == 2)
        #expect(pings.count == 1)
    }

    @Test func beforeTheFirstUnlockNothingIsRead() async {
        let (account, pings) = Self.signedInAccount()
        let readiness = PlaybackReadiness(account: account) {}
        readiness.isBeforeFirstUnlock = { true }
        #expect(await readiness.ensureReady() == .locked)
        // The app still signs in normally once it can.
        #expect(account.state == .unknown)
        #expect(pings.count == 0)
    }

    /// C46 (D163): the check is for a start only. Once the app has its login, a phone locked again
    /// (a request from the lock screen, AirPods or CarPlay) plays.
    @Test func aRunningAppIsReadyWhateverTheLockSays() async {
        let (account, _) = Self.signedInAccount()
        let readiness = PlaybackReadiness(account: account) {}
        readiness.isBeforeFirstUnlock = { false }
        #expect(await readiness.ensureReady() == .online)
        readiness.isBeforeFirstUnlock = { true }
        #expect(await readiness.ensureReady() == .online)
    }

    @Test func signedOutSaysSo() async {
        let defaults = UserDefaults(suiteName: "IntentTests.\(UUID().uuidString)")!
        let account = AccountModel(store: ProfileStore(defaults: defaults, secrets: InMemorySecretStore()), transport: PingCounter())
        let readiness = PlaybackReadiness(account: account) {}
        readiness.isBeforeFirstUnlock = { false }
        #expect(await readiness.ensureReady() == .signedOut)
    }

    @Test func aServerThatDoesntAnswerStopsWaiting() async {
        let (account, _) = Self.signedInAccount(answers: false)
        let readiness = PlaybackReadiness(account: account) {}
        readiness.isBeforeFirstUnlock = { false }
        readiness.limit = .milliseconds(300)
        #expect(await readiness.ensureReady() == .unreachable(canGoOffline: false))
    }

    /// An account saved as signed in, its server answering (or not) and counting the pings.
    private static func signedInAccount(answers: Bool = true) -> (AccountModel, PingCounter) {
        let defaults = UserDefaults(suiteName: "IntentTests.\(UUID().uuidString)")!
        let store = ProfileStore(defaults: defaults, secrets: InMemorySecretStore())
        let profile = store.save(ServerProfile(serverURL: "https://music.example", username: "u"), password: "pw")
        store.setActive(profile, password: "pw")
        let pings = PingCounter(answers: answers)
        let account = AccountModel(
            store: store, transport: pings, verifyAttempts: 1, verifyTimeout: .seconds(2), retryDelay: .milliseconds(1)
        )
        return (account, pings)
    }
}

/// A server whose `ping` answers ok (or never, while it counts).
private final class PingCounter: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var seen = 0
    let answers: Bool

    init(answers: Bool = true) {
        self.answers = answers
    }

    var count: Int { lock.withLock { seen } }

    func get(_ url: URL, timeout: TimeInterval) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { seen += 1 }
        guard answers else {
            try await Task.sleep(for: .seconds(30))
            throw URLError(.timedOut)
        }
        let body = #"{"subsonic-response":{"status":"ok","version":"1.16.1","type":"navidrome","serverVersion":"0.64.2","openSubsonic":true}}"#
        return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
