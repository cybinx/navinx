import AVKit
import MediaPlayer
import PlaybackKit
import SubsonicKit
import SwiftUI
import UIKit

/// Flutter `GlassIconButton`. `persistent`: the glyph always sits on a glass disc. Otherwise a disc
/// swells in behind it only while pressed, like the system's transport controls.
struct GlassCircleButton: View {
    let label: String
    let systemImage: String
    let size: CGFloat
    let iconSize: CGFloat
    var color: Color = .white
    var persistent = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: iconSize))
                .foregroundStyle(color)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: size, height: size)
                .contentShape(.circle)
        }
        .buttonStyle(GlassDiscStyle(size: size, persistent: persistent))
        .accessibilityLabel(label)
    }
}

/// A `GlassCircleButton` that opens a menu next to itself (D30).
struct GlassMenuButton<Items: View>: View {
    let label: String
    let systemImage: String
    let size: CGFloat
    let iconSize: CGFloat
    @ViewBuilder let items: () -> Items

    var body: some View {
        Menu {
            items()
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: iconSize))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .contentShape(.circle)
        }
        .buttonStyle(GlassDiscStyle(size: size, persistent: true))
        .accessibilityLabel(label)
    }
}

private struct GlassDiscStyle: ButtonStyle {
    let size: CGFloat
    let persistent: Bool

    func makeBody(configuration: Configuration) -> some View {
        let isPressed = configuration.isPressed
        configuration.label
            .scaleEffect(isPressed ? 0.92 : 1)
            .background {
                if persistent || isPressed {
                    Color.clear
                        .frame(width: size, height: size)
                        .appGlass(in: .circle)
                        .scaleEffect(isPressed ? 1.1 : 1)
                        .transition(.opacity.combined(with: .scale(scale: 0.72)))
                }
            }
            .animation(isPressed ? .easeOut(duration: 0.12) : .easeOut(duration: 0.32), value: isPressed)
            .animation(.easeOut(duration: 0.22), value: persistent)
            .sensoryFeedback(.impact(weight: .light), trigger: isPressed) { _, pressed in pressed }
    }
}

/// Flutter `MarqueeText`: a line too long for its space waits 2 s, scrolls at 30 pt/s, waits 2 s and
/// starts over.
struct ScrollingLabel: View {
    let text: String
    let font: Font

    private static let gap: CGFloat = 40
    private static let speed: CGFloat = 30

    @State private var textWidth: CGFloat = 0
    @State private var spaceWidth: CGFloat = 0
    @State private var offset: CGFloat = 0

    private struct Layout: Hashable {
        let text: String
        let textWidth: CGFloat
        let spaceWidth: CGFloat
    }

    var body: some View {
        // A hidden, truncated copy sets the size: the full line in the overlay can't widen the layout.
        Text(text)
            .font(font)
            .lineLimit(1)
            .hidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self, of: \.size.width) { spaceWidth = $0 }
            .overlay(alignment: .leading) {
                Text(text)
                    .font(font)
                    .lineLimit(1)
                    .fixedSize()
                    .onGeometryChange(for: CGFloat.self, of: \.size.width) { textWidth = $0 }
                    .offset(x: -offset)
            }
            .clipped()
            .task(id: Layout(text: text, textWidth: textWidth, spaceWidth: spaceWidth)) { await scroll() }
    }

    private func scroll() async {
        offset = 0
        guard spaceWidth > 0, textWidth > spaceWidth else { return }
        let distance = textWidth + Self.gap - spaceWidth
        let duration = distance / Self.speed
        do {
            while true {
                try await Task.sleep(for: .seconds(2))
                withAnimation(.linear(duration: duration)) { offset = distance }
                try await Task.sleep(for: .seconds(duration + 2))
                offset = 0
            }
        } catch {}
    }
}

/// Flutter `AirPlayButton` (the system's own route picker). 16 pt larger than its glyph, as there.
struct RoutePickerButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.tintColor = .white.withAlphaComponent(0.7)
        picker.activeTintColor = UIColor(Palette.accent)
        picker.prioritizesVideoDevices = false
        return picker
    }

    func updateUIView(_ picker: AVRoutePickerView, context: Context) {}
}

/// Flutter `VolumeSlider`, moving the phone's own volume only (D28), and always showing it (D194).
/// The slider is Apple's own `MPVolumeView` (C59): iOS has no other way to set the system's volume, and
/// while it's on screen the system's volume overlay stays away by itself. Since C60 it wears the look
/// of the scrubber above it through its public image and rect hooks (`VolumeTrackLook`). The simulator
/// draws no slider in it, so the row keeps its height there with nothing in it.
struct VolumeBar: View {
    /// The space between each speaker's drawn shape and the bar, the same on both sides (C66).
    private static let gap: CGFloat = 12
    /// How far each symbol's shape sits in from its image's edge on the bar's side, at 16 pt (measured
    /// on iOS 27.2 in C66): `speaker.fill` keeps the waves' room empty on its right, and
    /// `speaker.wave.3.fill` starts a little in. Each icon is its own width now; in a 20 pt frame the
    /// waves spilled out of it and the gaps were about 18 pt on the left and 12 on the right.
    private static let quietInset: CGFloat = 4.25
    private static let loudInset: CGFloat = 2.5

    var body: some View {
        HStack(spacing: 0) {
            speaker("speaker.fill")
                .padding(.trailing, Self.gap - Self.quietInset)
            SystemVolumeSlider()
                // Reaches past the row on both sides by the slider's own margins, which hold nothing,
                // so the bar that shows is as long as the row (`VolumeTrackLook`).
                .padding(.horizontal, -VolumeTrackLook.overhang)
                .frame(maxWidth: .infinity)
                .frame(height: 30)
            speaker("speaker.wave.3.fill")
                .padding(.leading, Self.gap - Self.loudInset)
        }
    }

    private func speaker(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 16))
            .foregroundStyle(.white.opacity(0.5))
            .fixedSize()
            .accessibilityHidden(true)
    }
}

/// The `VolumeBar`'s slider: a `VolumeSwell` holding a `DressedVolumeView`. It's kept to the 30 pt the
/// old bar had, so nothing else on now playing moves.
private struct SystemVolumeSlider: UIViewRepresentable {
    func makeUIView(context: Context) -> VolumeSwell { VolumeSwell() }

    func updateUIView(_ view: VolumeSwell, context: Context) {}
}

/// Apple's `MPVolumeView`, dressed through its public face only: track and knob images, and where the
/// slider and its knob go. Its route button is off by default on iOS 27 (measured in C59), and the app
/// has its own, `RoutePickerButton`.
final class DressedVolumeView: MPVolumeView {
    /// The bar at the thickness given; the knob is clear and set once, in `VolumeSwell`.
    func dress(thickness: CGFloat) {
        setMinimumVolumeSliderImage(VolumeTrackLook.trackImage(thickness: thickness, filled: true), for: .normal)
        setMaximumVolumeSliderImage(VolumeTrackLook.trackImage(thickness: thickness, filled: false), for: .normal)
    }

    override func volumeSliderRect(forBounds bounds: CGRect) -> CGRect {
        VolumeTrackLook.sliderRect(in: bounds)
    }

    override func volumeThumbRect(forBounds bounds: CGRect, volumeSliderRect rect: CGRect, value: Float) -> CGRect {
        VolumeTrackLook.thumbRect(in: rect, value: value)
    }
}

/// `BoldTrack`'s swell, given to the volume view from outside it: a touch that lands on the row thickens
/// the bar, and lifting it, or the system taking the touch away, settles it. The recognizer only
/// watches: it never cancels or holds back the slider's own touches and lets every other gesture
/// (the pages' scroll, pulling the player closed) run alongside it. A recognizer always ends, fails or
/// is cancelled before it starts again, and each of those settles the bar, so it can't stay thick.
final class VolumeSwell: UIView, UIGestureRecognizerDelegate {
    private let volume = DressedVolumeView()
    private var isSwollen = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        volume.frame = bounds
        volume.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        volume.tintColor = .white
        volume.overrideUserInterfaceStyle = .dark
        volume.accessibilityIdentifier = "nowPlayingVolume"
        volume.dress(thickness: VolumeTrackLook.restingThickness)
        volume.setVolumeThumbImage(VolumeTrackLook.thumbImage(), for: .normal)
        addSubview(volume)

        let press = UILongPressGestureRecognizer(target: self, action: #selector(pressChanged(_:)))
        press.minimumPressDuration = 0
        press.allowableMovement = .greatestFiniteMagnitude
        press.cancelsTouchesInView = false
        press.delaysTouchesBegan = false
        press.delaysTouchesEnded = false
        press.delegate = self
        addGestureRecognizer(press)
    }

    required init?(coder: NSCoder) { nil }

    @objc private func pressChanged(_ press: UILongPressGestureRecognizer) {
        switch press.state {
        case .began: swell(true, animated: true)
        case .possible, .changed: break
        default: swell(false, animated: true)  // Ended, cancelled or failed.
        }
    }

    /// `BoldTrack`'s timing: growing eases out, settling eases in and out.
    private func swell(_ on: Bool, animated: Bool) {
        guard on != isSwollen else { return }
        isSwollen = on
        let thickness = on ? VolumeTrackLook.pressedThickness : VolumeTrackLook.restingThickness
        guard animated else {
            volume.dress(thickness: thickness)
            return
        }
        volume.layoutIfNeeded()
        UIView.animate(
            withDuration: VolumeTrackLook.swellDuration,
            delay: 0,
            options: [on ? .curveEaseOut : .curveEaseInOut, .allowUserInteraction, .beginFromCurrentState]
        ) {
            self.volume.dress(thickness: thickness)
            self.volume.layoutIfNeeded()
        }
    }

    /// Off screen, nothing is pressing it.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { swell(false, animated: false) }
    }

    func gestureRecognizer(
        _ recognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        true
    }
}

/// Flutter `PlaybackProgressSlider`: seeks when released, and shows the dragged time meanwhile.
struct PlaybackProgress: View {
    @Environment(PlayerModel.self) private var player
    @State private var drag = ScrubDrag()

    var body: some View {
        let length = player.duration > 0 ? player.duration : 1
        let shown = drag.position ?? player.position

        VStack(spacing: 4) {
            BoldTrack(
                value: shown / length,
                label: "Seek",
                onChanged: { new in drag.move(to: new * length, song: player.currentSong?.id) },
                onEnded: { end in
                    if let seconds = drag.end(at: end * length, song: player.currentSong?.id) {
                        player.seek(to: seconds)
                    }
                },
                // A touch that turned into a swipe: nothing seeks, and the bar follows the song again.
                onCancelled: { _ in drag.cancel() }
            )
            .onChange(of: player.currentSong?.id) { drag.songChanged() }
            HStack {
                Text(PlayerTime.format(shown))
                    .accessibilityIdentifier("nowPlayingElapsed")
                Spacer()
                Text(PlayerTime.remaining(position: shown, duration: player.duration))
            }
            .font(.system(size: 12, weight: .medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.7))
        }
    }
}

/// Flutter `ArtworkBackdrop`: the cover decoded tiny, blurred, saturated and drifting slowly, under
/// a scrim that darkens more for bright covers and toward the bottom. New covers cross-fade: the new
/// one fades in over the old one, which stays until it's done, so the screen never dips toward black
/// between two songs (C15, D76; it used to fade the old one out and the new one in over a black base).
struct CoverWash: View {
    let image: UIImage?
    let brightness: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The pictures from the oldest, at the bottom, to the newest. A new one is added on top, fades
    /// in, and then the ones under it go. Starts with what it was given, so the first frame has it.
    @State private var layers: [Layer]

    private struct Layer: Identifiable {
        let id = UUID()
        let image: UIImage?
    }

    init(image: UIImage?, brightness: Double) {
        self.image = image
        self.brightness = brightness
        _layers = State(initialValue: [Layer(image: image)])
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black
                ForEach(layers) { layer in
                    Group {
                        if let picture = layer.image {
                            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
                                drifting(picture, size: proxy.size, at: context.date)
                            }
                        } else {
                            Color.black
                        }
                    }
                    .transition(.opacity)
                }
                scrim
            }
            .animation(.easeInOut(duration: 0.7), value: brightness)
        }
        .ignoresSafeArea()
        .onChange(of: image.map(ObjectIdentifier.init)) { _, _ in fade(to: image) }
    }

    /// Fades `picture` in over the others, then drops the ones it covers.
    private func fade(to picture: UIImage?) {
        let layer = Layer(image: picture)
        withAnimation(.easeInOut(duration: 0.7), completionCriteria: .logicallyComplete) {
            layers.append(layer)
        } completion: {
            guard let index = layers.firstIndex(where: { $0.id == layer.id }) else { return }
            var jump = Transaction()
            jump.disablesAnimations = true
            withTransaction(jump) { layers.removeFirst(index) }
        }
    }

    /// A 40-second loop of movement, turn and size.
    private func drifting(_ image: UIImage, size: CGSize, at date: Date) -> some View {
        let turn = reduceMotion ? 0 : date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 40) / 40
        let angle = turn * 2 * .pi
        return Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: size.width, height: size.height)
            .clipped()
            .blur(radius: 36, opaque: true)
            .saturation(1.35)
            // Blurs once: the movement below only moves the finished picture.
            .drawingGroup()
            .scaleEffect(1.5 + 0.1 * sin(2 * angle))
            .rotationEffect(.radians(0.08 * sin(angle)))
            .offset(x: size.width * 0.05 * cos(angle), y: size.height * 0.04 * sin(angle))
    }

    private var scrim: some View {
        let strength = CoverLuminance.scrim(brightness: brightness)
        return LinearGradient(
            stops: [
                .init(color: .black.opacity(strength.top), location: 0),
                .init(color: .black.opacity(strength.middle), location: 0.4),
                .init(color: .black.opacity(strength.bottom), location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

/// Flutter's sideways swipe on the cover: reports the speed of a sideways drag when it ends. A UIKit
/// recognizer, so it declines vertical drags and leaves them to pulling the player closed.
struct SidewaysFling: UIGestureRecognizerRepresentable {
    let onEnd: (CGFloat) -> Void

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) > abs(velocity.y)
        }

        /// The pages' sideways scroll waits, so a swipe that starts on the cover changes the song.
        func gestureRecognizer(
            _ recognizer: UIGestureRecognizer,
            shouldBeRequiredToFailBy other: UIGestureRecognizer
        ) -> Bool {
            other.view is UIScrollView
        }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        return pan
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        if recognizer.state == .ended {
            onEnd(recognizer.velocity(in: recognizer.view).x)
        }
    }
}

/// Flutter `PlayerUiSettingsService`'s switches that Navinx keeps (C22).
nonisolated enum PlayerDisplayOptions {
    /// "Show Star Ratings", off by default (Flutter's key).
    static let showsRatingStars = "player_show_star_ratings"
}

/// Flutter `_buildStarRatingRow` (C22, D91): five plain stars for the current song, filled in
/// Flutter's amber up to its rating. A tap sets that many; a tap on the current rating clears it.
/// The stars change at once and change back with a toast if the server says no; fast taps keep the
/// newest (`PlayerModel.setRating`).
struct RatingStars: View {
    /// Small screens and landscape: Flutter's smaller stars.
    let isCompact: Bool

    @Environment(PlayerModel.self) private var player
    @Environment(ToastCenter.self) private var toasts

    var body: some View {
        let rating = player.currentSong?.userRating ?? 0
        HStack(spacing: 0) {
            ForEach(1...5, id: \.self) { star in
                Button {
                    rate(star == rating ? 0 : star)
                } label: {
                    // Material's rounded star at 24 (20) draws about as large as this symbol at 20 (17).
                    Image(systemName: star <= rating ? "star.fill" : "star")
                        .font(.system(size: isCompact ? 17 : 20, weight: .medium))
                        .foregroundStyle(star <= rating ? Color(hex: 0xFFB800) : .white.opacity(0.38))
                        .frame(width: isCompact ? 44 : 48, height: isCompact ? 36 : 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(star) \(star == 1 ? "star" : "stars")")
                .accessibilityAddTraits(star <= rating ? .isSelected : [])
                .accessibilityIdentifier("star\(star)")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Rating")
        .accessibilityValue("\(rating) of 5")
        .accessibilityIdentifier("nowPlayingStars")
    }

    private func rate(_ stars: Int) {
        guard let id = player.currentSong?.id else { return }
        Task {
            do {
                try await player.setRating(songID: id, rating: stars)
            } catch {
                toasts.show("Failed to set rating: \(error.localizedDescription)")
            }
        }
    }
}
