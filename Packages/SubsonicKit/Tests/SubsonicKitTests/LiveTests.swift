import Foundation
import Testing
@testable import SubsonicKit

/// Read-only calls against a real server. Skipped unless `SUBSONICKIT_LIVE` names a JSON file
/// (kept outside the repo) like `{"url": "…", "username": "…", "password": "…"}`. Run with
/// `TEST_RUNNER_SUBSONICKIT_LIVE=/path/to/login.json xcodebuild test …` (see README.md).
@Suite(.enabled(if: LiveLogin.load() != nil, "set SUBSONICKIT_LIVE to run"))
struct LiveTests {
    let login = LiveLogin.load()!

    func client(legacy: Bool = false) throws -> SubsonicClient {
        let config = ServerConfig(serverURL: login.url, username: login.username, password: login.password, sendsPlainPassword: legacy)
        return try SubsonicClient(config: config, coverArtSalt: SubsonicClient.makeCoverArtSalt())
    }

    @Test func tokenAuthPingAndBrowse() async throws {
        let client = try client()
        let info = try await client.ping()
        #expect(info.type == "navidrome")

        let artists = try await client.artists()
        #expect(!artists.isEmpty)
        let albums = try await client.albumList(.alphabeticalByName, size: 5)
        let album = try await client.album(id: try #require(albums.first).id)
        #expect(!album.songs.isEmpty)
        _ = try await client.search(try #require(artists.first).name)
        _ = try await client.playlists()
        _ = try await client.starred()
        _ = try await client.musicFolders()
        _ = try await client.lyricsBySongID(try #require(album.songs.first).id)
    }

    /// The password goes in the URL as-is, so this also checks the encoding of `&`, `%` and the like.
    @Test func legacyAuthPing() async throws {
        #expect(try await client(legacy: true).ping().type == "navidrome")
    }

    @Test func wrongPasswordIsCode40() async throws {
        let config = ServerConfig(serverURL: login.url, username: login.username, password: login.password + "x")
        let client = try SubsonicClient(config: config, coverArtSalt: "s")
        await #expect(throws: SubsonicError.api(code: 40, message: "Wrong username or password")) {
            try await client.ping()
        }
    }

    @Test func coverArtLoads() async throws {
        let client = try client()
        let album = try #require(try await client.albumList(.newest, size: 1).first)
        let url = try #require(client.coverArtURL(album.coverArt, size: 300))
        let (data, response) = try await URLSession.shared.data(from: url)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(response.mimeType?.hasPrefix("image/") == true)
        #expect(!data.isEmpty)
    }
}

struct LiveLogin: Decodable {
    let url: String
    let username: String
    let password: String

    static func load(variable: String = "SUBSONICKIT_LIVE") -> LiveLogin? {
        guard let path = ProcessInfo.processInfo.environment[variable],
              let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode(LiveLogin.self, from: data)
    }
}
