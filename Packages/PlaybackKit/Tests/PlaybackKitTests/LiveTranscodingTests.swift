import AVFoundation
import Foundation
import Testing
import SubsonicKit
@testable import PlaybackKit

/// Which of the Format setting's choices `AVPlayer` really plays from Navidrome (C11). Read-only: it
/// streams a few seconds of a song, and never scrobbles. Skipped without the login file named by
/// `TEST_RUNNER_PLAYBACKKIT_LIVE`, as `LiveGaplessTests`.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["PLAYBACKKIT_LIVE"] != nil))
struct LiveTranscodingTests {
    private struct Login: Decodable {
        let url: String
        let username: String
        let password: String
    }

    private func client() throws -> SubsonicClient {
        let path = try #require(ProcessInfo.processInfo.environment["PLAYBACKKIT_LIVE"])
        let login = try JSONDecoder().decode(Login.self, from: Data(contentsOf: URL(filePath: path)))
        return try SubsonicClient(
            config: ServerConfig(serverURL: login.url, username: login.username, password: login.password),
            coverArtSalt: "livetestsalt1234"
        )
    }

    private func song(_ client: SubsonicClient) async throws -> Song {
        let albums = try await client.albumList(.alphabeticalByName, size: 50)
        for album in albums {
            if let song = try await client.albumSongs(albumID: album.id).first(where: { ($0.duration ?? 0) > 20 }) {
                return song
            }
        }
        throw CancellationError()
    }

    /// Plays `url` until 2 seconds have passed in the song, or it fails, or 30 seconds go by.
    private func plays(_ url: URL) async -> Bool {
        let player = AVPlayer(url: url)
        player.volume = 0
        player.play()
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(30)
        while clock.now < deadline {
            if player.currentItem?.status == .failed { return false }
            if player.currentTime().seconds >= 2 { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return false
    }

    /// The settings' choices as `TranscodingSettings` turns them into requests.
    @Test(arguments: [
        ("original", 0, "raw"),
        ("mp3 128", 128, "mp3"),
        ("aac 128", 128, "aac"),
        ("opus 128", 128, "opus"),
        ("server's choice 128", 128, "raw"),
    ])
    func formatPlays(_ name: String, _ bitRate: Int, _ format: String) async throws {
        let client = try client()
        let song = try await song(client)
        var settings = TranscodingSettings()
        settings.isEnabled = true
        settings.wifiBitRate = bitRate
        settings.format = format
        let options = settings.streamOptions(onMobileData: false)
        let url = client.streamURL(songID: song.id, maxBitRate: options.maxBitRate, format: options.format)
        let played = await plays(url)
        print("LiveTranscodingTests: \(name) → \(options) plays: \(played)")
        #expect(played, "\(name) didn't play")
    }
}
