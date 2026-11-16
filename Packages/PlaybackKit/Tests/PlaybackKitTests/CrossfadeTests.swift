import Foundation
import Testing
import SubsonicKit
@testable import PlaybackKit

private let first = URL(string: "https://music.example.com/rest/stream?id=a")!
private let second = URL(string: "https://music.example.com/rest/stream?id=b")!

/// `CrossfadeEngine` over two fake children (C19).
@MainActor
@Suite struct CrossfadeEngineTests {
    let a = FakeEngine()
    let b = FakeEngine()
    let engine: CrossfadeEngine
    let events: Recorder

    @MainActor final class Recorder {
        var events: [AudioEngineEvent] = []
        var advances: Int { events.filter { $0 == .advanced }.count }
    }

    init() {
        engine = CrossfadeEngine(children: [a, b], step: .milliseconds(5))
        let events = Recorder()
        self.events = events
        engine.onEvent = { events.events.append($0) }
    }

    /// Plays `first` with `second` lined up to overlap for `length` seconds, the song 100 s long.
    private func startOverlapping(length: TimeInterval = 0.15) {
        engine.volume = 0.8
        engine.load(first, start: 0, next: nil)
        engine.setNext(second, crossfade: Crossfade(length: length, listedDuration: 100))
        engine.play()
        a.send(.playing(true))
        a.send(.duration(100))
    }

    @Test func offItOnlyForwards() {
        engine.volume = 0.5
        engine.load(first, start: 0, next: second)
        engine.play()
        #expect(a.loaded == [first] && a.next == second && a.isPlaying)
        #expect(a.volume == 0.5)
        #expect(b.loaded.isEmpty)
        a.send(.position(99.9))
        a.send(.advanced)
        #expect(events.events == [.position(99.9), .advanced])
        #expect(b.loaded.isEmpty && a.stops == 0)
    }

    @Test func theSongsOverlapFromTheEnd() async {
        startOverlapping()
        #expect(a.next == nil)
        a.send(.position(80))
        #expect(b.loaded.isEmpty)
        a.send(.position(90))
        // Loaded ten seconds early, silent and paused.
        #expect(b.loaded == [second] && !b.isPlaying && b.volume == 0)
        #expect(events.advances == 0)
        a.send(.position(99.9))
        #expect(b.isPlaying && events.advances == 1 && engine.isOverlapping)
        // The old song's events go nowhere now.
        a.send(.position(99.95))
        a.send(.ended)
        #expect(events.events.last == .advanced)
        #expect(await eventually { !engine.isOverlapping })
        #expect(a.stops == 1 && b.volume == 0.8)
        #expect(events.advances == 1)
    }

    @Test func theVolumesCrossOnTheWay() async {
        startOverlapping(length: 2)
        a.send(.position(98))
        a.send(.position(99))
        #expect(await eventually { b.volume > 0.3 && a.volume < 0.75 })
        // Equal power: the two together stay near full.
        let power = (a.volume / 0.8) * (a.volume / 0.8) + (b.volume / 0.8) * (b.volume / 0.8)
        #expect(abs(power - 1) < 0.05)
        engine.stop()
    }

    @Test func atTwiceTheSpeedItStartsTwiceAsEarly() {
        engine.setRate(2, preservesPitch: true)
        startOverlapping(length: 3)
        #expect(b.rate == 2)
        a.send(.position(80))
        a.send(.position(93.8))
        #expect(events.advances == 0)
        a.send(.position(93.9))
        #expect(events.advances == 1)
        engine.stop()
    }

    @Test func pausingOrSeekingEndsTheOverlap() {
        startOverlapping(length: 5)
        a.send(.position(90))
        a.send(.position(96))
        #expect(engine.isOverlapping)
        engine.seek(to: 10)
        #expect(!engine.isOverlapping && a.stops == 1 && b.seeks == [10] && b.volume == 0.8)

        engine.setNext(first, crossfade: Crossfade(length: 5, listedDuration: 100))
        b.send(.duration(100))
        b.send(.position(90))
        b.send(.position(96))
        #expect(engine.isOverlapping)
        engine.pause()
        #expect(!engine.isOverlapping && b.stops == 1 && !a.isPlaying)
    }

    /// A volume change or mute during the overlap reaches the old song too, which keeps its own
    /// ReplayGain: the player sets the new song's (here half) as the overlap starts.
    @Test func theOldSongFollowsTheVolume() {
        let player = engine
        player.onEvent = { [weak player] event in
            if event == .advanced { player?.volume = 0.4 }
        }
        startOverlapping(length: 5)
        a.send(.position(90))
        a.send(.position(96))
        #expect(engine.isOverlapping && a.volume == 0.8)
        engine.volume = 0
        #expect(a.volume == 0 && b.volume == 0)
        engine.volume = 0.2
        #expect(a.volume > 0 && a.volume <= 0.4)
        engine.stop()
    }

    /// Next during a pause's fade-out pauses first, so the next song isn't heard for the rest of it.
    @Test func nextDuringAFadeOutPausesFirst() async {
        engine.load(first, start: 0, next: second)
        engine.play()
        a.send(.playing(true))
        engine.pause(fadeOut: 1)
        #expect(a.isPlaying)
        engine.advanceToNext()
        #expect(!a.isPlaying && a.advances == 1 && a.pauseFades == [0])
        try? await Task.sleep(for: .milliseconds(50))
        #expect(a.pauseFades == [0] && !a.isPlaying)
    }

    @Test func aSongThatCouldNotLoadEndsAsIfOff() {
        startOverlapping()
        a.send(.position(90))
        b.send(.failed("nope"))
        a.send(.position(99.9))
        #expect(events.advances == 0)
        a.send(.ended)
        #expect(events.events.last == .ended)
    }

    @Test func aSeekIntoTheFadeShortensIt() async {
        startOverlapping(length: 10)
        a.send(.position(99.99))
        #expect(events.advances == 1)
        #expect(await eventually(.seconds(2)) { !engine.isOverlapping })
    }

    @Test func aFadeOutShowsPausedAtOnce() async {
        engine.volume = 1
        engine.load(first, start: 0, next: nil)
        engine.play()
        a.send(.playing(true))
        events.events = []
        engine.pause(fadeOut: 0.1)
        // Still sounding, quieter; what it reports playing goes nowhere.
        #expect(a.isPlaying)
        a.send(.playing(true))
        #expect(events.events.isEmpty)
        #expect(await eventually { !a.isPlaying })
        #expect(a.volume == 0)
        // Play again with no fade: full volume at once.
        engine.play()
        #expect(a.volume == 1 && a.isPlaying)
    }

    @Test func aFadeInWaitsForTheSound() async {
        engine.volume = 0.6
        engine.load(first, start: 0, next: nil)
        engine.play(fadeIn: 0.1)
        #expect(a.volume == 0 && a.isPlaying)
        try? await Task.sleep(for: .milliseconds(150))
        #expect(a.volume == 0)
        a.send(.playing(true))
        #expect(await eventually { a.volume == 0.6 })
    }

    @Test func playDuringAFadeOutTurnsBack() async {
        engine.load(first, start: 0, next: nil)
        engine.play()
        a.send(.playing(true))
        engine.pause(fadeOut: 1)
        #expect(await eventually { a.volume < 0.9 })
        engine.play(fadeIn: 0.1)
        #expect(await eventually { a.volume == 1 })
        try? await Task.sleep(for: .milliseconds(100))
        #expect(a.isPlaying)
    }
}

/// When `PlayerModel` crossfades and fades, through a fake engine (C19, D88).
@MainActor
@Suite struct CrossfadePolicyTests {
    private func rig(crossfade seconds: Int = 6) throws -> Rig {
        let rig = try Rig()
        rig.defaults.set(seconds, forKey: CrossfadeSettings.secondsKey)
        return rig
    }

    @Test func offIsGapless() throws {
        let rig = try rig(crossfade: 0)
        rig.player.playSong(song("a"), playlist: songs("a", "b"))
        #expect(rig.engine.nextSongID == "b" && rig.engine.crossfade == nil)
    }

    @Test func onTheNextSongOverlaps() throws {
        let rig = try rig()
        rig.player.playSong(song("a"), playlist: songs("a", "b"))
        #expect(rig.engine.nextSongID == "b")
        #expect(rig.engine.crossfade == Crossfade(length: 6, listedDuration: 200))
        // Even with gapless off: they're separate settings.
        rig.player.toggleGapless()
        #expect(rig.engine.nextSongID == "b" && rig.engine.crossfade != nil)
    }

    @Test func aSettingChangeReachesTheNextChange() throws {
        let rig = try rig(crossfade: 0)
        rig.player.playSong(song("a"), playlist: songs("a", "b"))
        rig.defaults.set(4, forKey: CrossfadeSettings.secondsKey)
        rig.player.refreshCrossfade()
        #expect(rig.engine.crossfade?.length == 4)
    }

    @Test func repeatOneWhenSongEndsAndTheQueuesEndDont() throws {
        let rig = try rig()
        rig.player.playSong(song("a"), playlist: songs("a", "b"))
        rig.player.changeRepeat(.one)
        #expect(rig.engine.nextSongID == "a" && rig.engine.crossfade == nil)
        rig.player.changeRepeat(.off)
        rig.player.armSleepTimer(.whenSongEnds)
        #expect(rig.engine.next == nil)
        rig.player.armSleepTimer(.off)
        rig.player.skipNext()
        #expect(rig.player.currentSong?.id == "b" && rig.engine.next == nil)
    }

    @Test func theNextTrackOfTheSameAlbumStaysGapless() throws {
        let rig = try rig()
        func track(_ id: String, _ number: Int, disc: Int? = nil, album: String = "al") -> Song {
            Song(id: id, title: id, albumID: album, track: number, discNumber: disc, duration: 200)
        }
        rig.player.playSong(track("a", 1), playlist: [track("a", 1), track("b", 2), track("c", 4), track("d", 5, album: "other")])
        #expect(rig.engine.nextSongID == "b" && rig.engine.crossfade == nil)
        #expect(PlayerModel.continuesAlbum(track("x", 9, disc: 1), with: track("y", 1, disc: 2)))
        #expect(!PlayerModel.continuesAlbum(track("x", 2), with: track("y", 4)))
        #expect(!PlayerModel.continuesAlbum(track("x", 2), with: track("y", 3, album: "other")))
        rig.player.skipNext()
        // Track 2 to track 4: something was skipped, so it crossfades.
        #expect(rig.engine.nextSongID == "c" && rig.engine.crossfade != nil)
    }

    @Test func aShortSongCapsIt() throws {
        let rig = try rig(crossfade: 12)
        rig.player.playSong(song("a", duration: 8), playlist: [song("a", duration: 8), song("b", duration: 300)])
        #expect(rig.engine.crossfade?.length == 4)
        rig.player.changeSpeed(2)
        #expect(rig.engine.crossfade?.length == 2)
    }

    @Test func nextNeverCrossfades() throws {
        let rig = try rig()
        rig.player.playSong(song("a"), playlist: songs("a", "b", "c"))
        rig.player.skipNext()
        #expect(rig.engine.advances == 0)
        #expect(rig.engine.loadedSongIDs == ["a", "b"])
        #expect(rig.engine.nextSongID == "c" && rig.engine.crossfade != nil)
    }

    @Test func anOverlapMovesTheQueueOnOnce() throws {
        let rig = try rig()
        rig.player.playSong(song("a"), playlist: songs("a", "b", "c"))
        rig.engine.startSounding()
        rig.engine.send(.advanced)
        #expect(rig.player.currentSong?.id == "b" && rig.player.position == 0)
        #expect(rig.engine.nextSongID == "c" && rig.engine.crossfade != nil)
        #expect(rig.engine.loaded.count == 1)
    }

    @Test func playAndPauseFadeWhenItsOn() throws {
        let rig = try rig(crossfade: 0)
        rig.defaults.set(true, forKey: FadeSettings.enabledKey)
        rig.defaults.set(450, forKey: FadeSettings.durationKey)
        rig.player.playSong(song("a"), playlist: songs("a", "b"))
        // A song started from a list doesn't fade in.
        #expect(rig.engine.playFades == [0])
        rig.player.pause()
        #expect(!rig.player.isPlaying && rig.engine.pauseFades == [0.45])
        rig.player.play()
        #expect(rig.engine.playFades == [0, 0.45])
        // Next (here a gapless hand-over) doesn't fade either.
        rig.player.skipNext()
        #expect(rig.engine.playFades == [0, 0.45])
    }

    @Test func interruptionsAndHeadphonesNeverFade() throws {
        let rig = try rig(crossfade: 0)
        rig.defaults.set(true, forKey: FadeSettings.enabledKey)
        rig.player.playSong(song("a"), playlist: songs("a", "b"))
        rig.engine.startSounding()
        rig.player.handleInterruptionBegan()
        rig.player.handleInterruptionEnded(shouldResume: true)
        #expect(rig.engine.pauseFades == [0] && rig.engine.playFades == [0, 0])
        rig.player.handleOutputLost()
        #expect(rig.engine.pauseFades == [0, 0])
    }

    @Test func theSettingsKeepToFluttersRanges() {
        let defaults = UserDefaults(suiteName: "CrossfadeTests-\(UUID().uuidString)")!
        #expect(CrossfadeSettings(defaults: defaults).seconds == 0)
        #expect(FadeSettings(defaults: defaults).durationMs == 300 && FadeSettings(defaults: defaults).length == 0)
        defaults.set(40, forKey: CrossfadeSettings.secondsKey)
        defaults.set(5000, forKey: FadeSettings.durationKey)
        defaults.set(true, forKey: FadeSettings.enabledKey)
        #expect(CrossfadeSettings(defaults: defaults).seconds == 12)
        #expect(FadeSettings(defaults: defaults).length == 1)
    }
}
