import UIKit

/// How now playing's volume slider is dressed (C60): Apple's own `MPVolumeView`, given the look of the
/// scrubber beside it (`BoldTrack`) through nothing but its public image and rect hooks. A capsule that
/// is white up to the volume and faint white after it, 6 pt thick and 12 pt while a finger is on it,
/// with no knob to see. The numbers are `BoldTrack`'s, which the volume bar used before C59.
///
/// A slider's drag doesn't follow its knob image: iOS 27's maps the finger to the value between 19 pt
/// in from each end of its track, whatever knob it's given (measured in C60 on a `UISlider`, which the
/// volume view's slider is). So the track images carry 19 pt of nothing at each end, the knob sits
/// where the finger's value is, and the view reaches past the row on both sides by that much plus the
/// 3 pt a slider keeps its track in from its own edges. What shows is a bar exactly as long as the row,
/// filled from its left end at 0 to its right end at full, that follows the finger exactly.
enum VolumeTrackLook {
    /// `BoldTrack`'s bar at rest and under a finger.
    nonisolated static let restingThickness: CGFloat = 6
    nonisolated static let pressedThickness: CGFloat = 12
    /// `BoldTrack`'s white over `.white.opacity(0.3)`.
    nonisolated static let remainderOpacity: CGFloat = 0.3
    /// `BoldTrack`'s swell: it grows easing out and settles easing in and out, both in 0.2 s.
    nonisolated static let swellDuration: TimeInterval = 0.2

    /// How far in from each end of its track a slider's drag reaches 0 and full.
    nonisolated static let dragInset: CGFloat = 19
    /// How far in from its own edges a slider keeps its track.
    nonisolated static let trackInset: CGFloat = 3
    /// How far the volume view reaches past the row on each side, so the bar that shows is the row's length.
    nonisolated static let overhang: CGFloat = dragInset + trackInset

    /// The knob nobody sees, which is what the finger takes hold of: 44 pt wide, the usual touch target,
    /// and as tall as the row (30 pt), since a touch outside the volume view never reaches it anyway.
    nonisolated static let grabSize = CGSize(width: 44, height: 30)

    // MARK: Where the fill ends

    /// Where the white part ends, in the slider's track: at the bar's left end at 0 and its right end
    /// at full, which is also where a finger at that value is.
    nonisolated static func fillEnd(in track: CGRect, value: Float) -> CGFloat {
        let fraction = value.isFinite ? CGFloat(min(max(value, 0), 1)) : 0
        let reach = max(track.width - 2 * dragInset, 0)
        return track.minX + dragInset + reach * fraction
    }

    /// The invisible knob, centred on the fill's end (a slider draws the fill up to its knob's middle)
    /// and on the track's middle up and down.
    nonisolated static func thumbRect(in track: CGRect, value: Float, size: CGSize = grabSize) -> CGRect {
        CGRect(
            x: fillEnd(in: track, value: value) - size.width / 2,
            y: track.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    /// The volume view's slider is the whole view, so its track (and the knob, which follows it) sits on
    /// the middle of the 30 pt row, level with the speakers. Apple's own rect sat higher (C66: the bar
    /// stood above the icons' middle).
    nonisolated static func sliderRect(in bounds: CGRect) -> CGRect {
        bounds
    }

    // MARK: Images

    /// The filled part (white) or the rest (faint white): a capsule as thick as given, with the drag's
    /// 19 pt of nothing at each end, stretching sideways between its round ends. A slider shows each
    /// image across its whole track and cuts it at the knob, so the fill's end is square, as in `BoldTrack`.
    static func trackImage(thickness: CGFloat, filled: Bool) -> UIImage {
        let radius = thickness / 2
        let size = CGSize(width: 2 * dragInset + thickness + 1, height: thickness)
        let color = filled ? UIColor.white : UIColor.white.withAlphaComponent(remainderOpacity)
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            color.setFill()
            let capsule = CGRect(x: dragInset, y: 0, width: size.width - 2 * dragInset, height: thickness)
            UIBezierPath(roundedRect: capsule, cornerRadius: radius).fill()
        }
        let cap = dragInset + radius
        return image
            .resizableImage(withCapInsets: UIEdgeInsets(top: 0, left: cap, bottom: 0, right: cap), resizingMode: .stretch)
            .withRenderingMode(.alwaysOriginal)
    }

    /// Fully clear, `grabSize` big.
    static func thumbImage() -> UIImage {
        UIGraphicsImageRenderer(size: grabSize).image { _ in }.withRenderingMode(.alwaysOriginal)
    }
}
