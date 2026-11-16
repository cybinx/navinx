import AVFoundation
import Foundation
import Testing
@testable import PlaybackKit

/// The real `AVQueuePlayer`, on short tones written to disk, so no server is needed.
@MainActor
@Suite(.serialized) struct QueuePlayerEngineTests {
    /// Writes `seconds` of a tone as a PCM file.
    private func tone(seconds: Double, name: String = UUID().uuidString) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "EngineTests", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "\(name).caf")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(seconds * format.sampleRate)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let samples = try #require(buffer.floatChannelData?[0])
        for frame in 0..<Int(frames) {
            samples[frame] = 0.1 * sin(2 * .pi * 440 * Float(frame) / 44100)
        }
        try file.write(from: buffer)
        return url
    }

    /// An engine that writes down what it says.
    private final class Log {
        var events: [AudioEngineEvent] = []
        var positions: [TimeInterval] {
            events.compactMap { if case .position(let seconds) = $0 { seconds } else { nil } }
        }
        func contains(_ event: AudioEngineEvent) -> Bool { events.contains(event) }
        func count(_ event: AudioEngineEvent) -> Int { events.filter { $0 == event }.count }
    }

    private func makeEngine() -> (QueuePlayerEngine, Log) {
        let engine = QueuePlayerEngine()
        let log = Log()
        engine.onEvent = { log.events.append($0) }
        return (engine, log)
    }

    @Test func itPlaysToTheEndAndSaysSo() async throws {
        let (engine, log) = makeEngine()
        engine.load(try tone(seconds: 0.5), start: 0, next: nil)
        engine.play()
        #expect(engine.hasItem)
        #expect(await eventually(.seconds(10)) { log.contains(.ended) })
        #expect(log.contains(.playing(true)))
        #expect(log.contains(.playing(false)))
        #expect(!engine.hasItem)
    }

    /// A song loaded over one playing says it isn't buffering, even if it never was: the player shows
    /// itself loading until told.
    @Test func aSongLoadedOverAnotherSaysItIsNotBuffering() async throws {
        let (engine, log) = makeEngine()
        engine.load(try tone(seconds: 3), start: 0, next: nil)
        engine.play()
        #expect(await eventually(.seconds(10)) { engine.isSoundingNow })
        log.events = []
        engine.load(try tone(seconds: 3), start: 0, next: nil)
        engine.play()
        #expect(await eventually(.seconds(10)) { log.contains(.buffering(false)) })
        engine.stop()
    }

    @Test func itReportsTheDuration() async throws {
        let (engine, log) = makeEngine()
        engine.load(try tone(seconds: 1), start: 0, next: nil)
        let reported = await eventually(.seconds(5)) {
            log.events.contains { if case .duration(let seconds) = $0 { abs(seconds - 1) < 0.1 } else { false } }
        }
        #expect(reported)
    }

    @Test func itMovesToTheQueuedSongWithoutEndingOrStopping() async throws {
        let (engine, log) = makeEngine()
        engine.load(try tone(seconds: 0.5), start: 0, next: try tone(seconds: 3))
        engine.play()
        #expect(await eventually(.seconds(10)) { log.contains(.advanced) })
        #expect(!log.contains(.ended))
        #expect(engine.hasItem)
        #expect(log.count(.playing(false)) == 0)
    }

    @Test func itCanMoveAgainAfterLiningUpAnotherSong() async throws {
        let (engine, log) = makeEngine()
        engine.load(try tone(seconds: 0.4), start: 0, next: try tone(seconds: 0.4))
        engine.play()
        #expect(await eventually(.seconds(10)) { log.contains(.advanced) })
        engine.setNext(try tone(seconds: 0.4))
        #expect(await eventually(.seconds(10)) { log.count(.advanced) == 2 })
        #expect(await eventually(.seconds(10)) { log.contains(.ended) })
    }

    @Test func advancingReportsBeforeReturning() async throws {
        let (engine, log) = makeEngine()
        engine.load(try tone(seconds: 5), start: 0, next: try tone(seconds: 5))
        engine.play()
        #expect(await eventually(.seconds(5)) { log.contains(.playing(true)) })
        engine.advanceToNext()
        #expect(log.count(.advanced) == 1)
        engine.stop()
    }

    @Test func advancingWithNothingQueuedDoesNothing() async throws {
        let (engine, log) = makeEngine()
        engine.load(try tone(seconds: 5), start: 0, next: nil)
        engine.advanceToNext()
        #expect(!log.contains(.advanced))
        #expect(engine.hasItem)
        engine.stop()
    }

    @Test func removingTheQueuedSongEndsWithoutIt() async throws {
        let (engine, log) = makeEngine()
        engine.load(try tone(seconds: 0.5), start: 0, next: try tone(seconds: 0.5))
        engine.setNext(nil)
        engine.play()
        #expect(await eventually(.seconds(10)) { log.contains(.ended) })
        #expect(!log.contains(.advanced))
    }

    @Test func pauseAndPlayAreReported() async throws {
        let (engine, log) = makeEngine()
        engine.load(try tone(seconds: 10), start: 0, next: nil)
        engine.play()
        #expect(await eventually(.seconds(5)) { log.contains(.playing(true)) })
        engine.pause()
        #expect(await eventually(.seconds(5)) { log.contains(.playing(false)) })
        engine.play()
        #expect(await eventually(.seconds(5)) { log.count(.playing(true)) == 2 })
        engine.stop()
    }

    @Test func seekingLandsWhereAsked() async throws {
        let (engine, log) = makeEngine()
        engine.load(try tone(seconds: 10), start: 0, next: nil)
        engine.play()
        #expect(await eventually(.seconds(5)) { log.contains(.playing(true)) })
        engine.seek(to: 6)
        #expect(await eventually(.seconds(5)) { log.positions.contains { $0 >= 6 } })
        engine.stop()
    }

    @Test func aStartPositionIsHonouredBeforePlayingFromTheTop() async throws {
        let (engine, log) = makeEngine()
        engine.load(try tone(seconds: 10), start: 7, next: nil)
        engine.play()
        #expect(await eventually(.seconds(5)) { log.positions.contains { $0 >= 7 } })
        // Nothing from before the start position may be reported once playing.
        #expect(log.positions.allSatisfy { $0 >= 7 || $0 == 0 })
        #expect(log.positions.filter { $0 > 0 && $0 < 7 }.isEmpty)
        engine.stop()
    }

    @Test func aSeekBeforeItsReadyWaits() async throws {
        let (engine, log) = makeEngine()
        engine.load(try tone(seconds: 10), start: 0, next: nil)
        engine.seek(to: 5)
        engine.play()
        #expect(await eventually(.seconds(5)) { log.positions.contains { $0 >= 5 } })
        engine.stop()
    }

    @Test func stopUnloadsAndSaysNothingAboutEnding() async throws {
        let (engine, log) = makeEngine()
        engine.load(try tone(seconds: 10), start: 0, next: try tone(seconds: 10))
        engine.play()
        #expect(await eventually(.seconds(5)) { log.contains(.playing(true)) })
        engine.stop()
        #expect(!engine.hasItem)
        #expect(log.contains(.playing(false)))
        try await Task.sleep(for: .milliseconds(200))
        #expect(!log.contains(.ended))
        #expect(!log.contains(.advanced))
    }

    @Test func loadingOverAPlayingSongReplacesItSilently() async throws {
        let (engine, log) = makeEngine()
        engine.load(try tone(seconds: 10), start: 0, next: try tone(seconds: 10))
        engine.play()
        #expect(await eventually(.seconds(5)) { log.contains(.playing(true)) })
        engine.load(try tone(seconds: 10), start: 0, next: nil)
        engine.play()
        try await Task.sleep(for: .milliseconds(300))
        #expect(!log.contains(.ended))
        #expect(!log.contains(.advanced))
        #expect(engine.hasItem)
        engine.stop()
    }

    @Test func aMissingFileFails() async throws {
        let (engine, log) = makeEngine()
        let missing = FileManager.default.temporaryDirectory.appending(path: "nothing-\(UUID().uuidString).caf")
        engine.load(missing, start: 0, next: nil)
        engine.play()
        let failed = await eventually(.seconds(10)) {
            log.events.contains { if case .failed = $0 { true } else { false } }
        }
        #expect(failed)
    }

    @Test func volumeIsThePlayers() throws {
        let (engine, _) = makeEngine()
        engine.volume = 0.25
        #expect(engine.volume == 0.25)
    }
}
