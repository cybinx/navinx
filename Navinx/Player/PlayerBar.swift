import PlaybackKit
import SubsonicKit
import SwiftUI
import UIKit

/// Flutter `MiniPlayer`, in the tab bar's accessory: the system draws its capsule. Tapping opens now
/// playing; long press is the song options. Inline, every control but play/pause folds away.
///
/// Flutter's optional heart, shuffle and repeat buttons aren't built, as in Apple Music (D64).
struct PlayerBar: View {
    /// On the iPhone Duo's cover display, where the system never folds the bar, the landscape fold draws
    /// the inline layout itself (C17, D78).
    var forcesInline = false
    /// The Duo's melt draws the cover itself, moving between the capsule and the circle (C26).
    var hidesArt = false
    let onOpen: () -> Void

    @Environment(PlayerModel.self) private var player
    @Environment(PlayerOpening.self) private var nowPlaying: PlayerOpening?
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    private var isInline: Bool { forcesInline || placement == .inline }

    /// How far the art and title are moved sideways: under the finger, then out and back in on a skip.
    @State private var slide: CGFloat = 0
    @State private var slideOpacity: Double = 1

    var body: some View {
        content
            // The bar's fold, for the unfold at the top of a page (C26, D104). Also when the accessory is made
            // again (after Settings, the Duo's split, an account switch): the bar may have folded meanwhile.
            // (The copies drawn outside the accessory have no placement and report nothing.)
            .onChange(of: placement, initial: true) { old, placement in
                guard !forcesInline, placement != nil || old != nil else { return }
                UIKitTabBar.barFolded(placement == .inline)
            }
    }

    @ViewBuilder private var content: some View {
        if let song = player.currentSong {
            HStack(spacing: 12) {
                HStack(spacing: 12) {
                    AlbumArtwork(
                        coverArt: song.coverArt,
                        size: isInline ? 28 : 36,
                        cornerRadius: isInline ? 7 : 9
                    )
                    // Now playing's cover flies from and into here, so the art hides while it's up (C26).
                    .opacity(hidesArt || (placement != nil && nowPlaying?.isPresented == true) ? 0 : 1)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(song.title)
                            .font(.system(size: 15, weight: .semibold))
                            .lineLimit(1)
                            .accessibilityIdentifier("playerBarTitle")
                        let artists = song.displayArtists.map(\.name).joined(separator: ", ")
                        if !artists.isEmpty {
                            Text(artists)
                                .font(.system(size: 13))
                                .foregroundStyle(Palette.secondaryText)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .offset(x: slide)
                .opacity(slideOpacity)
                controls
            }
            .padding(.leading, isInline ? 9 : 10)
            .padding(.trailing, isInline ? 2 : 8)
            .frame(maxHeight: .infinity)
            .contentShape(.rect)
            .onTapGesture(perform: onOpen)
            // A swipe left is Next, right is Previous, as the buttons (C30 bug 13; Apple Music's).
            .gesture(SidewaysDrag(onChange: follow, onEnd: release))
            .songContextMenu(song)
            .overlay(alignment: .bottom) {
                PlayerBarProgress()
                    .padding(.horizontal, 26)
                    .padding(.bottom, 2)
            }
            .accessibilityAction(named: "Open Now Playing", onOpen)
        }
    }

    // MARK: The swipe (C30 bug 13)

    /// How far a swipe has to go, or how fast, to change the song.
    nonisolated static let skipDistance: CGFloat = 50
    nonisolated static let skipSpeed: CGFloat = 300
    /// How far the art and title go out and come back in from on a skip.
    private static let slideOut: CGFloat = 44

    /// Which way a released swipe goes: -1 Next (left), 1 Previous (right), 0 back to rest.
    nonisolated static func skipDirection(translation: CGFloat, velocity: CGFloat) -> Int {
        if translation < -skipDistance || (velocity < -skipSpeed && translation < 0) { return -1 }
        if translation > skipDistance || (velocity > skipSpeed && translation > 0) { return 1 }
        return 0
    }

    /// The art and title follow the finger, held back so they never leave the capsule.
    private func follow(_ translation: CGFloat) {
        let limit = Self.slideOut
        slide = limit * tanh(translation / (limit * 2.5))
    }

    private func release(translation: CGFloat, velocity: CGFloat) {
        let direction = Self.skipDirection(translation: translation, velocity: velocity)
        guard direction != 0 else {
            withAnimation(.snappy(duration: 0.25)) { slide = 0 }
            return
        }
        let out = CGFloat(direction) * Self.slideOut
        withAnimation(.easeIn(duration: 0.12)) {
            slide = out
            slideOpacity = 0
        } completion: {
            if direction < 0 { player.skipNext() } else { player.skipPrevious() }
            // The next song comes in from the other side.
            withTransaction(\.disablesAnimations, true) { slide = -out }
            withAnimation(.snappy(duration: 0.28)) {
                slide = 0
                slideOpacity = 1
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 0) {
            Button(player.isPlaying ? "Pause" : "Play", systemImage: player.isPlaying ? "pause.fill" : "play.fill") {
                player.playOrPause()
            }
            .font(.system(size: 19.5))
            .contentTransition(.symbolEffect(.replace))
            .frame(width: 40, height: 40)
            .accessibilityIdentifier("playerBarPlayPause")
            if !isInline {
                // Never disabled: on the last song it ends the queue (D25).
                Button("Next", systemImage: "forward.fill") { player.skipNext() }
                    .font(.system(size: 16))
                    .frame(width: 36, height: 36)
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
    }
}

/// A sideways pan that begins only when the finger moves more sideways than up or down, so a tap, the
/// long press and the page's own scrolling are left alone (as `SidewaysFling`, with the finger followed).
private struct SidewaysDrag: UIGestureRecognizerRepresentable {
    let onChange: (CGFloat) -> Void
    let onEnd: (_ translation: CGFloat, _ velocity: CGFloat) -> Void

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) > abs(velocity.y)
        }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        return pan
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let translation = recognizer.translation(in: recognizer.view).x
        switch recognizer.state {
        case .began, .changed: onChange(translation)
        case .ended: onEnd(translation, recognizer.velocity(in: recognizer.view).x)
        case .cancelled, .failed: onEnd(0, 0)
        default: break
        }
    }
}

/// Flutter `_MiniPlayerProgressBar`: the inset rounded hairline, in its own view so the time only
/// redraws this. Its label gives VoiceOver and the UI tests the time.
private struct PlayerBarProgress: View {
    @Environment(PlayerModel.self) private var player
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Rectangle().fill(colorScheme == .dark ? Color.white.opacity(0.14) : Color.black.opacity(0.08))
                Rectangle()
                    .fill(LinearGradient(
                        colors: [Palette.accent, Palette.accent.opacity(0.85)],
                        startPoint: .leading,
                        endPoint: .trailing
                    ))
                    .frame(width: proxy.size.width * player.progress)
                    .clipShape(.capsule)
            }
            .clipShape(.capsule)
        }
        .frame(height: 2)
        .allowsHitTesting(false)
        .accessibilityElement()
        .accessibilityLabel("\(PlayerTime.format(player.position)) / \(PlayerTime.format(player.duration))")
        .accessibilityIdentifier("playerBarTime")
    }
}
