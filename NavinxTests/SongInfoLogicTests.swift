import Foundation
import SubsonicKit
import Testing
@testable import Navinx

/// C35: Song Info's values and which rows it leaves out (D142).
struct SongInfoLogicTests {
    private let us = Locale(identifier: "en_US")

    @Test func bitRateSampleRateSizeChannels() {
        #expect(SongInfoLogic.bitRate(1024, locale: us) == "1,024 kbps")
        #expect(SongInfoLogic.bitRate(0, locale: us) == nil)
        #expect(SongInfoLogic.sampleRate(44100, locale: us) == "44.1 kHz")
        #expect(SongInfoLogic.sampleRate(48000, locale: us) == "48 kHz")
        #expect(SongInfoLogic.sampleRate(22050, locale: us) == "22.05 kHz")
        #expect(SongInfoLogic.sampleRate(nil, locale: us) == nil)
        #expect(SongInfoLogic.size(23_477_614, locale: us) == "23.5 MB")
        #expect(SongInfoLogic.channels(1) == "Mono")
        #expect(SongInfoLogic.channels(2) == "Stereo")
        #expect(SongInfoLogic.channels(6) == "6 channels")
        #expect(SongInfoLogic.channels(0) == nil)
    }

    @Test func trackDurationFormatGain() {
        #expect(SongInfoLogic.track(3, disc: 1) == "3")
        #expect(SongInfoLogic.track(3, disc: 2) == "3 · Disc 2")
        #expect(SongInfoLogic.track(nil, disc: 2) == "Disc 2")
        #expect(SongInfoLogic.track(0, disc: nil) == nil)
        #expect(SongInfoLogic.duration(185) == "3:05")
        #expect(SongInfoLogic.duration(3725) == "1:02:05")
        #expect(SongInfoLogic.format(suffix: "flac", contentType: "audio/flac") == "FLAC")
        #expect(SongInfoLogic.format(suffix: nil, contentType: "audio/mpeg") == "MPEG")
        #expect(SongInfoLogic.format(suffix: "", contentType: nil) == nil)
        #expect(SongInfoLogic.gain(-6.24, locale: us) == "\u{2212}6.2 dB")
        #expect(SongInfoLogic.gain(1.5, locale: us) == "+1.5 dB")
        #expect(SongInfoLogic.gain(-0.01, locale: us) == "0.0 dB")
    }

    /// An MP3 as Navidrome sends it: bit depth 0, no play count, no ReplayGain, not downloaded.
    @Test func leavesOutWhatTheServerDidNotSend() {
        let song = Song(
            id: "s", title: "T", album: "me", track: 1, discNumber: 1, duration: 118, bitRate: 192,
            suffix: "mp3", size: 2_881_551, samplingRate: 44100, bitDepth: 0, channelCount: 2
        )
        let groups = SongInfoLogic.groups(for: song, downloadedAt: nil, locale: us)
        #expect(groups.map(\.title) == ["Details", "File"])
        #expect(groups[0].rows.map(\.label) == ["Album", "Track", "Duration"])
        #expect(groups[1].rows.map(\.label) == ["Format", "Bit Rate", "Sample Rate", "Channels", "Size"])
        #expect(!groups.flatMap(\.rows).contains { $0.label == "Path" })
    }

    @Test func everyGroupWhenThereIsEverything() {
        var song = Song(id: "s", title: "T", album: "A", year: 2017, genre: "Rap", duration: 198, bitRate: 857,
                        suffix: "flac", size: 23_477_614, path: "x/y.flac", playCount: 4,
                        samplingRate: 44100, bitDepth: 16, channelCount: 2)
        song.created = Date(timeIntervalSince1970: 1_794_000_000)
        song.played = Date(timeIntervalSince1970: 1_794_100_000)
        song.replayGain = ReplayGain(trackGain: -6.2, albumGain: -7)
        let groups = SongInfoLogic.groups(for: song, downloadedAt: Date(timeIntervalSince1970: 1_794_200_000), locale: us)
        #expect(groups.map(\.title) == ["Details", "File", "Listening", "ReplayGain", "This iPhone"])
        #expect(groups[1].rows.first { $0.label == "Bit Depth" }?.value == "16-bit")
        #expect(groups[2].rows.map(\.label) == ["Plays", "Last Played", "Added"])
        #expect(groups[3].rows.map(\.value) == ["\u{2212}6.2 dB", "\u{2212}7.0 dB"])
        #expect(groups[4].rows.map(\.label) == ["Downloaded"])
    }
}
