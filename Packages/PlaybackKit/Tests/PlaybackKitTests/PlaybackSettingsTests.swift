import Foundation
import Testing
import MediaPlayer
import AVFoundation
import SubsonicKit
@testable import PlaybackKit

@Suite struct ReplayGainTests {
    private func settings(_ mode: ReplayGainSettings.Mode) -> ReplayGainSettings {
        var settings = ReplayGainSettings()
        settings.mode = mode
        return settings
    }

    @Test func offChangesNothing() {
        #expect(settings(.off).multiplier(for: ReplayGain(trackGain: -12)) == 1)
    }

    @Test func trackModeUsesTheTrackGain() {
        let value = settings(.track).multiplier(for: ReplayGain(trackGain: -20, albumGain: -6))
        #expect(abs(value - 0.1) < 0.0001)
    }

    @Test func albumModeUsesTheAlbumGain() {
        let value = settings(.album).multiplier(for: ReplayGain(trackGain: -6, albumGain: -20))
        #expect(abs(value - 0.1) < 0.0001)
    }

    @Test func albumModeFallsBackToTheTrackGain() {
        let value = settings(.album).multiplier(for: ReplayGain(trackGain: -20))
        #expect(abs(value - 0.1) < 0.0001)
    }

    @Test func noGainUsesTheFallback() {
        let value = settings(.track).multiplier(for: ReplayGain())
        #expect(abs(value - pow(10, -6.0 / 20)) < 0.0001)
    }

    @Test func thePreampAdds() {
        var settings = settings(.track)
        settings.preamp = -10
        #expect(abs(settings.multiplier(for: ReplayGain(trackGain: -10)) - 0.1) < 0.0001)
    }

    @Test func clippingPreventionHoldsThePeakDown() {
        let value = settings(.track).multiplier(for: ReplayGain(trackGain: 0, trackPeak: 2))
        #expect(value == 0.5)
    }

    @Test func clippingPreventionCanBeOff() {
        var settings = settings(.track)
        settings.preventsClipping = false
        #expect(settings.multiplier(for: ReplayGain(trackGain: 0, trackPeak: 2)) == 1)
    }

    @Test func aPositiveGainCannotGetLouder() {
        #expect(settings(.track).multiplier(for: ReplayGain(trackGain: 12)) == 1)
    }

    @Test func itReadsFlutterDefaultsWhenNothingIsSaved() throws {
        let defaults = try #require(UserDefaults(suiteName: "ReplayGainTests-\(UUID().uuidString)"))
        #expect(ReplayGainSettings(defaults: defaults) == ReplayGainSettings())
        defaults.set(2, forKey: "replay_gain_mode")
        defaults.set(-3.0, forKey: "replay_gain_preamp")
        defaults.set(false, forKey: "replay_gain_prevent_clipping")
        defaults.set(-9.0, forKey: "replay_gain_fallback")
        let read = ReplayGainSettings(defaults: defaults)
        #expect(read.mode == .album && read.preamp == -3 && !read.preventsClipping && read.fallbackGain == -9)
    }
}

@Suite struct TranscodingSettingsTests {
    @Test func offByDefault() throws {
        let defaults = try #require(UserDefaults(suiteName: "TranscodingTests-\(UUID().uuidString)"))
        #expect(!TranscodingSettings(defaults: defaults).isEnabled)
    }

    @Test func flutterDefaults() throws {
        let defaults = try #require(UserDefaults(suiteName: "TranscodingTests-\(UUID().uuidString)"))
        let read = TranscodingSettings(defaults: defaults)
        #expect(read.wifiBitRate == 0 && read.mobileBitRate == 192 && read.format == "mp3")
    }

    @Test func itReadsItsKeys() throws {
        let defaults = try #require(UserDefaults(suiteName: "TranscodingTests-\(UUID().uuidString)"))
        defaults.set(true, forKey: "transcoding_enabled")
        defaults.set(192, forKey: "transcoding_wifi_bitrate")
        defaults.set(64, forKey: "transcoding_mobile_bitrate")
        defaults.set("opus", forKey: "transcoding_format")
        let read = TranscodingSettings(defaults: defaults)
        #expect(read.isEnabled && read.wifiBitRate == 192 && read.mobileBitRate == 64 && read.format == "opus")
    }

    @Test func offAsksForNothing() {
        var settings = TranscodingSettings()
        settings.wifiBitRate = 128
        #expect(settings.streamOptions(onMobileData: false) == .init())
        #expect(settings.streamOptions(onMobileData: true) == .init())
    }

    /// Wi-Fi Quality on Wi-Fi, Mobile Quality on mobile data, always (Flutter used Mobile only with Smart on).
    @Test func theConnectionPicksTheQuality() {
        var settings = TranscodingSettings()
        settings.isEnabled = true
        settings.wifiBitRate = 320
        settings.mobileBitRate = 128
        #expect(settings.streamOptions(onMobileData: false) == .init(maxBitRate: 320, format: "mp3"))
        #expect(settings.streamOptions(onMobileData: true) == .init(maxBitRate: 128, format: "mp3"))
    }

    /// "Original" is the untouched file, whatever the format says (Flutter sent the format).
    @Test func originalAsksForTheUntouchedFile() {
        var settings = TranscodingSettings()
        settings.isEnabled = true
        settings.format = "aac"
        #expect(settings.streamOptions(onMobileData: false) == .init(format: "raw"))
        settings.mobileBitRate = 0
        #expect(settings.streamOptions(onMobileData: true) == .init(format: "raw"))
    }

    /// Format "Original" with a bit rate leaves the format to the server.
    @Test func formatOriginalSendsOnlyTheBitRate() {
        var settings = TranscodingSettings()
        settings.isEnabled = true
        settings.wifiBitRate = 192
        settings.format = "raw"
        #expect(settings.streamOptions(onMobileData: false) == .init(maxBitRate: 192))
    }
}

/// D24: Flutter's thresholds, on time actually playing.
@Suite struct ScrobbleTrackerTests {
    private let start = Date(timeIntervalSince1970: 1000)

    private func tracker(playedFor seconds: TimeInterval) -> ScrobbleTracker {
        var tracker = ScrobbleTracker()
        tracker.begin(songID: "a")
        tracker.resume(at: start)
        tracker.pause(at: start + seconds)
        return tracker
    }

    @Test func halfTheSongCounts() {
        #expect(!tracker(playedFor: 99).hasPlayedEnough(duration: 200, at: start + 500))
        #expect(tracker(playedFor: 100).hasPlayedEnough(duration: 200, at: start + 500))
    }

    @Test func fourMinutesCountsOnALongSong() {
        #expect(!tracker(playedFor: 239).hasPlayedEnough(duration: 3600, at: start + 500))
        #expect(tracker(playedFor: 240).hasPlayedEnough(duration: 3600, at: start + 500))
    }

    @Test func anUnknownLengthNeedsThirtySeconds() {
        #expect(!tracker(playedFor: 29).hasPlayedEnough(duration: 0, at: start + 500))
        #expect(tracker(playedFor: 30).hasPlayedEnough(duration: 0, at: start + 500))
    }

    @Test func pausedTimeDoesNotCount() {
        var tracker = ScrobbleTracker()
        tracker.begin(songID: "a")
        tracker.resume(at: start)
        tracker.pause(at: start + 10)
        #expect(tracker.playedTime(at: start + 1000) == 10)
        tracker.resume(at: start + 1000)
        #expect(tracker.playedTime(at: start + 1005) == 15)
    }

    /// D87: song time, so a speed change mid-song counts each part at its own speed.
    @Test func timeCountsAtTheSpeedPlayed() {
        var tracker = ScrobbleTracker()
        tracker.begin(songID: "a")
        tracker.resume(at: start, rate: 2)
        #expect(tracker.playedTime(at: start + 10) == 20)
        tracker.pause(at: start + 10)
        tracker.resume(at: start + 10, rate: 0.5)
        #expect(tracker.playedTime(at: start + 30) == 30)
        #expect(tracker.hasPlayedEnough(duration: 60, at: start + 30))
    }

    @Test func resumingTwiceDoesNotRestartTheClock() {
        var tracker = ScrobbleTracker()
        tracker.begin(songID: "a")
        tracker.resume(at: start)
        tracker.resume(at: start + 5)
        #expect(tracker.playedTime(at: start + 10) == 10)
    }

    @Test func beginStartsOver() {
        var tracker = tracker(playedFor: 100)
        tracker.begin(songID: "b")
        #expect(tracker.playedTime(at: start + 500) == 0)
        #expect(tracker.songID == "b")
    }
}

@Suite struct NowPlayingInfoTests {
    @Test func itCarriesTheSongAndTiming() {
        let song = Song(id: "a", title: "Title", album: "Album", artist: "Artist", duration: 100)
        let info = NowPlayingInfo.make(song: song, duration: 120, position: 30, isPlaying: true)
        #expect(info[MPMediaItemPropertyTitle] as? String == "Title")
        #expect(info[MPMediaItemPropertyArtist] as? String == "Artist")
        #expect(info[MPMediaItemPropertyAlbumTitle] as? String == "Album")
        #expect(info[MPMediaItemPropertyPlaybackDuration] as? Double == 120)
        #expect(info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double == 30)
        #expect(info[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 1)
    }

    /// The lock screen's clock runs at the song's speed while playing (D87).
    @Test func theRateIsTheSpeed() {
        let song = Song(id: "a", title: "T", duration: 100)
        let playing = NowPlayingInfo.make(song: song, duration: 100, position: 0, isPlaying: true, speed: 1.5)
        #expect(playing[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 1.5)
        #expect(playing[MPNowPlayingInfoPropertyDefaultPlaybackRate] as? Double == 1)
        let paused = NowPlayingInfo.make(song: song, duration: 100, position: 0, isPlaying: false, speed: 1.5)
        #expect(paused[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 0)
    }

    @Test func pausedHasNoRateAndTheListedLengthFillsIn() {
        let info = NowPlayingInfo.make(song: Song(id: "a", title: "T", duration: 100), duration: 0, position: 0, isPlaying: false)
        #expect(info[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 0)
        #expect(info[MPMediaItemPropertyPlaybackDuration] as? Double == 100)
        #expect(info[MPMediaItemPropertyArtist] == nil)
    }
}

@Suite struct AudioSessionTests {
    @Test func onlyALostOutputCounts() {
        let lost: [AnyHashable: Any] = [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue]
        #expect(SystemMediaBridge.isOutputLost(lost))
        let new: [AnyHashable: Any] = [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue]
        #expect(!SystemMediaBridge.isOutputLost(new))
        #expect(!SystemMediaBridge.isOutputLost(nil))
    }

    @Test func interruptionNotifications() {
        let began: [AnyHashable: Any] = [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue]
        #expect(SessionInterruption(userInfo: began) == .began)

        let resume: [AnyHashable: Any] = [
            AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
            AVAudioSessionInterruptionOptionKey: AVAudioSession.InterruptionOptions.shouldResume.rawValue,
        ]
        #expect(SessionInterruption(userInfo: resume) == .ended(shouldResume: true))

        let plain: [AnyHashable: Any] = [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue]
        #expect(SessionInterruption(userInfo: plain) == .ended(shouldResume: false))
        #expect(SessionInterruption(userInfo: nil) == nil)
    }
}
