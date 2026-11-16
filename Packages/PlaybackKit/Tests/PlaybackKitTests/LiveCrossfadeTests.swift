import Foundation
import Testing
import SubsonicKit
@testable import PlaybackKit

/// Measures `CrossfadeEngine` on two real players against a real server (C19). Read-only: it streams
/// and never scrobbles. Skipped without `TEST_RUNNER_PLAYBACKKIT_LIVE`, as `LiveGaplessTests`. Its
/// songs are an album's third and fourth, so it never streams the same song as the other live suites
/// at the same moment (CoreMedia −12640 otherwise).
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["PLAYBACKKIT_LIVE"] != nil))
struct LiveCrossfadeTests {
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
            if songs.count >= 4, (songs[2].duration ?? 0) > 30, (songs[3].duration ?? 0) > 30 {
                return [songs[2], songs[3]]
            }
        }
        throw CancellationError()
    }

    private struct Sample: CustomStringConvertible {
        let at: TimeInterval
        let volumes: [Float]
        let times: [TimeInterval]
        let sounding: [Bool]
        var description: String {
            String(format: "%5.1f  A vol %.2f t %6.2f %@ | B vol %.2f t %6.2f %@", at,
                   volumes[0], times[0], sounding[0] ? "▶︎" : "‖", volumes[1], times[1], sounding[1] ? "▶︎" : "‖")
        }
    }

    private func sample(_ engine: CrossfadeEngine, since start: ContinuousClock.Instant) -> Sample {
        let players = engine.children.map { $0 as! QueuePlayerEngine }
        return Sample(
            at: (ContinuousClock.now - start) / .seconds(1),
            volumes: players.map(\.volume),
            times: players.map { $0.hasItem ? $0.currentSeconds : .nan },
            sounding: players.map(\.isSoundingNow)
        )
    }

    /// A 4 s crossfade, from 8 s before the first song's end: both play during the overlap, the
    /// volumes cross, the old player stops, `.advanced` comes once, at the overlap's start.
    @Test func theSongsOverlap() async throws {
        let client = try client()
        let pair = try await pair(client)
        let engine = CrossfadeEngine()
        let clock = ContinuousClock()
        var advances: [ContinuousClock.Instant] = []
        var ended = false
        engine.onEvent = { event in
            if event == .advanced { advances.append(clock.now) }
            if event == .ended { ended = true }
        }
        let length = TimeInterval(pair[0].duration ?? 0)
        engine.volume = 0.9
        engine.load(client.streamURL(songID: pair[0].id), start: length - 8, next: nil)
        engine.setNext(client.streamURL(songID: pair[1].id), crossfade: Crossfade(length: 4, listedDuration: length))
        engine.play()
        let start = clock.now
        var samples: [Sample] = []
        while clock.now - start < .seconds(14) {
            samples.append(sample(engine, since: start))
            try await Task.sleep(for: .milliseconds(100))
        }
        engine.stop()
        print("LiveCrossfadeTests: overlap\n" + samples.map(\.description).joined(separator: "\n"))

        #expect(advances.count == 1)
        #expect(!ended)
        let both = samples.filter { $0.sounding[0] && $0.sounding[1] }
        let overlap = Double(both.count) / 10
        print("LiveCrossfadeTests: both sounding for \(overlap) s; advanced at \(advances.first.map { ($0 - start) / .seconds(1) } ?? -1) s")
        #expect(overlap > 3 && overlap < 5)
        // Crossing: somewhere in the overlap B is louder than A.
        #expect(both.contains { $0.volumes[1] > $0.volumes[0] } && both.contains { $0.volumes[0] > $0.volumes[1] })
        // At the end only the new song plays, at its full volume.
        let last = try #require(samples.dropLast().last)
        let new = engine.activeIndex
        #expect(last.sounding[new] && !last.sounding[1 - new])
        #expect(abs(last.volumes[new] - 0.9) < 0.001)
    }

    /// A 300 ms fade-out to a pause, then a fade-in: the player keeps sounding while it falls.
    @Test func aPauseFades() async throws {
        let client = try client()
        let pair = try await pair(client)
        let engine = CrossfadeEngine()
        var reports: [Bool] = []
        engine.onEvent = { if case .playing(let playing) = $0 { reports.append(playing) } }
        engine.load(client.streamURL(songID: pair[1].id), start: 10, next: nil)
        engine.play()
        let player = engine.children[engine.activeIndex] as! QueuePlayerEngine
        #expect(await eventually(.seconds(10)) { player.isSoundingNow })
        try await Task.sleep(for: .seconds(1))
        let clock = ContinuousClock()
        let start = clock.now
        engine.pause(fadeOut: 0.3)
        var samples: [Sample] = []
        while clock.now - start < .seconds(0.6) {
            samples.append(sample(engine, since: start))
            try await Task.sleep(for: .milliseconds(50))
        }
        print("LiveCrossfadeTests: fade-out\n" + samples.map(\.description).joined(separator: "\n"))
        let index = engine.activeIndex
        #expect(samples.first?.sounding[index] == true)
        #expect(samples.contains { $0.sounding[index] && $0.volumes[index] < 0.7 && $0.volumes[index] > 0.05 })
        #expect(samples.last?.sounding[index] == false)
        // Nothing said "playing" while it fell.
        #expect(reports.last == false && !reports.dropFirst().contains(true))

        engine.play(fadeIn: 0.3)
        #expect(await eventually(.seconds(3)) { player.volume == 1 && player.isSoundingNow })
        engine.stop()
    }

    /// With no crossfade lined up the engine only forwards: the change is still gapless.
    @Test func offIsStillGapless() async throws {
        let client = try client()
        let pair = try await pair(client)
        let engine = CrossfadeEngine()
        let clock = ContinuousClock()
        var advancedAt: ContinuousClock.Instant?
        var realDuration: TimeInterval = 0
        var before: [(at: ContinuousClock.Instant, position: TimeInterval)] = []
        var after: [(at: ContinuousClock.Instant, position: TimeInterval)] = []
        engine.onEvent = { event in
            switch event {
            case .advanced: advancedAt = clock.now
            case .duration(let seconds): if advancedAt == nil { realDuration = seconds }
            case .position(let seconds) where seconds > 0:
                if advancedAt == nil { before.append((clock.now, seconds)) } else { after.append((clock.now, seconds)) }
            default: break
            }
        }
        let length = TimeInterval(pair[0].duration ?? 0)
        engine.load(client.streamURL(songID: pair[0].id), start: length - 4, next: client.streamURL(songID: pair[1].id))
        engine.play()
        #expect(await eventually(.seconds(40)) { advancedAt != nil })
        #expect(await eventually(.seconds(5)) { after.count > 4 })
        // The other child never loaded anything.
        #expect(!engine.children[1 - engine.activeIndex].hasItem)
        engine.stop()
        let last = try #require(before.last)
        let songEnd = last.at + .seconds(realDuration - last.position)
        let seams = after.dropFirst().map { ((($0.at - .seconds($0.position)) - songEnd) / .seconds(1)) }
        let seam = seams.sorted()[seams.count / 2]
        print("LiveCrossfadeTests: seam with crossfade off \(seam) s")
        #expect(abs(seam) < 0.05)
    }
}
