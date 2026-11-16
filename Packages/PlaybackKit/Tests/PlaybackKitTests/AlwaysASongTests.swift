import Foundation
import SubsonicKit
import Testing
@testable import PlaybackKit

/// D81: the mini-player always has a song. With nothing queued, one is loaded, paused, from the
/// server's recently played albums, then a random song, then the downloads; and clearing or ending a
/// queue leaves a song loaded.
@MainActor
@Suite struct AlwaysASongTests {
    /// A server whose newest recently played album is "al1" with the songs "s1" and "s2".
    private func serverWithRecentAlbum(_ rig: Rig, album: String = "al1", songs: [String] = ["s1", "s2"]) {
        rig.server.stubPayload("getAlbumList2", #","albumList2":{"album":[{"id":"\#(album)","name":"Album \#(album)"}]}"#)
        let list = songs.map { #"{"id":"\#($0)","title":"Song \#($0)","duration":180}"# }.joined(separator: ",")
        rig.server.stubPayload("getAlbum", #","album":{"id":"\#(album)","name":"Album \#(album)","song":[\#(list)]}"#)
    }

    private func connect(_ rig: Rig, profile: String = "profile") throws {
        rig.player.connect(client: try makeClient(server: rig.server), profileID: profile)
    }

    // MARK: Choosing the song

    @Test func theNewestRecentlyPlayedAlbumsFirstSongIsLoadedPaused() async throws {
        let rig = try Rig(connects: false)
        serverWithRecentAlbum(rig)
        try connect(rig)
        #expect(await eventually { rig.player.currentSong?.id == "s1" })
        #expect(rig.player.queue.map(\.id) == ["s1"])
        #expect(rig.player.duration == 180 && rig.player.position == 0)
        #expect(!rig.player.isPlaying && !rig.player.isLoading)
        // The newest one: a page of one, by recently played.
        let asked = rig.server.calls(to: "getAlbumList2").first?.params
        #expect(asked?["type"] == "recent" && asked?["size"] == "1")
    }

    @Test func loadingItMakesNoSoundNoPlayAndNoNowPlayingNotice() async throws {
        let rig = try Rig(connects: false)
        serverWithRecentAlbum(rig)
        var changes = 0
        rig.player.onNowPlayingChange = { changes += 1 }
        var heard: [ListenEvent] = []
        rig.player.onListen = { heard.append($0) }
        try connect(rig)
        #expect(await eventually { rig.player.currentSong != nil })
        try await Task.sleep(for: .milliseconds(150))
        #expect(rig.engine.loaded.isEmpty && !rig.engine.hasItem && !rig.engine.isPlaying)
        #expect(rig.server.scrobbles.isEmpty)
        #expect(heard.isEmpty)
        #expect(changes >= 1)
    }

    @Test func playingTheSeededSongStartsItLikeARestoredOne() async throws {
        let rig = try Rig(connects: false)
        serverWithRecentAlbum(rig)
        try connect(rig)
        #expect(await eventually { rig.player.currentSong?.id == "s1" })
        rig.player.play()
        #expect(rig.engine.loadedSongIDs == ["s1"] && rig.engine.loadStarts == [0])
        #expect(rig.player.isPlaying)
        // Only now does the server hear about it.
        rig.engine.startSounding()
        #expect(await eventually { rig.server.scrobbles.contains("s1:false") })
    }

    @Test func withNoRecentAlbumARandomSongIsLoaded() async throws {
        let rig = try Rig(connects: false)
        rig.server.stubSongs("getRandomSongs", key: "randomSongs", ids: ["r1"])
        try connect(rig)
        #expect(await eventually { rig.player.currentSong?.id == "r1" })
        #expect(!rig.player.isPlaying && rig.engine.loaded.isEmpty)
    }

    @Test func aRecentAlbumWithNoSongsFallsBackToARandomSong() async throws {
        let rig = try Rig(connects: false)
        serverWithRecentAlbum(rig, songs: [])
        rig.server.stubSongs("getRandomSongs", key: "randomSongs", ids: ["r1"])
        try connect(rig)
        #expect(await eventually { rig.player.currentSong?.id == "r1" })
    }

    /// C30 bug 14: the random song is asked for alongside the album look, so a first set-up has its song
    /// sooner, and the recent album's song still wins when there is one.
    @Test func theRandomSongIsAskedAlongsideAndTheRecentAlbumStillWins() async throws {
        let rig = try Rig(connects: false)
        serverWithRecentAlbum(rig)
        rig.server.stubSongs("getRandomSongs", key: "randomSongs", ids: ["r1"])
        try connect(rig)
        #expect(await eventually { rig.player.currentSong?.id == "s1" })
        #expect(rig.server.calls(to: "getRandomSongs").count == 1)
        #expect(rig.player.queue.map(\.id) == ["s1"])
    }

    @Test func withTheServerOutOfReachTheFirstDownloadedSongIsLoaded() async throws {
        let rig = try Rig(connects: false)
        rig.server.setFailing(true)
        rig.player.offlineSongs = { [song("d1"), song("d2")] }
        try connect(rig)
        #expect(await eventually { rig.player.currentSong?.id == "d1" })
        #expect(!rig.player.isPlaying && rig.engine.loaded.isEmpty)
    }

    @Test func withNothingToShowNothingIsLoaded() async throws {
        let rig = try Rig(connects: false)
        rig.server.setFailing(true)
        try connect(rig)
        #expect(await eventually { rig.server.calls(to: "getRandomSongs").count == 1 })
        try await Task.sleep(for: .milliseconds(100))
        #expect(rig.player.currentSong == nil && rig.player.queue.isEmpty)
    }

    @Test func offlineModeLoadsADownloadedSongWithoutAskingTheServer() async throws {
        let rig = try Rig(connects: false)
        rig.player.offlineSongs = { [song("d1")] }
        rig.player.connectOffline(profileID: "profile")
        #expect(await eventually { rig.player.currentSong?.id == "d1" })
        #expect(rig.server.requests.isEmpty)
    }

    @Test func offlineWithNoDownloadsLoadsNothing() async throws {
        let rig = try Rig(connects: false)
        rig.player.connectOffline(profileID: "profile")
        try await Task.sleep(for: .milliseconds(100))
        #expect(rig.player.currentSong == nil)
    }

    @Test func aLookThatFailedOfflineIsRepeatedWhenTheServerIsBack() async throws {
        let rig = try Rig(connects: false)
        rig.player.connectOffline(profileID: "profile")
        serverWithRecentAlbum(rig)
        try connect(rig)
        #expect(await eventually { rig.player.currentSong?.id == "s1" })
    }

    // MARK: When not to

    @Test func aSavedQueueIsRestoredAndNothingIsAsked() async throws {
        let first = try Rig()
        first.player.playSong(song("a"), playlist: songs("a", "b"))
        first.player.saveNow()
        let store = PlayerStore(defaults: first.defaults, queueFile: first.queueFile)
        #expect(await eventually { store.loadQueue() != nil })

        let second = try Rig(defaults: first.defaults, queueFile: first.queueFile, connects: false)
        serverWithRecentAlbum(second)
        try connect(second)
        try await Task.sleep(for: .milliseconds(100))
        #expect(second.player.queue.map(\.id) == ["a", "b"])
        #expect(second.server.calls(to: "getAlbumList2").isEmpty)
    }

    @Test func anotherServersSavedQueueIsReplacedBySomethingFromThisOne() async throws {
        let first = try Rig()
        first.player.playSong(song("a"))
        first.player.saveNow()
        let store = PlayerStore(defaults: first.defaults, queueFile: first.queueFile)
        #expect(await eventually { store.loadQueue() != nil })

        let second = try Rig(defaults: first.defaults, queueFile: first.queueFile, connects: false)
        serverWithRecentAlbum(second)
        try connect(second, profile: "other")
        #expect(await eventually { second.player.currentSong?.id == "s1" })
        // And it's saved for that server, so the next launch brings it back.
        #expect(await eventually { store.loadQueue()?.profileID == "other" })
    }

    @Test func aSongTheUserStartsMeanwhileWins() async throws {
        let rig = try Rig(connects: false)
        serverWithRecentAlbum(rig)
        try connect(rig)
        rig.player.playSong(song("mine"))
        #expect(await eventually { !rig.server.calls(to: "getAlbum").isEmpty })
        try await Task.sleep(for: .milliseconds(100))
        #expect(rig.player.queue.map(\.id) == ["mine"] && rig.player.isPlaying)
        #expect(rig.engine.loadedSongIDs == ["mine"])
    }

    @Test func aReconnectKeepsWhatIsLoaded() async throws {
        let rig = try Rig(connects: false)
        serverWithRecentAlbum(rig)
        try connect(rig)
        #expect(await eventually { rig.player.currentSong?.id == "s1" })
        serverWithRecentAlbum(rig, album: "al2", songs: ["t1"])
        try connect(rig)
        try await Task.sleep(for: .milliseconds(100))
        #expect(rig.player.currentSong?.id == "s1")
    }

    // MARK: Switching servers

    @Test func switchingServerLoadsASongFromTheNewOne() async throws {
        let rig = try Rig(connects: false)
        serverWithRecentAlbum(rig)
        try connect(rig, profile: "one")
        #expect(await eventually { rig.player.currentSong?.id == "s1" })
        rig.player.reset()
        #expect(rig.player.currentSong == nil)
        serverWithRecentAlbum(rig, album: "al9", songs: ["n1"])
        try connect(rig, profile: "two")
        #expect(await eventually { rig.player.currentSong?.id == "n1" })
    }

    @Test func switchingWhileTheLookIsUnderWayDropsTheOldOne() async throws {
        let rig = try Rig(connects: false)
        serverWithRecentAlbum(rig)
        try connect(rig, profile: "one")
        rig.player.reset()
        serverWithRecentAlbum(rig, album: "al9", songs: ["n1"])
        try connect(rig, profile: "two")
        #expect(await eventually { rig.player.currentSong != nil })
        try await Task.sleep(for: .milliseconds(100))
        #expect(rig.player.currentSong?.id == "n1")
    }

    @Test func signingOutLeavesNothing() async throws {
        let rig = try Rig(connects: false)
        serverWithRecentAlbum(rig)
        try connect(rig)
        #expect(await eventually { rig.player.currentSong != nil })
        rig.player.reset()
        try await Task.sleep(for: .milliseconds(100))
        #expect(rig.player.currentSong == nil)
    }

    // MARK: The song stays

    @Test func theSeededSongIsSavedAndComesBackOnTheNextLaunch() async throws {
        let first = try Rig(connects: false)
        serverWithRecentAlbum(first)
        try connect(first)
        #expect(await eventually { first.player.currentSong?.id == "s1" })
        let store = PlayerStore(defaults: first.defaults, queueFile: first.queueFile)
        #expect(await eventually { store.loadQueue()?.queue.songs.map(\.id) == ["s1"] })

        // A relaunch with the server down: the saved song is back, paused.
        let second = try Rig(defaults: first.defaults, queueFile: first.queueFile, connects: false)
        second.server.setFailing(true)
        try connect(second)
        #expect(second.player.currentSong?.id == "s1")
        #expect(!second.player.isPlaying && second.engine.loaded.isEmpty)
    }

    @Test func theQueueEndingLeavesASongLoaded() throws {
        let rig = try Rig()
        rig.player.playSong(song("b"), playlist: songs("a", "b"), startIndex: 1)
        rig.engine.send(.ended)
        #expect(rig.player.currentSong != nil)
        #expect(!rig.player.isPlaying)
    }

    @Test func nextOnTheLastSongLeavesASongLoaded() throws {
        let rig = try Rig()
        rig.player.playSong(song("a"))
        rig.player.skipNext()
        #expect(rig.player.currentSong?.id == "a" && !rig.player.isPlaying)
    }

    // MARK: Queueing onto the kept song

    @Test func queueingSongsReplacesTheKeptSongAndStartsThem() async throws {
        let rig = try Rig(connects: false)
        serverWithRecentAlbum(rig)
        try connect(rig)
        #expect(await eventually { rig.player.currentSong?.id == "s1" })
        rig.player.queueUpAll(songs("x", "y"))
        // As with an empty queue: the list starts from its first song.
        #expect(rig.player.queue.map(\.id) == ["x", "y"] && rig.player.currentSong?.id == "x")
        #expect(rig.player.isPlaying && rig.engine.loadedSongIDs == ["x"])
    }

    @Test func playNextOntoTheKeptSongStartsIt() async throws {
        let rig = try Rig(connects: false)
        serverWithRecentAlbum(rig)
        try connect(rig)
        #expect(await eventually { rig.player.currentSong?.id == "s1" })
        rig.player.queueUpNext(song("x"))
        #expect(rig.player.queue.map(\.id) == ["x"] && rig.player.isPlaying)
    }

    @Test func queueingOntoASongTheUserPlayedAppendsAsBefore() async throws {
        let rig = try Rig(connects: false)
        serverWithRecentAlbum(rig)
        try connect(rig)
        #expect(await eventually { rig.player.currentSong?.id == "s1" })
        rig.player.play()
        rig.player.pause()
        rig.player.queueUpAll(songs("x"))
        #expect(rig.player.queue.map(\.id) == ["s1", "x"] && rig.player.currentSong?.id == "s1")
    }

    @Test func theKeptSongStaysReplaceableAfterARelaunch() async throws {
        let first = try Rig(connects: false)
        serverWithRecentAlbum(first)
        try connect(first)
        #expect(await eventually { first.player.currentSong?.id == "s1" })
        let store = PlayerStore(defaults: first.defaults, queueFile: first.queueFile)
        #expect(await eventually { store.loadQueue()?.isPlaceholder == true })

        let second = try Rig(defaults: first.defaults, queueFile: first.queueFile)
        #expect(second.player.currentSong?.id == "s1")
        second.player.queueUpAll(songs("x"))
        #expect(second.player.queue.map(\.id) == ["x"])
    }

    @Test func aClearedQueueKeepsASongTheUserCanReplaceToo() throws {
        let rig = try Rig()
        rig.player.playSong(song("b"), playlist: songs("a", "b", "c"), startIndex: 1)
        rig.player.clearQueue()
        rig.player.queueUpAll(songs("x"))
        #expect(rig.player.queue.map(\.id) == ["x"] && rig.player.isPlaying)
    }

    @Test func clearingKeepsTheCurrentSongAndSavesIt() async throws {
        let rig = try Rig()
        rig.player.playSong(song("b"), playlist: songs("a", "b", "c"), startIndex: 1)
        rig.player.clearQueue()
        #expect(rig.player.queue.map(\.id) == ["b"] && !rig.player.isPlaying)
        let store = PlayerStore(defaults: rig.defaults, queueFile: rig.queueFile)
        #expect(await eventually { store.loadQueue()?.queue.songs.map(\.id) == ["b"] })
    }
}
