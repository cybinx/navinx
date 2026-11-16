import CoreGraphics
import Foundation

/// Flutter `_buildPortraitLayout`'s sizes. `width` and `height` are the whole screen, safe areas
/// included; `top` and `bottom` are the safe areas.
nonisolated struct NowPlayingMetrics {
    let width: CGFloat
    let height: CGFloat
    let top: CGFloat
    let bottom: CGFloat

    var isSmall: Bool { height < 720 }
    var isTinyScreen: Bool { height < 620 }
    private var gapScale: CGFloat { min(max((height - 620) / 280, 0), 1) }

    /// From the top of the safe area down to the artwork's space. With no top inset (the iPhone Duo's
    /// cover display) the buttons sit 22 pt down and are 38 pt high, so their bottom is at 60: the
    /// artwork's space starts 8 pt under that, whatever its own vertical padding (C17).
    var topBarGap: CGFloat {
        top > 0 ? (isSmall ? 46 : 52) : 68 - artVertical
    }

    var artHorizontal: CGFloat {
        if width > 480 { return min(max((width - 380) / 2, 32), 120) }
        return width < 360 ? 24 : 32
    }

    var artVertical: CGFloat { isTinyScreen ? 2 : (isSmall ? 4 : 8) }
    var titleVertical: CGFloat { 4 + 6 * gapScale }
    var sliderBottom: CGFloat { isSmall ? 4 : 6 + 8 * gapScale }
    var controlsBottom: CGFloat { isTinyScreen ? 4 : (isSmall ? 6 : 8 + 10 * gapScale) }

    /// From the bottom actions down to the bottom of the safe area.
    var bottomActions: CGFloat {
        bottom > 0 ? 4 : (isSmall ? 6 : 10 + 6 * gapScale)
    }
}

/// Now playing's top bar keeps its two buttons out of a rounded display corner (C30 bug 18). A phone always
/// has a safe area on the top or the sides, which keeps them clear; the iPhone Duo's displays have neither
/// where the status bar runs down the side strip, so landscape's chevron, 8 pt from the top and 12 pt from a
/// bare side, had its outer edge cut by the corner's curve (about 60 pt on the inner display). Such a side gets
/// `cornerClearance` more, which leaves about 5 pt. No public API gives the display's corner radius, so it's
/// a constant, measured from the Duo's masked pictures (`simctl io … screenshot --mask=black`). The bottom
/// row's outer buttons are 78 pt or more from a side in every layout, outside the corner, so it's unchanged.
nonisolated enum NowPlayingCorners {
    static let cornerClearance: CGFloat = 16

    /// The top bar's distance from each side of the page. `leadingIsHinge`: the page's leading side is the
    /// Duo's hinge (the half beside the app, C30 bug 17), not a corner of the display.
    static func topBarSides(
        top: CGFloat,
        leading: CGFloat,
        trailing: CGFloat,
        isLandscape: Bool,
        leadingIsHinge: Bool = false
    ) -> (leading: CGFloat, trailing: CGFloat) {
        let side: CGFloat = isLandscape ? 12 : 18
        guard top == 0 else { return (side, side) }
        return (
            side + (leading == 0 && !leadingIsHinge ? cornerClearance : 0),
            side + (trailing == 0 ? cornerClearance : 0)
        )
    }
}

/// Flutter `_formatDuration`: `03:21`, or `1:03:21` from an hour up.
nonisolated enum PlayerTime {
    static func format(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds.isFinite ? max(seconds, 0) : 0)
        let (hours, minutes, rest) = (whole / 3600, whole / 60 % 60, whole % 60)
        let tail = String(format: "%02d:%02d", minutes, rest)
        return hours > 0 ? "\(hours):\(tail)" : tail
    }

    /// Time left, as the scrubber's right-hand label shows it.
    static func remaining(position: TimeInterval, duration: TimeInterval) -> String {
        "-" + format(max(duration - position, 0))
    }
}

/// The scrubber's drag (Flutter `PlaybackProgressSlider`): the time it shows while a finger is on it,
/// and the song the drag began on, so a drag held across the next song's start seeks nothing.
nonisolated struct ScrubDrag: Equatable {
    /// Where the finger is, in seconds; nil when the bar shows the song's own place.
    private(set) var position: TimeInterval?
    private(set) var songID: String?
    private(set) var isDragging = false

    /// The finger moved to `position`, on the song `song` playing now.
    mutating func move(to position: TimeInterval, song: String?) {
        if !isDragging {
            isDragging = true
            songID = song
        }
        guard songID == song else { return }
        self.position = position
    }

    /// The finger lifted at `position`: where to seek, or nil when the song changed under it.
    mutating func end(at position: TimeInterval, song: String?) -> TimeInterval? {
        let isSameSong = !isDragging || songID == song
        self = ScrubDrag()
        return isSameSong ? position : nil
    }

    /// Another gesture took the touch over (a swipe to the lyrics, the page's drag down): no seek,
    /// and the bar and both times follow the song again.
    mutating func cancel() {
        self = ScrubDrag()
    }

    /// A new song started: its own place shows, while a drag still held seeks nothing on it.
    mutating func songChanged() {
        position = nil
    }
}

/// How bright the blurred cover behind the player will be (Flutter `_artworkBrightness`): the
/// dominant colour pulled up by the brightest one, so a small bright area such as a sun still
/// darkens the scrim. Flutter gets the colours from `palette_generator`; this groups the pixels of
/// a tiny decode instead (no third-party packages, D5).
nonisolated enum CoverLuminance {
    /// Flutter's value until the cover is known.
    static let unknown = 0.2

    /// Bright areas smaller than this share of the cover are noise, not a colour of it.
    private static let minimumShare = 0.02

    /// The estimate for RGBA pixels, or nil if there are none.
    static func estimate(rgba: [UInt8]) -> Double? {
        var groups: [Int: (count: Int, red: Int, green: Int, blue: Int)] = [:]
        for start in stride(from: 0, to: rgba.count - 3, by: 4) {
            let (red, green, blue) = (Int(rgba[start]), Int(rgba[start + 1]), Int(rgba[start + 2]))
            let key = (red >> 5) << 6 | (green >> 5) << 3 | (blue >> 5)
            var group = groups[key] ?? (0, 0, 0, 0)
            group.count += 1
            group.red += red
            group.green += green
            group.blue += blue
            groups[key] = group
        }
        guard let dominant = groups.values.max(by: { $0.count < $1.count }) else { return nil }
        let total = groups.values.reduce(0) { $0 + $1.count }
        let luminance: ((count: Int, red: Int, green: Int, blue: Int)) -> Double = { group in
            let count = Double(group.count) * 255
            return relativeLuminance(
                red: Double(group.red) / count,
                green: Double(group.green) / count,
                blue: Double(group.blue) / count
            )
        }
        let brightest = groups.values
            .filter { Double($0.count) / Double(total) >= minimumShare }
            .map(luminance)
            .max() ?? luminance(dominant)
        return 0.6 * luminance(dominant) + 0.4 * max(brightest, luminance(dominant))
    }

    static func estimate(image: CGImage) -> Double? {
        let side = 16
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        return drawn ? estimate(rgba: pixels) : nil
    }

    /// Flutter's scrim over the blurred cover, top, 40 % down and bottom: black at these strengths.
    static func scrim(brightness: Double) -> (top: Double, middle: Double, bottom: Double) {
        let level = min(max(brightness, 0), 1)
        return (0.30 + 0.25 * level, 0.22 + 0.36 * level, 0.58 + 0.24 * level)
    }

    /// Flutter's `Color.computeLuminance`.
    static func relativeLuminance(red: Double, green: Double, blue: Double) -> Double {
        func linear(_ value: Double) -> Double {
            value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }
}
