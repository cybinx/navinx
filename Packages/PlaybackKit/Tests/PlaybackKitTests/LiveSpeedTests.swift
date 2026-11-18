import AVFoundation
import Foundation
import Testing
import SubsonicKit
@testable import PlaybackKit

/// The real engine at another speed (C18, D87), against a real server. Read-only: it streams, and
/// never scrobbles. Skipped without the login file named by `TEST_RUNNER_PLAYBACKKIT_LIVE`, as
/// `LiveGaplessTests`. It measures the player's timing only: how the pitch sounds needs ears.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["PLAYBACKKIT_LIVE"] != nil))
struct LiveSpeedTests {
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

    private func pair(_ client: SubsonicClient) async throws -> [Song] {
        let albums = try await client.albumList(.alphabeticalByName, size: 50)
        for album in albums {
            let songs = try await client.albumSongs(albumID: album.id)
            if songs.count >= 2, (songs[0].duration ?? 0) > 20, (songs[1].duration ?? 0) > 20 {
                return Array(songs.prefix(2))
            }
        }
        throw CancellationError()
    }

    /// At 1.5×: the player runs at 1.5, the song's clock moves 1.5 s a second, both items stretch
    /// with the pitch kept, the change to the next song keeps the speed, and switching
    /// "Preserve pitch" off changes the mode without stopping. Then a pause stays a pause.
    @Test func oneAndAHalfTimes() async throws {
        let client = try client()
        let pair = try await pair(client)
        let rate = 1.5
        let engine = QueuePlayerEngine()
        engine.volume = 0
        engine.setRate(Float(rate), preservesPitch: true)

        let clock = ContinuousClock()
        var advancedAt: ContinuousClock.Instant?
        var realDuration: TimeInterval = 0
        var ticksBefore: [(at: ContinuousClock.Instant, position: TimeInterval)] = []
        var ticksAfter: [(at: ContinuousClock.Instant, position: TimeInterval)] = []
        var isBuffering = false
        engine.onEvent = { event in
            switch event {
            case .advanced: advancedAt = clock.now
            case .duration(let seconds): if advancedAt == nil { realDuration = seconds }
            case .buffering(let buffering): isBuffering = buffering
            case .position(let seconds) where seconds > 0 && !isBuffering:
                if advancedAt == nil { ticksBefore.append((clock.now, seconds)) } else { ticksAfter.append((clock.now, seconds)) }
            default: break
            }
        }

        let length = TimeInterval(pair[0].duration ?? 0)
        engine.load(client.streamURL(songID: pair[0].id), start: max(length - 9, 0), next: client.streamURL(songID: pair[1].id))
        engine.play()

        #expect(await eventually(.seconds(20)) { ticksBefore.count > 4 })
        #expect(engine.playerRate == Float(rate))
        #expect(engine.currentPitchAlgorithm == .spectral)
        #expect(engine.nextPitchAlgorithm == .spectral)

        #expect(await eventually(.seconds(40)) { advancedAt != nil })
        #expect(await eventually(.seconds(8)) { ticksAfter.count > 6 })
        #expect(engine.playerRate == Float(rate), "the next song dropped the speed")

        // Song seconds a wall second, over the first song's steady part.
        let steady = Array(ticksBefore.dropFirst(2))
        if let first = steady.first, let last = steady.last, last.at > first.at {
            let speed = (last.position - first.position) / ((last.at - first.at) / .seconds(1))
            print("LiveSpeedTests: song seconds per second \(speed)")
            #expect(abs(speed - rate) < 0.15)
        }

        // The seam, as `LiveGaplessTests`, with song time turned into wall time.
        let last = try #require(ticksBefore.last)
        let songEnd = last.at + .seconds((realDuration - last.position) / rate)
        let seams = ticksAfter.dropFirst().map { ((($0.at - .seconds($0.position / rate)) - songEnd) / .seconds(1)) }
        let seam = seams.sorted()[seams.count / 2]
        print("LiveSpeedTests: seam at \(rate)×: \(seam) s")
        // Away from 1×, `AVQueuePlayer` holds the next song at its start for about 0.3 s, with any
        // pitch algorithm (C18, `docs/gotchas.md`); at 1× the seam is under a millisecond. This
        // catches it getting worse, not the gap itself.
        #expect(abs(seam) < 0.5, "a longer gap between the songs at \(rate)×")

        // "Preserve pitch" off, while playing.
        engine.setRate(Float(rate), preservesPitch: false)
        #expect(engine.currentPitchAlgorithm == .varispeed)
        let before = ticksAfter.count
        #expect(await eventually(.seconds(3)) { ticksAfter.count > before + 3 })
        #expect(engine.playerRate == Float(rate))

        // A speed change while paused doesn't start it.
        engine.pause()
        engine.setRate(2, preservesPitch: true)
        try await Task.sleep(for: .milliseconds(500))
        #expect(engine.playerRate == 0)
        engine.play()
        #expect(await eventually(.seconds(5)) { engine.playerRate == 2 })
        engine.stop()
    }

    /// A transcoded stream with no length (Opus in Ogg, C11) at 2×: it shouldn't stall or drop to 1×.
    @Test func aTranscodedStreamAtTwice() async throws {
        let client = try client()
        let song = try await pair(client)[1]  // not the song `LiveTranscodingTests` streams at the same time
        let engine = QueuePlayerEngine()
        engine.volume = 0
        engine.setRate(2, preservesPitch: true)
        let clock = ContinuousClock()
        var ticks: [(at: ContinuousClock.Instant, position: TimeInterval)] = []
        var isBuffering = false
        var failure: String?
        engine.onEvent = { event in
            switch event {
            case .buffering(let buffering): isBuffering = buffering
            case .failed(let message, _): failure = message
            case .position(let seconds) where seconds > 0 && !isBuffering: ticks.append((clock.now, seconds))
            default: break
            }
        }
        engine.load(client.streamURL(songID: song.id, maxBitRate: 128, format: "opus"), start: 0, next: nil)
        engine.play()
        #expect(await eventually(.seconds(30)) { ticks.count > 16 || failure != nil })
        engine.stop()
        #expect(failure == nil)
        let steady = Array(ticks.dropFirst(2))
        let first = try #require(steady.first)
        let last = try #require(steady.last)
        let speed = (last.position - first.position) / ((last.at - first.at) / .seconds(1))
        print("LiveSpeedTests: transcoded song seconds per second \(speed)")
        #expect(abs(speed - 2) < 0.2)
    }
}
