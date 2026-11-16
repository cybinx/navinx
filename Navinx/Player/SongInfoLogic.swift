import Foundation
import SubsonicKit

/// What Song Info shows (C35, D142): groups of label and value, each row left out when the server
/// sent nothing for it (a 0 counts as nothing: Navidrome sends a bit depth of 0 for an MP3), and each
/// group left out when it has no rows. No file path: Navidrome reports a made-up one.
nonisolated enum SongInfoLogic {
    struct Row: Hashable {
        let label: String
        let value: String
    }

    struct Group: Hashable {
        let title: String
        let rows: [Row]
    }

    /// `downloadedAt` is when this iPhone downloaded it, nil when it hasn't.
    static func groups(for song: Song, downloadedAt: Date?, locale: Locale = .current) -> [Group] {
        func row(_ label: String, _ value: String?) -> Row? {
            guard let value, !value.isEmpty else { return nil }
            return Row(label: label, value: value)
        }
        func day(_ date: Date?) -> String? {
            date.map { $0.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(locale)) }
        }
        let groups: [(String, [Row?])] = [
            ("Details", [
                row("Album", song.album?.trimmingCharacters(in: .whitespaces)),
                row("Year", positive(song.year).map(String.init)),
                row("Genre", song.genre?.trimmingCharacters(in: .whitespaces)),
                row("Track", track(song.track, disc: song.discNumber)),
                row("Duration", duration(song.duration)),
            ]),
            ("File", [
                row("Format", format(suffix: song.suffix, contentType: song.contentType)),
                row("Bit Rate", bitRate(song.bitRate, locale: locale)),
                row("Sample Rate", sampleRate(song.samplingRate, locale: locale)),
                row("Bit Depth", positive(song.bitDepth).map { "\($0)-bit" }),
                row("Channels", channels(song.channelCount)),
                row("Size", size(song.size, locale: locale)),
            ]),
            ("Listening", [
                row("Plays", positive(song.playCount).map { $0.formatted(.number.locale(locale)) }),
                row("Last Played", day(song.played)),
                row("Added", day(song.created)),
            ]),
            ("ReplayGain", [
                row("Track Gain", gain(song.replayGain.trackGain, locale: locale)),
                row("Album Gain", gain(song.replayGain.albumGain, locale: locale)),
            ]),
            ("This iPhone", [
                row("Downloaded", day(downloadedAt)),
            ]),
        ]
        return groups.compactMap { title, rows in
            let rows = rows.compactMap { $0 }
            return rows.isEmpty ? nil : Group(title: title, rows: rows)
        }
    }

    private static func positive(_ value: Int?) -> Int? {
        guard let value, value > 0 else { return nil }
        return value
    }

    /// "3", or "3 · Disc 2" on a set's later discs (every song says disc 1, which tells nothing).
    static func track(_ track: Int?, disc: Int?) -> String? {
        let disc = positive(disc).flatMap { $0 > 1 ? "Disc \($0)" : nil }
        let parts = [positive(track).map(String.init), disc].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "3:05", or "1:02:05" from an hour.
    static func duration(_ seconds: Int?) -> String? {
        guard let seconds = positive(seconds) else { return nil }
        let (hours, minutes, rest) = (seconds / 3600, seconds / 60 % 60, seconds % 60)
        return hours > 0
            ? "\(hours):" + String(format: "%02d:%02d", minutes, rest)
            : "\(minutes):" + String(format: "%02d", rest)
    }

    /// "FLAC" from the suffix, else from the content type ("audio/mpeg" → "MPEG").
    static func format(suffix: String?, contentType: String?) -> String? {
        if let suffix = suffix?.trimmingCharacters(in: .whitespaces), !suffix.isEmpty { return suffix.uppercased() }
        guard let subtype = contentType?.split(separator: "/").last, !subtype.isEmpty else { return nil }
        return subtype.uppercased()
    }

    /// "1,024 kbps".
    static func bitRate(_ kbps: Int?, locale: Locale = .current) -> String? {
        positive(kbps).map { $0.formatted(.number.locale(locale)) + " kbps" }
    }

    /// 44100 → "44.1 kHz", 48000 → "48 kHz".
    static func sampleRate(_ hertz: Int?, locale: Locale = .current) -> String? {
        positive(hertz).map {
            (Double($0) / 1000).formatted(.number.precision(.fractionLength(0...2)).locale(locale)) + " kHz"
        }
    }

    static func channels(_ count: Int?) -> String? {
        switch positive(count) {
        case nil: nil
        case 1: "Mono"
        case 2: "Stereo"
        case let count?: "\(count) channels"
        }
    }

    /// "23.5 MB".
    static func size(_ bytes: Int?, locale: Locale = .current) -> String? {
        positive(bytes).map { Int64($0).formatted(ByteCountFormatStyle(style: .file).locale(locale)) }
    }

    /// "−6.2 dB" (a true minus sign), "+1.5 dB", "0.0 dB".
    static func gain(_ decibels: Double?, locale: Locale = .current) -> String? {
        guard let decibels, decibels.isFinite else { return nil }
        let magnitude = abs(decibels).formatted(.number.precision(.fractionLength(1)).locale(locale))
        let rounded = (decibels * 10).rounded() / 10
        let sign = rounded < 0 ? "\u{2212}" : rounded > 0 ? "+" : ""
        return sign + magnitude + " dB"
    }
}
