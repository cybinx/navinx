import Foundation
import Testing
@testable import SubsonicKit

/// The saved play queue (C36): `getPlayQueue` and `savePlayQueue`.
@Suite struct PlayQueueTests {
    @Test func aSavedQueueReadsWithItsSongsPlaceAndTime() async throws {
        let (client, _) = try makeClient(["getPlayQueue": .fixture("Handwritten/getPlayQueue")])
        let queue = try #require(try await client.playQueue())
        #expect(queue.songs.map(\.id) == ["0kxNy5A2f53Hafc1EIwpjH", "7G4qEWlUS3ilmcKpZbmF4E", "4OIqwjDj1oAgRbU6jpTYjY"])
        #expect(queue.songs.first?.title == "She Want Me")
        #expect(queue.currentID == "7G4qEWlUS3ilmcKpZbmF4E")
        #expect(queue.positionMs == 61234)
        #expect(queue.changedBy == "Navinx")
        let changed = try #require(queue.changed)
        #expect(abs(changed.timeIntervalSince(try #require(SubsonicDate.parse("2026-11-13T18:04:11Z")))) < 1)
    }

    /// Navidrome's real answer with nothing saved still has a `playQueue`, with no songs.
    @Test func nothingSavedReadsAsNil() async throws {
        let (client, _) = try makeClient(["getPlayQueue": .fixture("Handwritten/getPlayQueue_empty")])
        #expect(try await client.playQueue() == nil)
        let bare = #"{"subsonic-response":{"status":"ok","version":"1.16.1"}}"#
        let (other, _) = try makeClient(["getPlayQueue": .body(bare)])
        #expect(try await other.playQueue() == nil)
    }

    @Test func savingSendsEachSongInOrderTheCurrentAndThePlace() async throws {
        let ok = Reply.body(#"{"subsonic-response":{"status":"ok","version":"1.16.1"}}"#)
        let (client, transport) = try makeClient(["savePlayQueue": ok])
        try await client.savePlayQueue(songIDs: ["a", "b", "a"], current: "b", positionMs: 61234)
        let url = try #require(transport.requests.first)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.filter { $0.name == "id" }.map(\.value) == ["a", "b", "a"])
        #expect(url.params["current"] == "b" && url.params["position"] == "61234")
    }

    /// An empty `savePlayQueue` deletes the saved queue on Navidrome: never sent.
    @Test func anEmptyQueueIsNeverSent() async throws {
        let (client, transport) = try makeClient()
        try await client.savePlayQueue(songIDs: [], current: nil, positionMs: 0)
        #expect(transport.requests.isEmpty)
    }

    /// A long queue goes as a POST, as a long playlist does.
    @Test func aLongQueueIsPosted() async throws {
        let ok = Reply.body(#"{"subsonic-response":{"status":"ok","version":"1.16.1"}}"#)
        let (client, transport) = try makeClient(["savePlayQueue": ok])
        let ids = (0..<300).map { "song-\($0)-0123456789abcdef" }
        try await client.savePlayQueue(songIDs: ids, current: ids[5], positionMs: 0)
        #expect(transport.posted.count == 1)
    }
}

/// One write as the login (C36, D141: `api`'s own saved queue only): saves a queue, reads it back,
/// then puts back the queue that was there. Skipped unless `SUBSONICKIT_QUEUE_WRITES` names a login
/// file like `SUBSONICKIT_LIVE`'s. Run with `TEST_RUNNER_SUBSONICKIT_QUEUE_WRITES=/path/to/login.json`.
@Suite(.enabled(if: LiveLogin.load(variable: "SUBSONICKIT_QUEUE_WRITES") != nil, "set SUBSONICKIT_QUEUE_WRITES to run"))
struct LivePlayQueueTests {
    @Test func aSavedQueueReadsBackAsSent() async throws {
        let login = try #require(LiveLogin.load(variable: "SUBSONICKIT_QUEUE_WRITES"))
        let config = ServerConfig(serverURL: login.url, username: login.username, password: login.password)
        let client = try SubsonicClient(config: config, coverArtSalt: SubsonicClient.makeCoverArtSalt())
        let before = try await client.playQueue()
        let songs = try await client.randomSongs(size: 3)
        try #require(songs.count == 3)
        let ids = songs.map(\.id)
        let started = Date()
        try await client.savePlayQueue(songIDs: ids, current: ids[1], positionMs: 61234)
        let read = try #require(try await client.playQueue())
        // Put back what was there before reading the results.
        if let before {
            try await client.savePlayQueue(
                songIDs: before.songs.map(\.id), current: before.currentID, positionMs: before.positionMs
            )
        }
        #expect(read.songs.map(\.id) == ids)
        #expect(read.currentID == ids[1])
        #expect(read.positionMs == 61234)
        #expect(read.changedBy == "Navinx")
        let changed = try #require(read.changed)
        #expect(abs(changed.timeIntervalSince(started)) < 120)
        #expect(read.songs[1].title == songs[1].title)
    }
}
