import Foundation
import SubsonicKit

/// Flutter `ReplayGainService`, set in Settings → Playback (C11).
public struct ReplayGainSettings: Sendable, Equatable {
    public static let modeKey = "replay_gain_mode"
    public static let preampKey = "replay_gain_preamp"
    public static let preventsClippingKey = "replay_gain_prevent_clipping"
    public static let fallbackKey = "replay_gain_fallback"

    public enum Mode: Int, Sendable, CaseIterable { case off, track, album }

    public var mode: Mode = .off
    /// dB, from -15 to 15.
    public var preamp: Double = 0
    public var preventsClipping = true
    /// dB, used for songs with no gain information.
    public var fallbackGain: Double = -6

    public init() {}

    public init(defaults: UserDefaults) {
        mode = Mode(rawValue: defaults.integer(forKey: Self.modeKey)) ?? .off
        preamp = defaults.object(forKey: Self.preampKey) as? Double ?? 0
        preventsClipping = defaults.object(forKey: Self.preventsClippingKey) as? Bool ?? true
        fallbackGain = defaults.object(forKey: Self.fallbackKey) as? Double ?? -6
    }

    /// Flutter `calculateVolumeMultiplier`. Clamped to 0–1, so a positive gain can't get louder.
    public func multiplier(for gain: ReplayGain) -> Double {
        guard mode != .off else { return 1 }
        var decibels: Double?
        var peak: Double?
        if mode == .album, let albumGain = gain.albumGain {
            decibels = albumGain
            peak = gain.albumPeak
        } else if let trackGain = gain.trackGain {
            decibels = trackGain
            peak = gain.trackPeak
        }
        var multiplier = pow(10, ((decibels ?? fallbackGain) + preamp) / 20)
        if preventsClipping, let peak, peak > 0 {
            multiplier = min(multiplier, 1 / peak)
        }
        return min(max(multiplier, 0), 1)
    }
}

/// Flutter `TranscodingService`, set in Settings → Playback (C11). Off by default, so the server sends
/// the original files. On, it always picks by connection: Wi-Fi Quality on Wi-Fi, Mobile Quality on
/// mobile data. Flutter's "Smart Transcoding" switch, without which Mobile Quality was never used,
/// is gone (D66).
public struct TranscodingSettings: Sendable, Equatable {
    public static let enabledKey = "transcoding_enabled"
    public static let wifiBitRateKey = "transcoding_wifi_bitrate"
    public static let mobileBitRateKey = "transcoding_mobile_bitrate"
    public static let formatKey = "transcoding_format"

    /// The Quality choices, in kbps; 0 is "Original (No Transcoding)" (Flutter `TranscodeBitrate`).
    public static let bitRates = [0, 64, 128, 192, 256, 320]
    /// The Format choices: `raw` is "Original", which leaves the format to the server.
    public static let formats = ["raw", "mp3", "opus", "aac"]

    public var isEnabled = false
    /// kbps on Wi-Fi; 0 is the original file.
    public var wifiBitRate = 0
    /// kbps on mobile data; 0 is the original file.
    public var mobileBitRate = 192
    public var format = "mp3"

    public init() {}

    public init(defaults: UserDefaults) {
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        wifiBitRate = defaults.object(forKey: Self.wifiBitRateKey) as? Int ?? 0
        mobileBitRate = defaults.object(forKey: Self.mobileBitRateKey) as? Int ?? 192
        format = defaults.string(forKey: Self.formatKey) ?? "mp3"
    }

    /// What `stream` is asked for. Off: nothing, so the server sends what it would. "Original": the
    /// untouched file (`format=raw`; Flutter sent the format, so the server transcoded at its own
    /// rate). Format "Original" with a bit rate: only the bit rate, and the server picks the format.
    public func streamOptions(onMobileData: Bool) -> StreamOptions {
        guard isEnabled else { return StreamOptions() }
        let bitRate = onMobileData ? mobileBitRate : wifiBitRate
        guard bitRate > 0 else { return StreamOptions(format: "raw") }
        return StreamOptions(maxBitRate: bitRate, format: format == "raw" ? nil : format)
    }

    public struct StreamOptions: Sendable, Equatable {
        public var maxBitRate: Int?
        public var format: String?

        public init(maxBitRate: Int? = nil, format: String? = nil) {
            self.maxBitRate = maxBitRate
            self.format = format
        }
    }
}

/// When a song has been played enough to count: half of it or 4 minutes, or 30 seconds when its
/// length isn't known (Flutter `_canScrobble`). Only time actually playing counts (D24), and it's
/// counted in the song's own time, so at 2× a wall second is two (D87).
struct ScrobbleTracker: Sendable, Equatable {
    private(set) var songID: String?
    private var played: TimeInterval = 0
    private var resumedAt: Date?
    /// The playback speed since `resumedAt`.
    private var rate: Double = 1

    mutating func begin(songID: String) {
        self.songID = songID
        played = 0
        resumedAt = nil
    }

    mutating func resume(at date: Date, rate: Double = 1) {
        guard resumedAt == nil else { return }
        resumedAt = date
        self.rate = rate
    }

    mutating func pause(at date: Date) {
        if let resumedAt { played += date.timeIntervalSince(resumedAt) * rate }
        resumedAt = nil
    }

    mutating func clear() {
        self = ScrobbleTracker()
    }

    func playedTime(at date: Date) -> TimeInterval {
        played + (resumedAt.map { date.timeIntervalSince($0) * rate } ?? 0)
    }

    func hasPlayedEnough(duration: TimeInterval, at date: Date) -> Bool {
        let played = playedTime(at: date)
        guard duration > 0 else { return played >= 30 }
        return played >= 240 || played >= duration / 2
    }
}

/// Flutter `CrossfadeService`, set in Settings → Playback (C19): seconds of overlap between songs
/// that end by themselves, 0 (off) to 12.
public struct CrossfadeSettings: Sendable, Equatable {
    public static let secondsKey = "crossfade_seconds"
    public static let range = 0...12

    public var seconds = 0

    public init() {}

    public init(defaults: UserDefaults) {
        seconds = min(max(defaults.integer(forKey: Self.secondsKey), Self.range.lowerBound), Self.range.upperBound)
    }
}

/// Flutter `FadeSettingsService`, set in Settings → Playback (C19): Play and Pause fade the volume.
public struct FadeSettings: Sendable, Equatable {
    public static let enabledKey = "fade_enabled"
    public static let durationKey = "fade_duration_ms"
    public static let durationRange = 100...1000

    public var isEnabled = false
    /// Milliseconds.
    public var durationMs = 300

    public init() {}

    public init(defaults: UserDefaults) {
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        let stored = defaults.object(forKey: Self.durationKey) as? Int ?? 300
        durationMs = min(max(stored, Self.durationRange.lowerBound), Self.durationRange.upperBound)
    }

    /// Seconds to fade, or 0 when it's off.
    public var length: TimeInterval {
        isEnabled ? TimeInterval(durationMs) / 1000 : 0
    }
}

/// Flutter `AutoDjMode`, in its order: what Auto DJ adds when the queue is running out (C21).
public enum RefillSource: String, Sendable, CaseIterable {
    // Saved by these raw values (`auto_dj_mode`, `auto_dj_last_mode`), as the earlier builds wrote them
    // (C43): a renamed case must not change them. Changing one needs a move at launch (C43's step 2).
    case off = "off"
    case fromLibrary = "shuffleLibrary"
    case fromSimilar = "similarSongs"
    case fromGenre = "sameGenre"
    case fromArtist = "sameArtist"
    case fromBlend = "smartMix"

    /// Flutter `getModeDisplayName`, the menu's words. Its descriptions were never shown, nor are they here.
    public var label: String {
        switch self {
        case .off: "Off"
        case .fromLibrary: "Shuffle Library"
        case .fromSimilar: "Similar Songs"
        case .fromGenre: "Same Genre"
        case .fromArtist: "Same Artist"
        case .fromBlend: "Smart Mix"
        }
    }
}

/// Flutter `AutoDjService`'s settings, set in Settings → Playback and by the queue's ∞ button (C21,
/// D90). Global, as Flutter's. Flutter's hidden `auto_dj_threshold` is the constant `threshold`.
public struct RefillSettings: Sendable, Equatable {
    public static let modeKey = "auto_dj_mode"
    public static let refillCountKey = "auto_dj_songs_to_add"
    /// The mode the ∞ button turns back on: the last one chosen other than Off.
    public static let lastModeKey = "auto_dj_last_mode"
    public static let refillCountRange = 1...20
    /// Songs left after the current one at which Auto DJ adds more (Flutter's default, never settable).
    public static let threshold = 2

    public var mode = RefillSource.off
    public var refillCount = 5
    public var lastMode = RefillSource.fromSimilar

    public init() {}

    public init(defaults: UserDefaults) {
        mode = defaults.string(forKey: Self.modeKey).flatMap(RefillSource.init(rawValue:)) ?? .off
        let stored = defaults.object(forKey: Self.refillCountKey) as? Int ?? 5
        refillCount = min(max(stored, Self.refillCountRange.lowerBound), Self.refillCountRange.upperBound)
        let last = defaults.string(forKey: Self.lastModeKey).flatMap(RefillSource.init(rawValue:)) ?? .fromSimilar
        lastMode = last == .off ? .fromSimilar : last
    }
}
