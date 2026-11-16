import Foundation
import SubsonicKit
import Testing
@testable import PlaybackKit

/// Downloaded songs and offline mode (C10).
@MainActor
@Suite struct OfflinePlaybackTests {
    private func file(_ id: String) -> URL {
        URL(filePath: "/downloads/\(id).mp3")
    }

    @Test func aDownloadedSongPlaysFromItsFileEvenOnline() throws {
        let rig = try Rig()
        rig.player.localFile = { $0.id == "a" ? file($0.id) : nil }
        rig.player.playSong(song("a"), playlist: songs("a", "b"))
        #expect(rig.engine.loaded.last == file("a"))
        // The next one isn't downloaded, so it's lined up from the server.
        #expect(rig.engine.nextSongID == "b")
        #expect(rig.engine.next?.lastPathComponent == "stream")
    }

    /// The audit's P5: "Open in offline mode" while a stream is lined up next lines up the next
    /// song's file instead, or nothing if it isn't downloaded.
    @Test func goingOfflineLinesTheNextSongUpAgain() throws {
        let rig = try Rig()
        rig.player.playSong(song("a"), playlist: songs("a", "b", "c"))
        #expect(rig.engine.next?.lastPathComponent == "stream")
        rig.player.localFile = { $0.id == "b" ? file($0.id) : nil }
        rig.player.connectOffline(profileID: "profile")
        #expect(rig.engine.next == file("b"))

        let other = try Rig()
        other.player.playSong(song("a"), playlist: songs("a", "b"))
        other.player.localFile = { _ in nil }
        other.player.connectOffline(profileID: "profile")
        #expect(other.engine.next == nil)
    }

    @Test func aLocalFileIsNeverTranscoded() throws {
        let rig = try Rig()
        rig.defaults.set(true, forKey: "transcoding_enabled")
        rig.player.localFile = { file($0.id) }
        rig.player.playSong(song("a"))
        #expect(rig.engine.loaded.last == file("a"))
    }

    @Test func offlineWithoutAServerOnlyDownloadedSongsPlay() throws {
        let rig = try Rig(connects: false)
        rig.player.connectOffline(profileID: "profile")
        rig.player.localFile = { ["b", "d"].contains($0.id) ? file($0.id) : nil }
        rig.player.playSong(song("a"), playlist: songs("a", "b", "c", "d"))
        // "a" isn't downloaded, so it's skipped.
        #expect(rig.player.currentSong?.id == "b")
        #expect(rig.engine.loaded == [file("b")])
        #expect(rig.player.isPlaying)
        // "c" can't be lined up; when "b" ends, it's skipped too.
        #expect(rig.engine.next == nil)
        rig.engine.send(.ended)
        #expect(rig.player.currentSong?.id == "d")
        #expect(rig.engine.loaded.last == file("d"))
    }

    @Test func offlineWithNothingDownloadedPlaybackStops() throws {
        let rig = try Rig(connects: false)
        rig.player.connectOffline(profileID: "profile")
        rig.player.localFile = { _ in nil }
        rig.player.playSong(song("a"), playlist: songs("a", "b"))
        #expect(rig.engine.loaded.isEmpty)
        #expect(!rig.player.isPlaying)
        #expect(!rig.player.isLoading)
    }

    /// A song ending with nothing after it downloaded ends the queue as usual (D25), so Play starts
    /// it over rather than sitting on a song that can't play.
    @Test func endingBeforeSongsNotDownloadedEndsTheQueue() throws {
        let rig = try Rig(connects: false)
        rig.player.connectOffline(profileID: "profile")
        rig.player.localFile = { ["a", "b"].contains($0.id) ? file($0.id) : nil }
        rig.player.playSong(song("a"), playlist: songs("a", "b", "c"))
        rig.engine.send(.advanced)
        #expect(rig.player.currentSong?.id == "b" && rig.engine.next == nil)
        rig.engine.send(.ended)
        #expect(rig.player.currentSong?.id == "a")
        #expect(!rig.player.isPlaying && !rig.player.isLoading)
        rig.player.play()
        #expect(rig.engine.loaded.last == file("a") && rig.player.isPlaying)
    }

    @Test func skippingWrapsOnlyWithRepeatAll() throws {
        let rig = try Rig(connects: false)
        rig.player.connectOffline(profileID: "profile")
        rig.player.localFile = { $0.id == "a" ? file($0.id) : nil }
        rig.player.playSong(song("b"), playlist: songs("a", "b", "c"))
        #expect(rig.engine.loaded.isEmpty)

        rig.player.changeRepeat(.all)
        rig.player.playSong(song("c"), playlist: songs("a", "b", "c", "x"))
        #expect(rig.player.currentSong?.id == "a")
    }

    @Test func offlineBringsBackTheSavedQueue() async throws {
        let first = try Rig()
        first.player.playSong(song("b"), playlist: songs("a", "b"))
        first.player.pause()
        let store = PlayerStore(defaults: first.defaults, queueFile: first.queueFile)
        #expect(await eventually { store.loadQueue()?.queue.currentSongID == "b" })

        let second = try Rig(defaults: first.defaults, queueFile: first.queueFile, connects: false)
        second.player.connectOffline(profileID: "profile")
        #expect(second.player.queue.map(\.id) == ["a", "b"])
        #expect(second.player.currentSong?.id == "b")
        #expect(!second.player.isPlaying)
    }

    @Test func offlinePlaysWaitAndGoWithTheirTimeWhenTheServerIsBack() async throws {
        let rig = try Rig(connects: false)
        rig.player.connectOffline(profileID: "profile")
        rig.player.localFile = { file($0.id) }
        rig.player.playSong(song("a"), playlist: songs("a", "b"))
        rig.engine.startSounding()
        rig.clock.advance(150)
        let playedAt = rig.clock.date
        rig.engine.send(.advanced)
        let store = PlayerStore(defaults: rig.defaults, queueFile: rig.queueFile)
        let waiting = store.heldScrobbles(profileID: "profile")
        #expect(waiting.map(\.songID) == ["a", "a", "b"])
        #expect(waiting.first { $0.submission }?.time == playedAt)
        #expect(rig.server.requests.isEmpty)

        // The server comes back: the play goes, the "now playing" notices don't.
        rig.player.connect(client: try makeClient(server: rig.server), profileID: "profile")
        #expect(await eventually { store.heldScrobbles(profileID: "profile").isEmpty })
        #expect(rig.server.scrobbles == ["a:true"])
        #expect(rig.server.calls(to: "scrobble").first?.params["time"] == String(Int64(playedAt.timeIntervalSince1970 * 1000)))
        // Same server: the queue stays as it is.
        #expect(rig.player.currentSong?.id == "b")
    }
}
