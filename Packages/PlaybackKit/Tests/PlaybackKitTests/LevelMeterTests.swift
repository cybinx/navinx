import Foundation
import SubsonicKit
import Testing
@testable import PlaybackKit

/// The equalizer bars' levels (C20, D89): the server's file, reading it at a position, which
/// songs to preload, and the meter's fetching, blending, retries and cache.
@MainActor
@Suite struct LevelMeterTests {
    /// A file as `levels.py` (in `Server/panel`) encodes it.
    static func file(_ frames: [[UInt8]], fps: UInt8 = 30) -> Data {
        var data = Data("NXLV".utf8) + Data([1, 3, fps, 0])
        let count = UInt32(frames.count)
        data += Data((0..<4).map { UInt8(truncatingIfNeeded: count >> (8 * $0)) })
        return data + Data(frames.flatMap { $0 })
    }

    // MARK: The file

    @Test func readsTheServersFile() throws {
        let levels = try #require(SongLevels(data: Self.file([[0, 128, 255], [255, 0, 0]])))
        #expect(levels.framesPerSecond == 30)
        #expect(levels.frameCount == 2)
        #expect(levels == SongLevels(framesPerSecond: 30, frames: [[0, 128, 255], [255, 0, 0]]))
    }

    @Test func refusesAnythingElse() {
        #expect(SongLevels(data: Data(#"{"detail":"Not Found"}"#.utf8)) == nil)
        var wrongVersion = Self.file([[1, 2, 3]])
        wrongVersion[4] = 2
        #expect(SongLevels(data: wrongVersion) == nil)
        #expect(SongLevels(data: Self.file([[1, 2, 3]]).dropLast()) == nil)
        #expect(SongLevels(data: Self.file([])) == nil)
    }

    @Test func readsBetweenFramesAndIsSilentPastTheEnd() {
        let levels = SongLevels(framesPerSecond: 30, frames: [[0, 255, 0], [255, 0, 0], [255, 0, 0]])
        // A frame's value sits at its middle: frame 0 at 1/60 s, frame 1 at 3/60 s.
        #expect(levels.levels(at: 0) == SIMD3(0, 1, 0))
        #expect(levels.levels(at: 1.0 / 60) == SIMD3(0, 1, 0))
        let between = levels.levels(at: 2.0 / 60)
        #expect(abs(between.x - 0.5) < 0.001 && abs(between.y - 0.5) < 0.001)
        #expect(levels.levels(at: 3.0 / 60) == SIMD3(1, 0, 0))
        #expect(levels.levels(at: 5) == .zero)
        #expect(levels.levels(at: .nan) == .zero)
    }

    @Test func aSongTimeReadsItsOwnFrame() {
        // A tone from 2.0 s (frame 60, as the server measured one): read at the player's time, so
        // at 1.5× it's simply reached sooner, and a seek lands on it.
        let frames = (0..<120).map { $0 < 60 ? [UInt8(0), 0, 0] : [255, 0, 0] }
        let levels = SongLevels(framesPerSecond: 30, frames: frames)
        #expect(levels.levels(at: 1.9).x == 0)
        #expect(levels.levels(at: 2.05).x == 1)
    }

    // MARK: Which songs

    @Test func preloadsTheCurrentSongAndTheNextThree() {
        let queue = ["a", "b", "c", "d", "e", "f"]
        #expect(LevelMeter.songsToPreload(queue: queue, currentIndex: 1, wraps: false) == ["b", "c", "d", "e"])
        #expect(LevelMeter.songsToPreload(queue: queue, currentIndex: 4, wraps: false) == ["e", "f"])
        #expect(LevelMeter.songsToPreload(queue: queue, currentIndex: 4, wraps: true) == ["e", "f", "a", "b"])
        #expect(LevelMeter.songsToPreload(queue: ["a", "b"], currentIndex: 0, wraps: true) == ["a", "b"])
        #expect(LevelMeter.songsToPreload(queue: ["a", "a", "b"], currentIndex: 0, wraps: false) == ["a", "b"])
        #expect(LevelMeter.songsToPreload(queue: queue, currentIndex: -1, wraps: false) == [])
    }

    // MARK: The meter

    final class Calls {
        var fetched: [String] = []
        var replies: [String: LevelFetch] = [:]
        var failing = false
    }

    func meter(_ calls: Calls, clock: TestClock, folder: URL? = nil) -> LevelMeter {
        LevelMeter(folder: folder, now: { clock.date }) { id in
            calls.fetched.append(id)
            if calls.failing { throw URLError(.notConnectedToInternet) }
            return calls.replies[id] ?? .levels(Self.file([[255, 255, 255]]))
        }
    }

    @Test func fetchesInOrderOnceAndBlendsIn() async {
        let calls = Calls()
        let clock = TestClock()
        let meter = meter(calls, clock: clock)
        #expect(meter.sample(songID: "a", at: 0, date: clock.date) == nil)
        meter.preload(["a", "b", "c"])
        await meter.settle()
        #expect(calls.fetched == ["a", "b", "c"])
        // Arrived now: the loop still shows; 0.4 s on, half; after the blend, all levels.
        #expect(meter.sample(songID: "a", at: 0, date: clock.date)?.weight == 0)
        #expect(abs((meter.sample(songID: "a", at: 0, date: clock.date + 0.4)?.weight ?? 0) - 0.5) < 0.001)
        let later = meter.sample(songID: "a", at: 0, date: clock.date + 5)
        #expect(later?.weight == 1)
        #expect(later?.levels == SIMD3(1, 1, 1))
        meter.preload(["b", "c", "d"])
        await meter.settle()
        #expect(calls.fetched == ["a", "b", "c", "d"])
    }

    @Test func aSongWithNoneIsNotAskedForAgainForAWhile() async {
        let calls = Calls()
        calls.replies["a"] = LevelFetch.none
        let clock = TestClock()
        let meter = meter(calls, clock: clock)
        meter.preload(["a", "b"])
        await meter.settle()
        meter.preload(["a", "b"])
        await meter.settle()
        #expect(calls.fetched == ["a", "b"])
        #expect(meter.sample(songID: "a", at: 0, date: clock.date) == nil)
        clock.advance(LevelMeter.missingRetry + 1)
        meter.preload(["a"])
        await meter.settle()
        #expect(calls.fetched == ["a", "b", "a"])
    }

    /// The review's case: a song the server fails on (500 `analysis`) waits on its own; the
    /// next ones are still fetched, and it's asked again only after `failedRetry`.
    @Test func aSongTheServerFailsOnWaitsAloneAndTheOthersCarryOn() async {
        let calls = Calls()
        calls.replies["a"] = .failed
        let clock = TestClock()
        let meter = meter(calls, clock: clock)
        meter.preload(["a", "b", "c"])
        await meter.settle()
        #expect(calls.fetched == ["a", "b", "c"])
        #expect(meter.hasLevels("b") && meter.hasLevels("c") && !meter.hasLevels("a"))
        meter.preload(["a", "b", "c"])
        await meter.settle()
        #expect(calls.fetched == ["a", "b", "c"])
        clock.advance(LevelMeter.failedRetry + 1)
        calls.replies["a"] = nil
        meter.preload(["a", "b", "c"])
        await meter.settle()
        #expect(calls.fetched == ["a", "b", "c", "a"])
    }

    @Test func noServerOrNoRoutePausesEverything() async {
        let calls = Calls()
        calls.replies["a"] = .unavailable
        let clock = TestClock()
        let meter = meter(calls, clock: clock)
        meter.preload(["a", "b", "c"])
        await meter.settle()
        #expect(calls.fetched == ["a"])
        clock.advance(LevelMeter.unavailablePause + 1)
        calls.replies["a"] = nil
        meter.preload(["a", "b"])
        await meter.settle()
        #expect(calls.fetched == ["a", "a", "b"])
    }

    @Test func aFailedCallPausesThenTriesAgain() async {
        let calls = Calls()
        calls.failing = true
        let clock = TestClock()
        let meter = meter(calls, clock: clock)
        meter.preload(["a", "b"])
        await meter.settle()
        #expect(calls.fetched == ["a"])
        calls.failing = false
        meter.preload(["a", "b"])
        await meter.settle()
        #expect(calls.fetched == ["a"])
        clock.advance(LevelMeter.failurePause + 1)
        meter.preload(["a", "b"])
        await meter.settle()
        #expect(calls.fetched == ["a", "a", "b"])
        #expect(meter.hasLevels("a") && meter.hasLevels("b"))
    }

    /// A pause that has passed is forgotten, so finished runs stop waking up for it.
    @Test func aPassedPauseIsForgotten() async {
        let calls = Calls()
        calls.failing = true
        let clock = TestClock()
        let meter = meter(calls, clock: clock)
        meter.preload(["a"])
        await meter.settle()
        #expect(meter.isPaused)
        calls.failing = false
        clock.advance(LevelMeter.failurePause + 1)
        meter.preload(["a", "b"])
        await meter.settle()
        #expect(!meter.isPaused)
        #expect(meter.hasLevels("a") && meter.hasLevels("b"))
    }

    @Test func aFileThatIsntLevelsCountsAsNone() async {
        let calls = Calls()
        calls.replies["a"] = .levels(Data("<html>".utf8))
        let meter = meter(calls, clock: TestClock())
        meter.preload(["a"])
        await meter.settle()
        #expect(!meter.hasLevels("a"))
    }

    @Test func keepsLevelsOnDiskForTheNextLaunch() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "LevelMeterTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let calls = Calls()
        let first = meter(calls, clock: TestClock(), folder: folder)
        first.preload(["song1", "../bad"])
        await first.settle()
        #expect(calls.fetched == ["song1", "../bad"])
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path())
        #expect(files == ["song1.lvl"])
        let second = meter(calls, clock: TestClock(), folder: folder)
        second.preload(["song1"])
        await second.settle()
        #expect(calls.fetched == ["song1", "../bad"])
        #expect(second.hasLevels("song1"))
    }

    @Test func memoryKeepsTheWantedSongs() async {
        let calls = Calls()
        let meter = meter(calls, clock: TestClock())
        let ids = (0..<20).map { "s\($0)" }
        for id in ids {
            meter.preload([id])
            await meter.settle()
        }
        #expect(!meter.hasLevels("s0"))
        #expect(meter.hasLevels("s19"))
    }

    // MARK: The player's clock

    @Test func playbackTimeIsTheEnginesClockElseThePosition() throws {
        let rig = try Rig()
        rig.player.playInOrder(songs("1", "2"))
        rig.engine.send(.position(10))
        #expect(rig.player.playbackTime == 10)
        rig.engine.clock = 10.37
        #expect(rig.player.playbackTime == 10.37)
    }

    @Test func theCrossfadeEngineReadsTheSongPlayingNow() {
        let children = [FakeEngine(), FakeEngine()]
        let engine = CrossfadeEngine(children: children)
        #expect(engine.currentTime == nil)
        children[0].clock = 42
        children[1].clock = 3
        #expect(engine.currentTime == 42)
    }
}
