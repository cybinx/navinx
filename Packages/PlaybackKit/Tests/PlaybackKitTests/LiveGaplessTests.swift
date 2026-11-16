import Foundation
import Testing
import SubsonicKit
@testable import PlaybackKit

/// Measures a song change on the real engine against a real server. Read-only: it streams, and never
/// scrobbles. Skipped without a login file, the same JSON as `SubsonicKit`'s live tests, named by
/// `TEST_RUNNER_PLAYBACKKIT_LIVE` (`PLAYBACKKIT_LIVE` inside the test).
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["PLAYBACKKIT_LIVE"] != nil))
struct LiveGaplessTests {
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

    /// Plays the last 4 seconds of a song and times how far the handover is from the song's end.
    /// This measures the player's timing only: an audible gap needs ears.
    @Test func theSongChangeLandsOnTheEndOfTheSong() async throws {
        let client = try client()
        let albums = try await client.albumList(.alphabeticalByName, size: 50)
        var pair: [Song] = []
        for album in albums {
            let songs = try await client.albumSongs(albumID: album.id)
            if songs.count >= 2, (songs[0].duration ?? 0) > 10 {
                pair = Array(songs.prefix(2))
                break
            }
        }
        try #require(pair.count == 2, "No album with two songs")

        let engine = QueuePlayerEngine()
        var advancedAt: ContinuousClock.Instant?
        var startedAt: ContinuousClock.Instant?
        var startPosition: TimeInterval = 0
        var isBuffering = false
        var realDuration: TimeInterval = 0
        var stalled = false
        let clock = ContinuousClock()
        // Where each song's own timeline is, when: the seam is the time between one ending and the next starting.
        var ticksBefore: [(at: ContinuousClock.Instant, position: TimeInterval)] = []
        var ticksAfter: [(at: ContinuousClock.Instant, position: TimeInterval)] = []
        engine.onEvent = { event in
            if case .position(let seconds) = event, seconds > 0 {
                if advancedAt == nil {
                    ticksBefore.append((clock.now, seconds))
                } else {
                    ticksAfter.append((clock.now, seconds))
                }
            }
            switch event {
            case .advanced: advancedAt = clock.now
            case .duration(let seconds): if advancedAt == nil { realDuration = seconds }
            case .buffering(let buffering):
                isBuffering = buffering
                if buffering, startedAt != nil, advancedAt == nil { stalled = true }
            case .position(let seconds):
                if startedAt == nil, seconds > 0, !isBuffering, realDuration > 0 {
                    startedAt = clock.now
                    startPosition = seconds
                }
            default: break
            }
        }

        let length = TimeInterval(pair[0].duration ?? 0)
        engine.load(client.streamURL(songID: pair[0].id), start: max(length - 4, 0), next: client.streamURL(songID: pair[1].id))
        engine.play()

        #expect(await eventually(.seconds(40)) { advancedAt != nil })

        // A few of the next song's reports, for the seam.
        #expect(await eventually(.seconds(5)) { ticksAfter.count > 4 })
        engine.stop()

        // By the player's own clock. This is what caught an audio tap opening a gap (D45).
        let last = try #require(ticksBefore.last)
        let songEnd = last.at + .seconds(realDuration - last.position)
        let seams = ticksAfter.dropFirst().map { ((($0.at - .seconds($0.position)) - songEnd) / .seconds(1)) }
        let seam = seams.sorted()[seams.count / 2]
        print("Seam: \(seam) s")
        #expect(abs(seam) < 0.05, "a gap between the songs")
        let started = try #require(startedAt)
        let advanced = try #require(advancedAt)
        let played = (advanced - started) / .seconds(1)
        let expected = realDuration - startPosition
        let difference = played - expected
        print("Gapless timing: \(pair[0].suffix ?? "?"), played \(played)s, expected \(expected)s, off by \(difference)s, stalled: \(stalled)")
        #expect(!stalled, "The next song wasn't ready in time")
        #expect(abs(difference) < 0.5)
    }
}
