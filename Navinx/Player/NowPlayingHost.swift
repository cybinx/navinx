import PlaybackKit
import SubsonicKit
import SwiftUI
import UIKit

/// What's inside the full-screen presentation: now playing, grown out of the mini-player and dragged back
/// into it (`PlayerOpening`).
struct NowPlayingHost: View {
    @Environment(PlayerOpening.self) private var transition
    @Environment(PlayerModel.self) private var player
    @Environment(AccountModel.self) private var account
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The half it opens to on the Duo's inner display (C30 bug 17); nil for the whole window.
    @Environment(\.nowPlayingArea) private var area

    /// 0 in the mini-player, 1 open.
    @State private var progress: CGFloat = 0
    /// How far the page is dragged down.
    @State private var drag: CGFloat = 0
    @State private var isClosing = false
    /// True while the page springs back to rest after a short pull or a grab mid-close: `drag` is
    /// already 0 then, but the page is still drawn moved and scaled (C66).
    @State private var isSettling = false
    /// The page's own frame in the window (its safe area) and the window's.
    @State private var pageFrame: CGRect = .zero
    @State private var window: CGRect = .zero

    private var isLandscape: Bool { window.width > window.height }

    var body: some View {
        let covers = NowPlayingCovers.cached(for: player.currentSong?.coverArt, client: account.client)
        NowPlayingView()
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                // Measured through the drag's own offset and scale, so only at rest. Not while it springs
                // back either: each frame of that would move the anchor, backdrop and clip it is drawn with.
                guard drag == 0, !isClosing, !isSettling else { return }
                pageFrame = frame
                // The whole window, safe areas and all (a view that ignores them here still reported the
                // safe area's frame), or the Duo's half.
                window = area ?? UIKitTabBar.controller?.view.window?.bounds ?? frame
            }
            .modifier(NowPlayingMorphEffect(
                progress: progress,
                drag: drag,
                window: window,
                page: pageFrame,
                capsule: capsuleFrame,
                miniArt: miniArtFrame,
                cover: transition.coverFrame,
                coverScale: player.isPlaying ? 1 : 0.86,
                coverImage: covers.cover,
                backdrop: covers.tiny,
                coverArt: player.currentSong?.coverArt,
                crossFades: reduceMotion
            ))
            .gesture(DownwardPan(isEnabled: canDrag, onChange: dragged, onEnd: letGo))
            // A tap while it's closing brings it back, the way a grab mid-flight does in Apple Music.
            .simultaneousGesture(TapGesture().onEnded { if isClosing { reopen() } }, isEnabled: isClosing)
            .presentationBackground(.clear)
            .onAppear(perform: open)
            .onChange(of: transition.closeRequests) { close(velocity: 0) }
            .onChange(of: drag != 0 || isClosing || isSettling) { _, isMoving in transition.isMoving = isMoving }
    }

    /// Only the player's page drags, and not in landscape (Flutter's). The Duo's half is upright, so it does.
    private var canDrag: Bool {
        transition.isOnPlayerPage && !isLandscape && !isClosing && progress == 1
    }

    /// Where the page shrinks into: the mini-player's capsule, or the foot of the screen without one.
    private var capsuleFrame: CGRect {
        let frame = transition.capsuleFrame
        guard frame.width > 1 else {
            return CGRect(x: window.midX - 120, y: window.maxY - 120, width: 240, height: 56)
        }
        return frame
    }

    private var miniArtFrame: CGRect {
        let frame = transition.miniArtFrame
        guard frame.width > 1 else {
            return CGRect(x: capsuleFrame.minX + 10, y: capsuleFrame.midY - 18, width: 36, height: 36)
        }
        return frame
    }

    private func open() {
        progress = 0
        drag = 0
        // One frame for the page to lay out and report its cover, then it grows.
        Task { @MainActor in
            await Task.yield()
            withAnimation(openAnimation) {
                progress = 1
            } completion: {
                if !isClosing { transition.isSettled = true }
            }
        }
    }

    private func reopen() {
        isClosing = false
        isSettling = true
        withAnimation(openAnimation) {
            progress = 1
            drag = 0
        } completion: {
            guard !isClosing else { return }
            isSettling = false
            transition.isSettled = true
        }
    }

    private var openAnimation: Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.45, bounce: 0)
    }

    /// Back into the mini-player; `velocity` is the finger's, down, in points a second.
    private func close(velocity: CGFloat) {
        guard !isClosing else { return }
        isClosing = true
        isSettling = false
        // The bar may have folded or come back since it opened. (On the Duo's inner display the mini-player
        // is off while the player is open; the frame read at the open stays, which is where it comes back.)
        transition.readPlayerBar()
        transition.isSettled = false
        let animation: Animation
        if reduceMotion {
            animation = .easeInOut(duration: 0.2)
        } else {
            // The finger's speed as a share of the way left to go, per second.
            let remaining = max(capsuleFrame.minY - (window.minY + drag), 120)
            animation = .interpolatingSpring(.init(duration: 0.45, bounce: 0), initialVelocity: max(velocity, 0) / remaining)
        }
        withAnimation(animation, completionCriteria: .logicallyComplete) {
            progress = 0
        } completion: {
            guard isClosing else { return }
            isClosing = false
            drag = 0
            transition.finishClosing()
        }
    }

    private func dragged(_ translation: CGFloat) {
        drag = max(translation, 0)
    }

    private func letGo(_ velocity: CGFloat) {
        if NowPlayingMorph.closes(drag: drag, velocity: velocity, height: window.height) {
            close(velocity: velocity)
        } else {
            isSettling = true
            withAnimation(.spring(duration: 0.35, bounce: 0)) {
                drag = 0
            } completion: {
                // A new pull meanwhile keeps `drag` off 0, which keeps the measuring off by itself.
                isSettling = false
            }
        }
    }
}

/// Draws now playing at a point of its open and close; `progress` and `drag` animate.
private struct NowPlayingMorphEffect: ViewModifier, Animatable {
    var progress: CGFloat
    var drag: CGFloat
    let window: CGRect
    let page: CGRect
    let capsule: CGRect
    let miniArt: CGRect
    let cover: CGRect?
    let coverScale: CGFloat
    let coverImage: UIImage?
    let backdrop: UIImage?
    let coverArt: String?
    let crossFades: Bool

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(progress, drag) }
        set {
            progress = newValue.first
            drag = newValue.second
        }
    }

    func body(content: Content) -> some View {
        if crossFades {
            content
                .offset(y: drag)
                .opacity(progress)
        } else {
            morphed(content)
        }
    }

    private func morphed(_ content: Content) -> some View {
        let p = min(max(progress, 0), 1)
        let scale = NowPlayingMorph.lerp(1, NowPlayingMorph.scale(forDrag: drag, height: window.height), p)
        let shape = NowPlayingMorph.pageFrame(p: p, drag: drag, capsule: capsule, window: window)
        let radius = NowPlayingMorph.cornerRadius(p: p, drag: drag, capsule: capsule)
        // The page scales about the window's centre, like its shape.
        let anchor = UnitPoint(
            x: page.width > 0 ? (window.midX - page.minX) / page.width : 0.5,
            y: page.height > 0 ? (window.midY - page.minY) / page.height : 0.5
        )
        let isFlying = p < 1 && cover != nil
        return content
            .environment(\.nowPlayingHidesCover, isFlying)
            .opacity(NowPlayingMorph.ramp(p, from: 0.3, to: 1))
            .scaleEffect(scale, anchor: anchor)
            .offset(y: drag * p)
            .background(alignment: .topLeading) {
                // The backdrop fills the shape first: all of the window and the capsule (on the Duo's inner
                // display the capsule runs across the app's half, outside the page, C30 bug 17).
                let behind = window.union(capsule)
                CoverWash(image: backdrop, brightness: NowPlayingCovers.brightness(of: backdrop))
                    .frame(width: behind.width, height: behind.height)
                    .offset(x: behind.minX - page.minX, y: behind.minY - page.minY)
                    .opacity(NowPlayingMorph.ramp(p, from: 0.04, to: 0.25))
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .topLeading) {
                if isFlying, let cover {
                    travellingCover(cover: cover, p: p)
                }
            }
            .clipShape(WindowRect(rect: shape.offsetBy(dx: -page.minX, dy: -page.minY), cornerRadius: radius))
    }

    /// The cover's copy, from the mini art to the big cover.
    private func travellingCover(cover: CGRect, p: CGFloat) -> some View {
        let shown = NowPlayingMorph.moved(
            cover,
            scale: coverScale,
            about: CGPoint(x: cover.midX, y: cover.midY),
            drag: 0
        )
        let frame = NowPlayingMorph.artFrame(p: p, drag: drag, miniArt: miniArt, cover: shown, window: window)
        let radius = NowPlayingMorph.lerp(NowPlayingMorph.miniArtRadius, NowPlayingMorph.coverRadius * coverScale, p)
        return Group {
            if let coverImage {
                Image(uiImage: coverImage).resizable().scaledToFill()
            } else {
                AlbumArtwork(coverArt: coverArt, size: frame.width, cornerRadius: 0)
            }
        }
        .frame(width: frame.width, height: frame.height)
        .clipShape(.rect(cornerRadius: radius))
        .shadow(color: .black.opacity(0.35 * p), radius: 12 * p, y: 10 * p)
        .offset(x: frame.minX - page.minX, y: frame.minY - page.minY)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A rounded rect given in the view's own coordinates, which may run past its bounds (into the safe area).
nonisolated private struct WindowRect: Shape {
    var rect: CGRect
    var cornerRadius: CGFloat

    func path(in _: CGRect) -> Path {
        Path(roundedRect: rect, cornerRadius: min(cornerRadius, rect.height / 2, rect.width / 2), style: .continuous)
    }
}

extension EnvironmentValues {
    /// True while now playing's cover is flying (its copy is drawn instead).
    @Entry var nowPlayingHidesCover = false
}

/// A pan that starts only downwards and mostly vertical, so the pages' sideways swipe, the cover's
/// fling and the sliders keep theirs. Reports the window's translation and speed, down.
private struct DownwardPan: UIGestureRecognizerRepresentable {
    let isEnabled: Bool
    let onChange: (CGFloat) -> Void
    let onEnd: (CGFloat) -> Void

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var isEnabled = true

        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard isEnabled, let pan = recognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: nil)
            return velocity.y > 0 && abs(velocity.y) > abs(velocity.x)
        }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        return pan
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
        context.coordinator.isEnabled = isEnabled
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        switch recognizer.state {
        case .changed:
            onChange(recognizer.translation(in: nil).y)
        case .ended, .cancelled, .failed:
            onEnd(recognizer.velocity(in: nil).y)
        default:
            break
        }
    }
}
