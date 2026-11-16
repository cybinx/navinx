import Foundation
import Testing
import SubsonicKit
@testable import PlaybackKit

@MainActor
@Suite struct PlayerStartingTests {
    @Test func playingASongLoadsItAndLinesUpTheNext() throws {
        let rig = try Rig()
        rig.player.playSong(song("b"), playlist: songs("a", "b", "c"), startIndex: 1)
        #expect(rig.player.currentSong?.id == "b")
        #expect(rig.engine.loadedSongIDs == ["b"])
        #expect(rig.engine.nextSongID == "c")
        #expect(rig.engine.isPlaying && rig.player.isPlaying && rig.player.isLoading)
        #expect(rig.player.duration == 200)
    }

    @Test func aPlaylistWithoutAnIndexFindsTheSong() throws {
        let rig = try Rig()
        rig.player.playSong(song("c"), playlist: songs("a", "b", "c"))
        #expect(rig.player.currentIndex == 2)
    }

    @Test func aSongAloneBecomesTheQueue() throws {
        let rig = try Rig()
        rig.player.playSong(song("a"))
        #expect(rig.player.queue.map(\.id) == ["a"])
    }

    @Test func aSongAlreadyQueuedIsMovedTo() throws {
        let rig = try Rig()
        rig.player.playSong(song("a"), playlist: songs("a", "b", "c"))
        rig.player.playSong(song("c"))
        #expect(rig.player.queue.count == 3)
        #expect(rig.player.currentIndex == 2)
    }

    @Test func tappingTheCurrentSongInItsListCarriesOn() throws {
        let rig = try Rig()
        let list = songs("a", "b")
        rig.player.playSong(list[0], playlist: list)
        rig.player.pause()
        rig.player.playSong(list[0], playlist: list)
        #expect(rig.engine.loaded.count == 1)
        #expect(rig.player.isPlaying)
    }

    @Test func tappingTheCurrentSongInAnotherListReplacesTheQueue() throws {
        let rig = try Rig()
        rig.player.playSong(song("a"), playlist: songs("a", "b"))
        rig.player.playSong(song("a"), playlist: songs("a", "x", "y"))
        #expect(rig.player.queue.map(\.id) == ["a", "x", "y"])
        #expect(rig.engine.loaded.count == 2)
    }

    @Test func playInOrderRestartsFromTheTopWithShuffleOff() throws {
        let rig = try Rig()
        rig.player.toggleShuffle()
        let list = songs("a", "b", "c")
        rig.player.playInOrder(list)
        rig.player.playInOrder(list)
        #expect(!rig.player.isShuffled)
        #expect(rig.player.queue.map(\.id) == ["a", "b", "c"])
        #expect(rig.player.currentIndex == 0)
        #expect(rig.engine.loaded.count == 2)
    }

    @Test func playShuffledTurnsShuffleOnAndRemembersIt() throws {
        let rig = try Rig()
        rig.player.playShuffled(songs("a", "b", "c"))
        #expect(rig.player.isShuffled)
        #expect(rig.defaults.bool(forKey: "player_shuffle"))
        #expect(rig.player.queue.count == 3)
        #expect(rig.engine.isPlaying)
    }

    @Test func aTappedSongPlaysFirstWithShuffleOn() throws {
        let rig = try Rig()
        rig.player.toggleShuffle()
        let list = songs("a", "b", "c", "d", "e")
        rig.player.playSong(list[3], playlist: list, startIndex: 3)
        #expect(rig.player.currentSong?.id == "d")
        #expect(rig.player.currentIndex == 0)
        #expect(rig.player.isShuffled)
    }

    @Test func nothingToPlayDoesNothing() throws {
        let rig = try Rig()
        rig.player.playInOrder([])
        rig.player.playShuffled([])
        rig.player.play()
        #expect(rig.engine.loaded.isEmpty && !rig.player.isPlaying)
    }

    @Test func withoutAServerTheSongShowsButDoesNotPlay() throws {
        let rig = try Rig(connects: false)
        rig.player.playSong(song("a"))
        #expect(rig.player.currentSong?.id == "a")
        #expect(!rig.player.isPlaying)
        #expect(rig.engine.loaded.isEmpty)
    }

    @Test func theSessionIsActivatedBeforePlaying() throws {
        let rig = try Rig()
        var activations = 0
        rig.player.activateSession = { activations += 1 }
        rig.player.playSong(song("a"))
        rig.player.pause()
        rig.player.play()
        #expect(activations == 2)
    }

    @Test func transcodingSettingsReachTheStreamURL() throws {
        let rig = try Rig()
        rig.defaults.set(true, forKey: "transcoding_enabled")
        rig.defaults.set(128, forKey: "transcoding_wifi_bitrate")
        rig.defaults.set("aac", forKey: "transcoding_format")
        rig.player.playSong(song("a"))
        let url = try #require(rig.engine.loaded.first)
        #expect(url.params["maxBitRate"] == "128" && url.params["format"] == "aac")
    }

    @Test func mobileDataUsesMobileQuality() throws {
        let rig = try Rig()
        rig.defaults.set(true, forKey: "transcoding_enabled")
        rig.defaults.set(320, forKey: "transcoding_wifi_bitrate")
        rig.defaults.set(64, forKey: "transcoding_mobile_bitrate")
        rig.player.isOnMobileData = { true }
        rig.player.playSong(song("a"))
        let url = try #require(rig.engine.loaded.first)
        #expect(url.params["maxBitRate"] == "64" && url.params["format"] == "mp3")
    }

    /// A changed quality reaches the song lined up next, which kept its old address before (C11).
    @Test func aChangedQualityLinesUpTheNextSongAgain() throws {
        let rig = try Rig()
        rig.player.playInOrder([song("a"), song("b")])
        let before = try #require(rig.engine.next)
        #expect(before.params["maxBitRate"] == nil)
        rig.defaults.set(true, forKey: "transcoding_enabled")
        rig.defaults.set(128, forKey: "transcoding_wifi_bitrate")
        rig.player.refreshTranscoding()
        let after = try #require(rig.engine.next)
        #expect(after.params["id"] == "b" && after.params["maxBitRate"] == "128")
        // The current song carries on as it is.
        #expect(rig.engine.loaded.count == 1)
    }

    /// The app calls this at every network change: an unchanged next song keeps what it has buffered.
    @Test func anUnchangedQualityLeavesTheNextSongAlone() throws {
        let rig = try Rig()
        rig.player.playInOrder([song("a"), song("b")])
        let changes = rig.engine.nextChanges
        rig.player.refreshTranscoding()
        #expect(rig.engine.nextChanges == changes)
        #expect(rig.engine.nextSongID == "b")
    }

    /// Re-check item 5 (2026-11-15): the same server reached on another address (home, away) lines
    /// the next song up again from it; the current one carries on.
    @Test func anotherAddressLinesTheNextSongUpAgainFromIt() throws {
        let rig = try Rig()
        rig.player.playInOrder([song("a"), song("b")])
        #expect(rig.engine.next?.host() == "music.example.com")
        func client(_ address: String) throws -> SubsonicClient {
            try SubsonicClient(
                config: ServerConfig(serverURL: address, username: "demo", password: "demo"),
                coverArtSalt: "stablesalt123456",
                transport: rig.server
            )
        }
        rig.player.connect(client: try client("away.example.com"), profileID: "profile", checksServerQueue: false)
        #expect(rig.engine.next?.host() == "away.example.com" && rig.engine.nextSongID == "b")
        #expect(rig.engine.loaded.count == 1 && rig.player.currentSong?.id == "a")
        // The same address again, with a new login: what's buffered stays.
        let changes = rig.engine.nextChanges
        rig.player.connect(client: try client("away.example.com"), profileID: "profile", checksServerQueue: false)
        #expect(rig.engine.nextChanges == changes)
    }

    @Test func theOriginalFileIsTheDefault() throws {
        let rig = try Rig()
        rig.player.playSong(song("a"))
        let url = try #require(rig.engine.loaded.first)
        #expect(url.params["maxBitRate"] == nil && url.params["format"] == nil)
    }
}

@MainActor
@Suite struct PlayerTransportTests {
    @Test func pauseAndPlay() throws {
        let rig = try Rig()
        rig.player.playSong(song("a"))
        rig.player.playOrPause()
        #expect(!rig.player.isPlaying && !rig.engine.isPlaying)
        rig.player.playOrPause()
        #expect(rig.player.isPlaying && rig.engine.isPlaying)
        #expect(rig.engine.loaded.count == 1)
    }

    @Test func seekUpdatesAtOnce() throws {
        let rig = try Rig()
        rig.player.playSong(song("a"))
        rig.player.seek(to: 50)
        #expect(rig.player.position == 50 && rig.engine.seeks == [50])
        rig.player.seek(toProgress: 0.5)
        #expect(rig.player.position == 100)
        #expect(rig.player.progress == 0.5)
    }

    /// A seek made while paused is saved, as a pause is: the app closed before it goes to the
    /// background still comes back there.
    @Test func aSeekWhilePausedIsSaved() async throws {
        let rig = try Rig()
        rig.player.playSong(song("a"))
        rig.player.pause()
        let store = PlayerStore(defaults: rig.defaults, queueFile: rig.queueFile)
        #expect(await eventually { store.loadQueue()?.position == 0 })
        rig.player.seek(to: 30)
        rig.player.seek(to: 42)
        #expect(await eventually { store.loadQueue()?.position == 42 })
    }

    @Test func nextUsesWhatIsAlreadyBuffered() throws {
        let rig = try Rig()
        rig.player.playSong(song("a"), playlist: songs("a", "b", "c"))
        rig.player.skipNext()
        #expect(rig.engine.advances == 1)
        #expect(rig.engine.loaded.count == 1)
        #expect(rig.player.currentSong?.id == "b")
        #expect(rig.engine.nextSongID == "c")
    }

    @Test func nextWorksInARushWithoutSkippingTooFar() throws {
        let rig = try Rig()
        rig.player.playSong(song("a"), playlist: songs("a", "b", "c", "d"))
        rig.player.skipNext()
        rig.player.skipNext()
        #expect(rig.player.currentSong?.id == "c")
        #expect(rig.engine.nextSongID == "d")
    }

    @Test func nextPastTheEndWithRepeatAllWraps() throws {
        let rig = try Rig()
        rig.player.changeRepeat(.all)
        rig.player.playSong(song("b"), playlist: songs("a", "b"), startIndex: 1)
        rig.player.skipNext()
        #expect(rig.player.currentSong?.id == "a")
    }

    /// D25.
    @Test func nextPastTheEndFinishesTheQueue() throws {
        let rig = try Rig()
        rig.player.playSong(song("b"), playlist: songs("a", "b"), startIndex: 1)
        rig.player.skipNext()
        #expect(rig.player.currentSong?.id == "a")
        #expect(!rig.player.isPlaying && rig.player.position == 0)
        #expect(!rig.engine.hasItem)
    }

    @Test func nextOnRepeatOneMovesOn() throws {
        let rig = try Rig()
        rig.player.changeRepeat(.one)
        rig.player.playSong(song("a"), playlist: songs("a", "b"))
        rig.player.skipNext()
        #expect(rig.player.currentSong?.id == "b")
        #expect(rig.engine.loadedSongIDs == ["a", "b"])
        #expect(rig.player.repeatMode == .one)
    }

    @Test func nextOnASingleRepeatAllSongRestartsIt() throws {
        let rig = try Rig()
        rig.player.changeRepeat(.all)
        rig.player.playSong(song("a"))
        rig.player.skipNext()
        #expect(rig.player.currentSong?.id == "a")
        #expect(rig.engine.loadedSongIDs == ["a", "a"])
    }

    @Test func pausedStaysPausedThroughNextAndPrevious() throws {
        let rig = try Rig()
        rig.player.changeRepeat(.one)
        rig.player.playSong(song("a"), playlist: songs("a", "b", "c"))
        rig.player.pause()
        rig.player.skipNext()
        #expect(!rig.player.isPlaying && !rig.engine.isPlaying)
        rig.player.skipPrevious()
        #expect(!rig.player.isPlaying && !rig.engine.isPlaying)
        #expect(rig.player.currentSong?.id == "a")
    }

    @Test func previousAfterThreeSecondsRestartsTheSong() throws {
        let rig = try Rig()
        rig.player.playSong(song("b"), playlist: songs("a", "b"), startIndex: 1)
        rig.engine.send(.position(3.5))
        rig.player.skipPrevious()
        #expect(rig.player.currentSong?.id == "b")
        #expect(rig.engine.seeks == [0])
    }

    @Test func previousEarlyGoesBack() throws {
        let rig = try Rig()
        rig.player.playSong(song("b"), playlist: songs("a", "b"), startIndex: 1)
        rig.engine.send(.position(2))
        rig.player.skipPrevious()
        #expect(rig.player.currentSong?.id == "a")
    }

    @Test func previousAtTheStartRestarts() throws {
        let rig = try Rig()
        rig.player.playSong(song("a"), playlist: songs("a", "b"))
        rig.player.skipPrevious()
        #expect(rig.player.currentSong?.id == "a")
        #expect(rig.engine.seeks == [0])
    }

    @Test func previousAtTheStartWrapsOnRepeatAll() throws {
        let rig = try Rig()
        rig.player.changeRepeat(.all)
        rig.player.playSong(song("a"), playlist: songs("a", "b"))
        rig.player.skipPrevious()
        #expect(rig.player.currentSong?.id == "b")
    }

    @Test func stopKeepsTheQueueAndPlayStartsAgain() throws {
        let rig = try Rig()
        rig.player.playSong(song("a"), playlist: songs("a", "b"))
        rig.engine.send(.position(50))
        rig.player.stop()
        #expect(rig.player.queue.count == 2 && !rig.player.isPlaying && rig.player.position == 0)
        rig.player.play()
        #expect(rig.engine.loadedSongIDs == ["a", "a"])
        #expect(rig.engine.loadStarts == [0, 0])
        #expect(rig.player.isPlaying)
    }

    @Test func skipToIndexPlays() throws {
        let rig = try Rig()
        rig.player.playSong(song("a"), playlist: songs("a", "b", "c"))
        rig.player.pause()
        rig.player.skip(toIndex: 2)
        #expect(rig.player.currentSong?.id == "c" && rig.player.isPlaying)
        rig.player.skip(toIndex: 9)
        #expect(rig.player.currentSong?.id == "c")
    }
}

@MainActor
@Suite struct PlayerEngineEventTests {
    @Test func aSongEndingMovesToTheNextWithoutReloading() throws {
        let rig = try Rig()
        rig.player.playSong(song("a"), playlist: songs("a", "b", "c"))
        rig.engine.send(.position(100))
        rig.engine.send(.advanced)
        #expect(rig.player.currentSong?.id == "b")
        #expect(rig.player.position == 0)
        #expect(rig.engine.loaded.count == 1)
        #expect(rig.engine.nextSongID == "c")
    }

    @Test func theLastSongLinesUpNothing() throws {
        let rig = try Rig()
        rig.player.playSong(song("a"), playlist: songs("a", "b"))
        rig.engine.send(.advanced)
        #expect(rig.player.currentSong?.id == "b")
        #expect(rig.engine.next == nil)
    }

    @Test func repeatOneLinesUpTheSameSongAgain() throws {
        let rig = try Rig()
        rig.player.changeRepeat(.one)
        rig.player.playSong(song("a"), playlist: songs("a", "b"))
        #expect(rig.engine.nextSongID == "a")
        rig.engine.send(.advanced)
        #expect(rig.player.currentSong?.id == "a")
        #expect(rig.engine.nextSongID == "a")
    }

    @Test func repeatAllWrapsBackToTheFirst() throws {
        let rig = try Rig()
        rig.player.changeRepeat(.all)
        rig.player.playSong(song("b"), playlist: songs("a", "b"), startIndex: 1)
        #expect(rig.engine.nextSongID == "a")
        rig.engine.send(.advanced)
        #expect(rig.player.currentSong?.id == "a")
    }

    /// D25: back on the first song, paused at the start, and Play starts the queue over.
    @Test func theQueueEndingGoesBackToTheFirstSong() throws {
        let rig = try Rig()
        rig.player.playSong(song("b"), playlist: songs("a", "b"), startIndex: 1)
        rig.engine.send(.position(199))
        rig.engine.send(.ended)
        #expect(rig.player.currentSong?.id == "a")
        #expect(rig.player.position == 0)
        #expect(!rig.player.isPlaying && !rig.player.isLoading)
        #expect(rig.player.queue.count == 2)

        rig.player.play()
        #expect(rig.engine.loadedSongIDs == ["b", "a"])
        #expect(rig.engine.loadStarts.last == 0)
        #expect(rig.engine.nextSongID == "b")
        #expect(rig.player.isPlaying)
    }

    @Test func aFailureStopsWithoutLosingThePlace() throws {
        let rig = try Rig()
        rig.player.playSong(song("a"), playlist: songs("a", "b"))
        rig.engine.send(.position(42))
        rig.engine.send(.failed("No"))
        #expect(!rig.player.isPlaying && !rig.player.isLoading)
        #expect(rig.player.currentSong?.id == "a")
        // Play loads it again where it stopped, rather than playing the dead item.
        rig.player.play()
        #expect(rig.engine.loadedSongIDs == ["a", "a"] && rig.engine.loadStarts.last == 42)
        #expect(rig.player.isPlaying && rig.engine.isPlaying)
        // Loaded again, Pause and Play act on it as usual.
        rig.player.pause()
        rig.player.play()
        #expect(rig.engine.loaded.count == 2)
    }

    /// The system's media services restarting kills the players: the song is loaded again where it
    /// was, playing or paused as it was.
    @Test func aMediaServicesResetLoadsTheSongAgainWhereItWas() throws {
        let rig = try Rig()
        rig.player.playSong(song("a"), playlist: songs("a", "b"))
        rig.engine.send(.position(42))
        rig.player.handleMediaServicesReset()
        #expect(rig.engine.stops == 1)
        #expect(rig.engine.loadedSongIDs == ["a", "a"] && rig.engine.loadStarts.last == 42)
        #expect(rig.player.isPlaying && rig.engine.isPlaying && rig.engine.nextSongID == "b")
        rig.player.pause()
        rig.player.handleMediaServicesReset()
        #expect(rig.engine.loaded.count == 3 && rig.engine.loadStarts.last == 42)
        #expect(!rig.player.isPlaying && !rig.engine.isPlaying)
    }

    @Test func aFailedSongTappedAgainIsLoadedAgain() throws {
        let rig = try Rig()
        rig.player.playSong(song("a"), playlist: songs("a", "b"))
        rig.engine.send(.failed("No"))
        rig.player.playSong(song("a"), playlist: songs("a", "b"))
        #expect(rig.engine.loadedSongIDs == ["a", "a"] && rig.player.isPlaying)
    }

    @Test func theRealDurationReplacesTheListedOne() throws {
        let rig = try Rig()
        rig.player.playSong(song("a"))
        rig.engine.send(.duration(212.5))
        #expect(rig.player.duration == 212.5)
    }

    @Test func aSongWithNoListedLengthStartsAtZero() throws {
        let rig = try Rig()
        rig.player.playSong(song("a", duration: nil))
        #expect(rig.player.duration == 0 && rig.player.progress == 0)
    }

    @Test func theSystemPausingIsReflected() throws {
        let rig = try Rig()
        rig.player.playSong(song("a"))
        rig.engine.send(.playing(false))
        #expect(!rig.player.isPlaying)
    }

    @Test func gaplessOffLinesUpNothingAndMovesOnAtTheEnd() throws {
        let rig = try Rig()
        rig.player.toggleGapless()
        #expect(!rig.player.isGaplessEnabled)
        rig.player.playSong(song("a"), playlist: songs("a", "b"))
        #expect(rig.engine.next == nil)
        rig.engine.send(.ended)
        #expect(rig.player.currentSong?.id == "b")
        #expect(rig.engine.loadedSongIDs == ["a", "b"])
        #expect(rig.player.isPlaying)
    }

    /// The review's case (C19): Pause with Fade In/Out on keeps the song sounding until the fade ends;
    /// if it ends in that window, the next song is lined up paused, not played.
    @Test func aSongEndingWhileAPauseFadesOutDoesNotStartTheNext() throws {
        let rig = try Rig()
        rig.player.toggleGapless()
        rig.player.playSong(song("a"), playlist: songs("a", "b"))
        rig.player.pause()
        rig.engine.send(.ended)
        #expect(rig.player.currentSong?.id == "b")
        #expect(rig.engine.loadedSongIDs == ["a", "b"])
        #expect(!rig.player.isPlaying && !rig.engine.isPlaying)
    }

    @Test func gaplessOffRepeatOneReplays() throws {
        let rig = try Rig()
        rig.player.toggleGapless()
        rig.player.changeRepeat(.one)
        rig.player.playSong(song("a"))
        rig.engine.send(.ended)
        #expect(rig.engine.loadedSongIDs == ["a", "a"])
    }
}

@MainActor
@Suite struct PlayerQueueEditingTests {
    @Test func addingToTheEndOfTheLastSongLinesItUp() throws {
        let rig = try Rig()
        rig.player.playSong(song("a"))
        #expect(rig.engine.next == nil)
        rig.player.queueUp(song("b"))
        #expect(rig.engine.nextSongID == "b")
    }

    @Test func addingFurtherBackLeavesTheBufferedNextAlone() throws {
        let rig = try Rig()
        rig.player.playSong(song("a"), playlist: songs("a", "b"))
        let changes = rig.engine.nextChanges
        rig.player.queueUp(song("c"))
        #expect(rig.engine.nextChanges == changes)
    }

    @Test func addingWithNothingPlayingStartsIt() throws {
        let rig = try Rig()
        rig.player.queueUpAll(songs("a", "b"))
        #expect(rig.player.currentSong?.id == "a")
        #expect(rig.player.isPlaying)
        #expect(rig.engine.nextSongID == "b")
    }

    @Test func playNextChangesWhatsLinedUp() throws {
        let rig = try Rig()
        rig.player.playSong(song("a"), playlist: songs("a", "b"))
        rig.player.queueUpNext(song("z"))
        #expect(rig.engine.nextSongID == "z")
        #expect(rig.player.queue.map(\.id) == ["a", "z", "b"])
    }

    @Test func removingTheNextSongLinesUpTheOneAfter() throws {
        let rig = try Rig()
        rig.player.playSong(song("a"), playlist: songs("a", "b", "c"))
        rig.player.dropFromQueue(at: 1)
        #expect(rig.engine.nextSongID == "c")
        #expect(rig.engine.loaded.count == 1)
    }

    @Test func removingTheCurrentSongPlaysTheOneInItsPlace() throws {
        let rig = try Rig()
        rig.player.playSong(song("a"), playlist: songs("a", "b", "c"))
        rig.player.dropFromQueue(at: 0)
        #expect(rig.player.currentSong?.id == "b")
        #expect(rig.engine.loadedSongIDs == ["a", "b"])
        #expect(rig.player.isPlaying)
    }

    /// D81: Flutter emptied the player here; the song stays loaded, stopped, so the mini-player stays.
    @Test func removingTheOnlySongStopsItAndKeepsItLoaded() throws {
        let rig = try Rig()
        rig.player.playSong(song("a"))
        rig.player.dropFromQueue(at: 0)
        #expect(rig.player.currentSong?.id == "a" && rig.player.queue.count == 1)
        #expect(!rig.player.isPlaying && !rig.engine.hasItem && rig.player.position == 0)
    }

    @Test func reorderingCanChangeWhatsNext() throws {
        let rig = try Rig()
        rig.player.playSong(song("a"), playlist: songs("a", "b", "c"))
        rig.player.reorderQueue(from: 2, to: 1)
        #expect(rig.player.queue.map(\.id) == ["a", "c", "b"])
        #expect(rig.engine.nextSongID == "c")
    }

    /// D81: everything but the current song goes, and it stays loaded, paused at its start.
    @Test func clearStopsEverythingAndKeepsTheCurrentSong() throws {
        let rig = try Rig()
        rig.player.playSong(song("a"), playlist: songs("a", "b"))
        rig.engine.send(.position(50))
        rig.player.clearQueue()
        #expect(rig.player.queue.map(\.id) == ["a"] && rig.player.currentSong?.id == "a")
        #expect(!rig.player.isPlaying && !rig.engine.hasItem && rig.player.position == 0)
        // Playing it again starts it from the top.
        rig.player.play()
        #expect(rig.engine.loadedSongIDs == ["a", "a"] && rig.player.isPlaying)
    }

    @Test func clearingWithNothingLoadedLeavesNothing() throws {
        let rig = try Rig()
        rig.player.clearQueue()
        #expect(rig.player.queue.isEmpty && rig.player.currentSong == nil)
    }

    /// Flutter restarted the song here.
    @Test func shufflingDoesNotInterruptTheSong() throws {
        let rig = try Rig()
        rig.player.playSong(song("a"), playlist: songs("a", "b", "c", "d"))
        rig.engine.send(.position(50))
        rig.player.toggleShuffle()
        #expect(rig.engine.loaded.count == 1)
        #expect(rig.player.currentSong?.id == "a" && rig.player.position == 50)
        #expect(rig.engine.nextSongID == rig.player.queue[1].id)

        rig.player.toggleShuffle()
        #expect(rig.player.queue.map(\.id) == ["a", "b", "c", "d"])
        #expect(rig.engine.nextSongID == "b")
        #expect(rig.engine.loaded.count == 1)
    }

    @Test func repeatChangesWhatsLinedUp() throws {
        let rig = try Rig()
        rig.player.playSong(song("b"), playlist: songs("a", "b"), startIndex: 1)
        #expect(rig.engine.next == nil)
        rig.player.toggleRepeat()
        #expect(rig.player.repeatMode == .all && rig.engine.nextSongID == "a")
        rig.player.toggleRepeat()
        #expect(rig.player.repeatMode == .one && rig.engine.nextSongID == "b")
        rig.player.toggleRepeat()
        #expect(rig.player.repeatMode == .off && rig.engine.next == nil)
    }
}

@MainActor
@Suite struct PlayerVolumeTests {
    @Test func volumeReachesTheEngineAndIsSaved() throws {
        let rig = try Rig()
        rig.player.setVolume(0.5)
        #expect(rig.engine.volume == 0.5)
        #expect(rig.defaults.double(forKey: "player_volume") == 0.5)
        rig.player.setVolume(4)
        #expect(rig.player.volume == 1)
    }

    @Test func muteRemembersTheLevel() throws {
        let rig = try Rig()
        rig.player.setVolume(0.4)
        rig.player.toggleMute()
        #expect(rig.player.volume == 0 && rig.player.volumeBeforeMute == 0.4)
        rig.player.toggleMute()
        #expect(rig.player.volume == 0.4)
    }

    @Test func replayGainScalesTheVolumePerSong() throws {
        let rig = try Rig()
        rig.defaults.set(1, forKey: "replay_gain_mode")
        var quiet = song("a")
        quiet.replayGain = ReplayGain(trackGain: -20)
        var loud = song("b")
        loud.replayGain = ReplayGain(trackGain: 0)
        rig.player.playSong(quiet, playlist: [quiet, loud])
        #expect(abs(rig.engine.volume - 0.1) < 0.001)
        rig.engine.send(.advanced)
        #expect(rig.engine.volume == 1)
        #expect(rig.player.volume == 1)
    }
}

@MainActor
@Suite struct PlayerSessionTests {
    @Test func anInterruptionPausesAndResumes() throws {
        let rig = try Rig()
        rig.player.playSong(song("a"))
        rig.player.handleInterruptionBegan()
        #expect(!rig.player.isPlaying && !rig.engine.isPlaying)
        rig.player.handleInterruptionEnded(shouldResume: true)
        #expect(rig.player.isPlaying && rig.engine.isPlaying)
    }

    @Test func itStaysPausedWhenTheSystemSaysNotToResume() throws {
        let rig = try Rig()
        rig.player.playSong(song("a"))
        rig.player.handleInterruptionBegan()
        rig.player.handleInterruptionEnded(shouldResume: false)
        #expect(!rig.player.isPlaying)
    }

    @Test func itStaysPausedIfItWasAlreadyPaused() throws {
        let rig = try Rig()
        rig.player.playSong(song("a"))
        rig.player.pause()
        rig.player.handleInterruptionBegan()
        rig.player.handleInterruptionEnded(shouldResume: true)
        #expect(!rig.player.isPlaying)
    }

    /// iOS can stop the player a moment before it announces the interruption.
    @Test func itResumesWhenTheSystemStoppedItJustBefore() throws {
        let rig = try Rig()
        rig.player.playSong(song("a"))
        rig.engine.send(.playing(false))
        rig.player.handleInterruptionBegan()
        rig.player.handleInterruptionEnded(shouldResume: true)
        #expect(rig.player.isPlaying)
    }

    /// The song ended, and later an unrelated call came and went.
    @Test func anOldStopDoesNotStartMusicAfterALaterInterruption() throws {
        let rig = try Rig()
        rig.player.playSong(song("a"))
        rig.engine.send(.playing(false))
        rig.clock.advance(60)
        rig.player.handleInterruptionBegan()
        rig.player.handleInterruptionEnded(shouldResume: true)
        #expect(!rig.player.isPlaying)
    }

    /// The audit's P3: stopped during a call, it stays stopped when the call ends.
    @Test func aStopDuringAnInterruptionIsNotUndoneByItsEnd() throws {
        let rig = try Rig()
        rig.player.playSong(song("a"))
        rig.player.handleInterruptionBegan()
        rig.player.stop()
        rig.player.handleInterruptionEnded(shouldResume: true)
        #expect(!rig.player.isPlaying && !rig.engine.isPlaying)
    }

    /// Stopped a moment before a call comes: the call's end doesn't start it.
    @Test func aStopJustBeforeAnInterruptionIsNotUndoneByIt() throws {
        let rig = try Rig()
        rig.player.playSong(song("a"))
        rig.engine.send(.playing(false))
        rig.player.stop()
        rig.player.handleInterruptionBegan()
        rig.player.handleInterruptionEnded(shouldResume: true)
        #expect(!rig.player.isPlaying)
    }

    /// The queue ended during a call: the call's end doesn't start it over.
    @Test func aQueueThatEndedDuringAnInterruptionStaysEnded() throws {
        let rig = try Rig()
        rig.player.playSong(song("b"), playlist: songs("a", "b"), startIndex: 1)
        rig.player.handleInterruptionBegan()
        rig.player.skipNext()
        #expect(rig.player.currentSong?.id == "a" && !rig.engine.hasItem)
        rig.player.handleInterruptionEnded(shouldResume: true)
        #expect(!rig.player.isPlaying && !rig.engine.hasItem)
    }

    /// Both the old and the new notifications can arrive for one interruption.
    @Test func hearingAnInterruptionTwiceChangesNothing() throws {
        let rig = try Rig()
        rig.player.playSong(song("a"))
        rig.player.handleInterruptionBegan()
        rig.player.handleInterruptionBegan()
        rig.player.handleInterruptionEnded(shouldResume: true)
        #expect(rig.player.isPlaying)
        rig.player.pause()
        rig.player.handleInterruptionEnded(shouldResume: true)
        #expect(!rig.player.isPlaying)
    }

    /// The audit's case: a pause, then a tapped song; a call later still resumes it.
    @Test func aSongTappedAfterAPauseResumesAfterAnInterruption() throws {
        let rig = try Rig()
        rig.player.playSong(song("a"))
        rig.player.pause()
        rig.player.playSong(song("b"))
        rig.player.handleInterruptionBegan()
        rig.player.handleInterruptionEnded(shouldResume: true)
        #expect(rig.player.isPlaying && rig.engine.isPlaying)
    }

    /// A list started after the headphones came out plays on past its first song (gapless off).
    @Test func aListStartedAfterLosingTheOutputPlaysOn() throws {
        let rig = try Rig()
        rig.player.toggleGapless()
        rig.player.playSong(song("a"))
        rig.player.handleOutputLost()
        rig.player.playInOrder(songs("x", "y"))
        rig.engine.send(.ended)
        #expect(rig.player.currentSong?.id == "y" && rig.player.isPlaying && rig.engine.isPlaying)
    }

    @Test func losingTheOutputPausesAndStaysPaused() throws {
        let rig = try Rig()
        rig.player.playSong(song("a"))
        rig.player.handleOutputLost()
        #expect(!rig.player.isPlaying && !rig.engine.isPlaying)
        rig.player.handleInterruptionBegan()
        rig.player.handleInterruptionEnded(shouldResume: true)
        #expect(!rig.player.isPlaying)
    }

    @Test func thePhoneIsToldAboutChanges() throws {
        let rig = try Rig()
        var updates = 0
        rig.player.onNowPlayingChange = { updates += 1 }
        rig.player.playSong(song("a"), playlist: songs("a", "b"))
        let afterStart = updates
        #expect(afterStart > 0)
        rig.player.pause()
        #expect(updates > afterStart)
        let afterPause = updates
        rig.engine.send(.position(5))
        #expect(updates == afterPause)
        rig.engine.send(.advanced)
        #expect(updates > afterPause)
        // A network stall stops the lock screen's clock.
        let afterAdvance = updates
        rig.engine.send(.buffering(true))
        #expect(updates > afterAdvance)
    }
}

/// D24 and Flutter's now-playing and submission calls.
@MainActor
@Suite struct PlayerScrobbleTests {
    @Test func theServerHearsOnceTheSongActuallyStarts() async throws {
        let rig = try Rig()
        rig.player.playSong(song("a"))
        rig.engine.startSounding()
        #expect(await eventually { rig.server.scrobbles == ["a:false"] })
        rig.player.pause()
        rig.player.play()
        try await Task.sleep(for: .milliseconds(30))
        #expect(rig.server.scrobbles == ["a:false"])
    }

    @Test func aPausedStartSaysNothing() async throws {
        let rig = try Rig()
        rig.player.playSong(song("a"), playlist: songs("a", "b"))
        rig.player.pause()
        rig.player.skipNext()
        rig.engine.startSounding()
        try await Task.sleep(for: .milliseconds(30))
        #expect(rig.server.scrobbles.isEmpty)
    }

    @Test func aSongPlayedThroughCountsWhenTheNextTakesOver() async throws {
        let rig = try Rig()
        rig.player.playSong(song("a"), playlist: songs("a", "b"))
        rig.engine.startSounding()
        rig.clock.advance(150)
        rig.engine.send(.advanced)
        #expect(await eventually { rig.server.scrobbles.contains("a:true") })
    }

    @Test func aSongSkippedEarlyDoesNotCount() async throws {
        let rig = try Rig()
        rig.player.playSong(song("a"), playlist: songs("a", "b"))
        rig.engine.startSounding()
        rig.clock.advance(10)
        rig.player.skipNext()
        rig.engine.startSounding()
        #expect(await eventually { rig.server.scrobbles.contains("b:false") })
        #expect(!rig.server.scrobbles.contains("a:true"))
    }

    /// Flutter lost this one.
    @Test func startingAnotherAlbumMidSongCountsTheOutgoingSong() async throws {
        let rig = try Rig()
        rig.player.playSong(song("a"), playlist: songs("a", "b"))
        rig.engine.startSounding()
        rig.clock.advance(150)
        rig.player.playInOrder(songs("x", "y"))
        #expect(await eventually { rig.server.scrobbles.contains("a:true") })
    }

    /// Flutter counted the pause too.
    @Test func pausedTimeDoesNotCount() async throws {
        let rig = try Rig()
        rig.player.playSong(song("a"), playlist: songs("a", "b"))
        rig.engine.startSounding()
        rig.clock.advance(10)
        rig.player.pause()
        rig.clock.advance(1000)
        rig.player.play()
        rig.clock.advance(10)
        rig.player.skipNext()
        rig.engine.startSounding()
        #expect(await eventually { rig.server.scrobbles.contains("b:false") })
        #expect(!rig.server.scrobbles.contains("a:true"))
    }

    @Test func bufferingDoesNotCount() async throws {
        let rig = try Rig()
        rig.player.playSong(song("a"), playlist: songs("a", "b"))
        rig.clock.advance(1000)
        rig.engine.send(.advanced)
        try await Task.sleep(for: .milliseconds(30))
        #expect(!rig.server.scrobbles.contains("a:true"))
    }

    @Test func repeatOneCountsEachPlay() async throws {
        let rig = try Rig()
        rig.player.changeRepeat(.one)
        rig.player.playSong(song("a"))
        rig.engine.startSounding()
        rig.clock.advance(200)
        rig.engine.send(.advanced)
        rig.clock.advance(200)
        rig.engine.send(.advanced)
        #expect(await eventually { rig.server.scrobbles.filter { $0 == "a:true" }.count == 2 })
    }

    @Test func theQueueEndingCountsTheLastSong() async throws {
        let rig = try Rig()
        rig.player.playSong(song("a"))
        rig.engine.startSounding()
        rig.clock.advance(200)
        rig.engine.send(.ended)
        #expect(await eventually { rig.server.scrobbles.contains("a:true") })
    }

    /// A late "now playing" is no longer true, so it's dropped (C10); Flutter sent it.
    @Test func aFailedNowPlayingWaitsAndIsThenDropped() async throws {
        let rig = try Rig()
        rig.server.setFailing(true)
        rig.player.playSong(song("a"))
        rig.engine.startSounding()
        let store = PlayerStore(defaults: rig.defaults, queueFile: rig.queueFile)
        #expect(await eventually { store.heldScrobbles(profileID: "profile").count == 1 })

        rig.server.setFailing(false)
        rig.player.connect(client: try makeClient(server: rig.server), profileID: "profile")
        #expect(await eventually { store.heldScrobbles(profileID: "profile").isEmpty })
        #expect(rig.server.scrobbles.filter { $0 == "a:false" }.count == 1)
    }

    /// Flutter saved the time and never sent it.
    @Test func aFailedPlayIsSentLaterWithItsRealTime() async throws {
        let rig = try Rig()
        rig.server.setFailing(true)
        rig.player.playSong(song("a"), playlist: songs("a", "b"))
        rig.engine.startSounding()
        rig.clock.advance(150)
        let playedAt = rig.clock.date
        rig.engine.send(.advanced)
        let store = PlayerStore(defaults: rig.defaults, queueFile: rig.queueFile)
        #expect(await eventually { store.heldScrobbles(profileID: "profile").contains { $0.submission } })

        rig.server.setFailing(false)
        rig.clock.advance(3600)
        rig.player.connect(client: try makeClient(server: rig.server), profileID: "profile")
        #expect(await eventually { store.heldScrobbles(profileID: "profile").isEmpty })
        let sent = try #require(rig.server.calls(to: "scrobble").last { $0.params["submission"] == "true" })
        #expect(sent.songID == "a")
        #expect(sent.params["time"] == String(Int64(playedAt.timeIntervalSince1970 * 1000)))
    }

    @Test func aFlushThatFailsKeepsItsScrobbles() async throws {
        let rig = try Rig()
        let store = PlayerStore(defaults: rig.defaults, queueFile: rig.queueFile)
        store.setHeldScrobbles([.init(songID: "a", submission: true)], profileID: "profile")
        rig.server.setFailing(true)
        rig.player.connect(client: try makeClient(server: rig.server), profileID: "profile")
        #expect(await eventually { rig.server.scrobbles == ["a:true"] })
        try await Task.sleep(for: .milliseconds(30))
        #expect(store.heldScrobbles(profileID: "profile") == [.init(songID: "a", submission: true)])
    }

    @Test func anotherServersScrobblesStayItsOwn() async throws {
        let rig = try Rig()
        let store = PlayerStore(defaults: rig.defaults, queueFile: rig.queueFile)
        store.setHeldScrobbles([.init(songID: "a", submission: true)], profileID: "other")
        rig.player.connect(client: try makeClient(server: rig.server), profileID: "profile")
        try await Task.sleep(for: .milliseconds(30))
        #expect(rig.server.scrobbles.isEmpty)
        #expect(store.heldScrobbles(profileID: "other").count == 1)
    }
}

@MainActor
@Suite struct PlayerFavoriteTests {
    @Test func theHeartChangesAtOnceAndTheServerHears() async throws {
        let rig = try Rig()
        rig.player.playSong(song("a"))
        await rig.player.toggleFavorite()
        #expect(rig.player.currentSong?.starred == true)
        #expect(rig.server.calls(to: "star").first?.songID == "a")
        await rig.player.toggleFavorite()
        #expect(rig.player.currentSong?.starred == false)
        #expect(rig.server.calls(to: "unstar").first?.songID == "a")
    }

    @Test func theHeartChangesBackOnFailure() async throws {
        let rig = try Rig()
        rig.player.playSong(song("a"))
        rig.server.setFailing(true)
        await rig.player.toggleFavorite()
        #expect(rig.player.currentSong?.starred == false)
    }

    /// Fast heart taps keep the newest, as the stars do: an older write failing doesn't undo a newer
    /// tap, and a tap overtaken while it waited isn't written at all.
    @Test func fastHeartTapsKeepTheNewest() async throws {
        let rig = try Rig()
        rig.player.playSong(song("a"))
        rig.server.hold("star")
        let player = rig.player
        let first = Task { await player.toggleFavorite() }
        #expect(await eventually { rig.server.waitingCount == 1 })
        let second = Task { await player.toggleFavorite() }
        #expect(await eventually { player.currentSong?.starred == false })
        let third = Task { await player.toggleFavorite() }
        #expect(await eventually { player.currentSong?.starred == true })
        rig.server.release(failing: true)
        #expect(await eventually { rig.server.waitingCount == 1 })
        #expect(player.currentSong?.starred == true)
        rig.server.release()
        await first.value
        await second.value
        await third.value
        #expect(rig.server.calls(to: "star").count == 2)
        #expect(rig.server.calls(to: "unstar").isEmpty)
        #expect(player.currentSong?.starred == true && player.latest(song("a")).starred)
    }

    @Test func anySongCanBeFavourited() async throws {
        let rig = try Rig()
        rig.player.playSong(song("a"), playlist: songs("a", "b"))
        let other = rig.player.queue[1]
        try await rig.player.toggleFavorite(for: other)
        #expect(rig.server.calls(to: "star").first?.songID == "b")
        #expect(rig.player.queue[1].starred)
    }

    @Test func aFailureOnAnySongThrowsAndChangesNothing() async throws {
        let rig = try Rig()
        rig.player.playSong(song("a"))
        rig.server.setFailing(true)
        await #expect(throws: SubsonicError.self) { try await rig.player.toggleFavorite(for: song("a")) }
        #expect(rig.player.currentSong?.starred == false)
    }

    @Test func ratingTheCurrentSong() async throws {
        let rig = try Rig()
        rig.player.playSong(song("a"))
        try await rig.player.setRating(songID: "a", rating: 4)
        #expect(rig.player.currentSong?.userRating == 4)
        #expect(rig.server.calls(to: "setRating").first?.params["rating"] == "4")
    }

    @Test func aFailedRatingChangesBackAndThrows() async throws {
        let rig = try Rig()
        rig.player.playSong(song("a"))
        rig.server.setFailing(true)
        await #expect(throws: SubsonicError.self) { try await rig.player.setRating(songID: "a", rating: 4) }
        #expect(rig.player.currentSong?.userRating == nil)
    }

    /// C22: the menus read `latest`, so now playing's stars must reach it too (it used to keep the
    /// menu's older rating).
    @Test func nowPlayingsRatingReachesTheMenus() async throws {
        let rig = try Rig()
        rig.player.playSong(song("a"))
        try await rig.player.rate(song("a"), rating: 3)
        try await rig.player.setRating(songID: "a", rating: 5)
        #expect(rig.player.latest(song("a")).userRating == 5)
        rig.server.setFailing(true)
        await #expect(throws: SubsonicError.self) { try await rig.player.setRating(songID: "a", rating: 1) }
        #expect(rig.player.latest(song("a")).userRating == 5)
        #expect(rig.player.currentSong?.userRating == 5)
    }

    /// C22: fast taps keep the newest. A tap waits for the write before it; an older write failing
    /// doesn't undo a newer tap, and a tap overtaken while it waited isn't written at all.
    @Test func fastRatingTapsKeepTheNewest() async throws {
        let rig = try Rig()
        rig.player.playSong(song("a"))
        rig.server.hold("setRating")
        let player = rig.player
        let first = Task { try await player.setRating(songID: "a", rating: 3) }
        #expect(await eventually { rig.server.waitingCount == 1 })
        let second = Task { try await player.setRating(songID: "a", rating: 4) }
        #expect(await eventually { player.currentSong?.userRating == 4 })
        let third = Task { try await player.setRating(songID: "a", rating: 5) }
        #expect(await eventually { player.currentSong?.userRating == 5 })
        rig.server.release(failing: true)
        #expect(await eventually { rig.server.waitingCount == 1 })
        #expect(player.currentSong?.userRating == 5)
        rig.server.release()
        try await first.value
        try await second.value
        try await third.value
        #expect(rig.server.calls(to: "setRating").compactMap { $0.params["rating"] } == ["3", "5"])
        #expect(rig.player.currentSong?.userRating == 5)
        #expect(rig.player.latest(song("a")).userRating == 5)
    }

    @Test func ratingAnotherSongIsIgnored() async throws {
        let rig = try Rig()
        rig.player.playSong(song("a"))
        try await rig.player.setRating(songID: "z", rating: 4)
        #expect(rig.server.calls(to: "setRating").isEmpty)
    }
}

@MainActor
@Suite struct PlayerPersistenceTests {
    /// A save asked for before the saved queue was cleared (a sign-out) never lands after it.
    @Test func aSaveFromBeforeAClearIsDropped() async throws {
        let store = PlayerStore(
            defaults: try #require(UserDefaults(suiteName: "PlaybackKitTests-\(UUID().uuidString)")),
            queueFile: FileManager.default.temporaryDirectory.appending(path: "PlaybackKitTests-\(UUID().uuidString)/queue.json")
        )
        let saved = PlayerStore.SavedQueue(profileID: "profile", queue: PlayQueue().saved, position: 3)
        let clears = store.clearCount
        store.clearQueue()
        await store.saveQueue(saved, ifNotClearedSince: clears)
        #expect(store.loadQueue() == nil)
        await store.saveQueue(saved, ifNotClearedSince: store.clearCount)
        #expect(store.loadQueue() == saved)
    }

    @Test func theQueueComesBackPausedWhereItWas() async throws {
        let first = try Rig()
        first.player.playSong(song("b"), playlist: songs("a", "b", "c"), startIndex: 1)
        first.engine.send(.position(42))
        first.player.pause()
        let store = PlayerStore(defaults: first.defaults, queueFile: first.queueFile)
        #expect(await eventually { store.loadQueue()?.position == 42 })

        let second = try Rig(defaults: first.defaults, queueFile: first.queueFile)
        #expect(second.player.queue.map(\.id) == ["a", "b", "c"])
        #expect(second.player.currentSong?.id == "b")
        #expect(second.player.position == 42)
        #expect(second.player.duration == 200)
        #expect(!second.player.isPlaying)
        #expect(second.engine.loaded.isEmpty)
    }

    @Test func playingARestoredSongResumesAtItsPosition() async throws {
        let first = try Rig()
        first.player.playSong(song("a"), playlist: songs("a", "b"))
        first.engine.send(.position(42))
        first.player.saveNow()
        let store = PlayerStore(defaults: first.defaults, queueFile: first.queueFile)
        #expect(await eventually { store.loadQueue()?.position == 42 })

        let second = try Rig(defaults: first.defaults, queueFile: first.queueFile)
        second.player.play()
        #expect(second.engine.loadStarts == [42])
        #expect(second.player.isPlaying)
        #expect(second.player.position == 42)
    }

    @Test func anotherServersQueueIsIgnored() async throws {
        let first = try Rig()
        first.player.playSong(song("a"))
        first.player.saveNow()
        let store = PlayerStore(defaults: first.defaults, queueFile: first.queueFile)
        #expect(await eventually { store.loadQueue() != nil })
        let second = try Rig(defaults: first.defaults, queueFile: first.queueFile, profileID: "other")
        #expect(second.player.queue.isEmpty)
    }

    @Test func aReconnectDoesNotDisturbWhatsPlaying() throws {
        let rig = try Rig()
        rig.player.playSong(song("a"))
        rig.player.connect(client: try makeClient(server: rig.server), profileID: "profile")
        #expect(rig.player.isPlaying && rig.engine.loaded.count == 1)
    }

    @Test func settingsComeBack() throws {
        let first = try Rig()
        first.player.changeRepeat(.one)
        first.player.toggleShuffle()
        first.player.setVolume(0.3)
        first.player.toggleGapless()
        let second = try Rig(defaults: first.defaults, queueFile: first.queueFile)
        #expect(second.player.repeatMode == .one)
        #expect(second.player.isShuffled)
        #expect(second.player.volume == 0.3)
        #expect(!second.player.isGaplessEnabled)
    }

    @Test func resetClearsTheQueueForTheNextServer() async throws {
        let rig = try Rig()
        rig.player.playSong(song("a"))
        rig.player.saveNow()
        let store = PlayerStore(defaults: rig.defaults, queueFile: rig.queueFile)
        #expect(await eventually { store.loadQueue() != nil })

        rig.player.reset()
        #expect(rig.player.currentSong == nil && !rig.player.isPlaying && !rig.engine.hasItem)
        #expect(store.loadQueue() == nil)
        rig.player.connect(client: try makeClient(server: rig.server), profileID: "profile")
        #expect(rig.player.queue.isEmpty)
    }

    @Test func resetCountsWhatWasPlayingOnTheOldServer() async throws {
        let rig = try Rig()
        rig.player.playSong(song("a"))
        rig.engine.startSounding()
        rig.clock.advance(150)
        rig.player.reset()
        #expect(await eventually { rig.server.scrobbles.contains("a:true") })
    }

    /// D81: a cleared queue is saved as its one kept song, so a relaunch still shows it.
    @Test func clearSavesTheKeptSongAlone() async throws {
        let rig = try Rig()
        rig.player.playSong(song("a"), playlist: songs("a", "b"))
        rig.player.saveNow()
        let store = PlayerStore(defaults: rig.defaults, queueFile: rig.queueFile)
        #expect(await eventually { store.loadQueue()?.queue.songs.count == 2 })
        rig.player.clearQueue()
        #expect(await eventually { store.loadQueue()?.queue.songs.map(\.id) == ["a"] })
    }
}

@MainActor
@Suite struct SleepTimerTests {
    @Test func aTimerPausesWhenItRunsOut() async throws {
        let rig = try Rig()
        rig.player.playSong(song("a"))
        rig.player.startSleepTimer(after: 0.05, choice: .minutes(5))
        #expect(rig.player.sleepTimerChoice == .minutes(5))
        #expect(rig.player.sleepTimerDeadline != nil)
        #expect(rig.player.isPlaying)
        // Under the suite's parallel load the timer can fire well after its 50 ms.
        for _ in 0..<100 where rig.player.isPlaying {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(!rig.player.isPlaying)
        #expect(!rig.engine.isPlaying)
        #expect(rig.player.sleepTimerChoice == .off)
        #expect(rig.player.sleepTimerDeadline == nil)
    }

    @Test func offCancelsIt() async throws {
        let rig = try Rig()
        rig.player.playSong(song("a"))
        rig.player.startSleepTimer(after: 0.05, choice: .minutes(5))
        rig.player.armSleepTimer(.off)
        try await Task.sleep(for: .milliseconds(200))
        #expect(rig.player.isPlaying)
        #expect(rig.player.sleepTimerDeadline == nil)
    }

    @Test func minutesSetTheEnd() throws {
        let rig = try Rig()
        rig.player.armSleepTimer(.minutes(10))
        let end = try #require(rig.player.sleepTimerDeadline)
        #expect(end.timeIntervalSince(rig.clock.date) == 600)
        #expect(rig.player.sleepTimerChoice == .minutes(10))
        rig.player.armSleepTimer(.off)
    }

    @Test func whenSongEndsLinesUpNothing() throws {
        let rig = try Rig()
        rig.player.playSong(song("a"), playlist: songs("a", "b"))
        #expect(rig.engine.nextSongID == "b")
        rig.player.armSleepTimer(.whenSongEnds)
        #expect(rig.engine.nextSongID == nil)
        rig.player.armSleepTimer(.off)
        #expect(rig.engine.nextSongID == "b")
    }

    @Test func whenSongEndsStopsOnTheNextSongAtItsStart() throws {
        let rig = try Rig()
        rig.player.playSong(song("a"), playlist: songs("a", "b"))
        rig.player.armSleepTimer(.whenSongEnds)
        rig.engine.send(.ended)
        #expect(rig.player.currentSong?.id == "b")
        #expect(!rig.player.isPlaying)
        #expect(!rig.engine.isPlaying)
        #expect(rig.player.position == 0)
        #expect(rig.player.sleepTimerChoice == .off)
        // And Play carries on from there.
        rig.player.play()
        #expect(rig.player.isPlaying)
    }

    @Test func whenSongEndsOnTheLastSongEndsTheQueue() throws {
        let rig = try Rig()
        rig.player.playSong(song("b"), playlist: songs("a", "b"), startIndex: 1)
        rig.player.armSleepTimer(.whenSongEnds)
        rig.engine.send(.ended)
        #expect(rig.player.currentSong?.id == "a")
        #expect(!rig.player.isPlaying)
        #expect(rig.player.sleepTimerChoice == .off)
    }

    @Test func nextByHandKeepsPlayingAndKeepsTheTimer() throws {
        let rig = try Rig()
        rig.player.playSong(song("a"), playlist: songs("a", "b", "c"))
        rig.player.armSleepTimer(.whenSongEnds)
        rig.player.skipNext()
        #expect(rig.player.currentSong?.id == "b")
        #expect(rig.player.isPlaying)
        #expect(rig.player.sleepTimerChoice == .whenSongEnds)
        #expect(rig.engine.nextSongID == nil)
    }

    @Test func aHandoverJustAsItWasSetStillStops() throws {
        let rig = try Rig()
        rig.player.playSong(song("a"), playlist: songs("a", "b"))
        rig.player.armSleepTimer(.whenSongEnds)
        rig.engine.send(.advanced)
        #expect(rig.player.currentSong?.id == "b")
        #expect(!rig.player.isPlaying)
        #expect(rig.player.sleepTimerChoice == .off)
    }

    @Test func aSignOutClearsIt() throws {
        let rig = try Rig()
        rig.player.playSong(song("a"))
        rig.player.armSleepTimer(.minutes(5))
        rig.player.reset()
        #expect(rig.player.sleepTimerChoice == .off)
        #expect(rig.player.sleepTimerDeadline == nil)
    }
}

@MainActor
@Suite struct SongEditTests {
    @Test func aFavouriteFromAListStaysKnown() async throws {
        let rig = try Rig()
        let stale = song("z")
        try await rig.player.toggleFavorite(for: stale)
        #expect(rig.player.latest(stale).starred)
        #expect(rig.server.calls(to: "star").count == 1)
        // The list still holds its old copy, and the second press takes it off again.
        try await rig.player.toggleFavorite(for: stale)
        #expect(!rig.player.latest(stale).starred)
        #expect(rig.server.calls(to: "unstar").count == 1)
    }

    @Test func aRatingFromAListStaysKnown() async throws {
        let rig = try Rig()
        rig.player.playSong(song("a"))
        try await rig.player.rate(song("a"), rating: 3)
        #expect(rig.server.calls(to: "setRating").first?.params["rating"] == "3")
        #expect(rig.player.latest(song("a")).userRating == 3)
        #expect(rig.player.currentSong?.userRating == 3)
        try await rig.player.rate(song("a"), rating: 0)
        #expect(rig.player.latest(song("a")).userRating == 0)
    }

    @Test func aFailedRatingChangesNothing() async throws {
        let rig = try Rig()
        rig.server.setFailing(true)
        await #expect(throws: SubsonicError.self) { try await rig.player.rate(song("a"), rating: 3) }
        #expect(rig.player.latest(song("a")).userRating == nil)
    }

    @Test func untouchedSongsComeBackAsTheyAre() throws {
        let rig = try Rig()
        #expect(rig.player.latest(song("a")) == song("a"))
    }

    @Test func aSignOutForgetsEdits() async throws {
        let rig = try Rig()
        try await rig.player.toggleFavorite(for: song("a"))
        rig.player.reset()
        #expect(!rig.player.latest(song("a")).starred)
    }
}

/// C18 (D87): one speed and pitch mode for the whole player.
@MainActor
@Suite struct PlayerSpeedTests {
    @Test func itStartsNormalAndReachesTheEngine() throws {
        let rig = try Rig()
        #expect(rig.player.playbackSpeed == 1 && rig.player.preservesPitch)
        #expect(rig.engine.rate == 1 && rig.engine.preservesPitch)
        rig.player.changeSpeed(1.5)
        rig.player.setPreservesPitch(false)
        #expect(rig.engine.rate == 1.5 && !rig.engine.preservesPitch)
        rig.player.changeSpeed(5)
        #expect(rig.player.playbackSpeed == 2)
    }

    @Test func itCarriesOverASongChangeAndANewList() throws {
        let rig = try Rig()
        rig.player.playSong(song("a"), playlist: songs("a", "b"))
        rig.player.changeSpeed(0.75)
        let changes = rig.engine.rateChanges
        rig.player.skipNext()
        rig.player.playSong(song("x"), playlist: songs("x", "y"))
        #expect(rig.player.playbackSpeed == 0.75)
        #expect(rig.engine.rate == 0.75)
        // The engine keeps it across loads; nothing has to set it again.
        #expect(rig.engine.rateChanges == changes)
    }

    @Test func aPausedSongStaysPaused() throws {
        let rig = try Rig()
        rig.player.playSong(song("a"))
        rig.player.pause()
        rig.player.changeSpeed(2)
        rig.player.setPreservesPitch(false)
        #expect(!rig.player.isPlaying && !rig.engine.isPlaying)
    }

    /// At 2× a song of 200 s has played half of itself in 50 wall seconds.
    @Test func playCountsFollowTheSongsTime() async throws {
        let rig = try Rig()
        rig.player.playSong(song("a"), playlist: songs("a", "b"))
        rig.engine.startSounding()
        rig.clock.advance(20)
        rig.player.changeSpeed(2)
        rig.clock.advance(40)
        rig.engine.send(.advanced)
        #expect(await eventually { rig.server.scrobbles.contains("a:true") })
    }
}
