import Foundation
import Testing
import SubsonicKit
@testable import PlaybackKit

/// Checks that scrobbles and favourites really land, by asking the server afterwards. **It writes to
/// the login's account:** one play, and a favourite turned on and off again. Skipped without
/// `TEST_RUNNER_PLAYBACKKIT_WRITES`, a login file as for `LiveGaplessTests`.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["PLAYBACKKIT_WRITES"] != nil))
struct LiveWriteTests {
    private struct Login: Decodable {
        let url: String
        let username: String
        let password: String
    }

    private func client() throws -> SubsonicClient {
        let path = try #require(ProcessInfo.processInfo.environment["PLAYBACKKIT_WRITES"])
        let login = try JSONDecoder().decode(Login.self, from: Data(contentsOf: URL(filePath: path)))
        return try SubsonicClient(
            config: ServerConfig(serverURL: login.url, username: login.username, password: login.password),
            coverArtSalt: "livetestsalt1234"
        )
    }

    /// Real playback through the real player, with the clock moved on so it counts as played.
    @Test func aPlayedSongReachesTheServersRecentList() async throws {
        let client = try client()
        let recent = Set(try await client.albumList(.recent, size: 500).map(\.id))
        let albums = try await client.albumList(.alphabeticalByName, size: 500)
        let album = try #require(albums.first { !recent.contains($0.id) && $0.name != "[Unknown Album]" }, "Every album has been played")
        let songs = try await client.albumSongs(albumID: album.id)
        try #require(!songs.isEmpty)

        let clock = TestClock()
        let player = PlayerModel(
            engine: QueuePlayerEngine(),
            defaults: try #require(UserDefaults(suiteName: "LiveWriteTests-\(UUID().uuidString)")),
            queueFile: FileManager.default.temporaryDirectory.appending(path: "LiveWriteTests-\(UUID().uuidString).json"),
            now: { clock.date }
        )
        player.connect(client: client, profileID: "live")
        player.playInOrder(songs)
        #expect(await eventually(.seconds(20)) { player.isPlaying && !player.isLoading && player.position > 0.5 })

        clock.advance(10_000)
        player.stop()

        var reached = false
        for _ in 0..<20 where !reached {
            try await Task.sleep(for: .milliseconds(500))
            reached = try await client.albumList(.recent, size: 500).contains { $0.id == album.id }
        }
        #expect(reached, "The played album isn't in the server's recent list")
    }

    @Test func aFavouriteReachesTheServerAndComesOffAgain() async throws {
        let client = try client()
        let albums = try await client.albumList(.alphabeticalByName, size: 500)
        let starredBefore = try await client.starred().albums.map(\.id)
        let album = try #require(albums.first { !starredBefore.contains($0.id) }, "Every album is a favourite")

        try await client.star(albumID: album.id)
        let isStarred = try await client.starred().albums.contains { $0.id == album.id }
        try await client.unstar(albumID: album.id)
        let isStillStarred = try await client.starred().albums.contains { $0.id == album.id }

        #expect(isStarred)
        #expect(!isStillStarred)
    }
}
