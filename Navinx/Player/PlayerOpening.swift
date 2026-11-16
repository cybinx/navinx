import PlaybackKit
import SubsonicKit
import SwiftUI
import UIKit

// Now playing opens and closes Apple Music's way (C26, D102, D104), in place of the system's zoom (D76).
//
// One page rises out of the mini-player: its shape grows from the accessory's capsule to the whole
// screen, rounded like the display's corners on the way, while a copy of the cover flies from the mini
// art to the big cover; the backdrop fills the shape first and the controls fade in late. Dragged down
// on the player's page, it follows the finger, rounds and shrinks a little; let go past a third of the
// height or flicked down, it goes back into the mini-player the same way, else it springs back. Only the
// player's page drags (the lyrics and the queue scroll), landscape doesn't drag (Flutter's), and with
// Reduce Motion it cross-fades.
//
// It's drawn in a full-screen presentation that comes and goes with no animation of its own and a clear
// background, so the app shows behind it; that keeps now playing's dark scheme and light status bar to
// itself, its VoiceOver modal, and its sheets. The mini-player sits in the system's accessory, which
// SwiftUI's matched geometry can't reach, so only its frames are read (`PlayerBar`).

/// The open and close: whether the page is up, and the frames it grows from and into.
@MainActor @Observable
final class PlayerOpening {
    /// The full-screen presentation that holds the page; it shows and hides with no animation.
    private(set) var isPresented = false
    /// Bumped to ask the page to close with its animation.
    private(set) var closeRequests = 0
    /// The mini-player's capsule and its art, in the window.
    var capsuleFrame: CGRect = .zero
    var miniArtFrame: CGRect = .zero
    /// The big cover's frame in the window at rest, before its paused scale.
    private(set) var coverFrame: CGRect?
    /// While a drag or a close moves the page, the cover's frame isn't at rest.
    var isMoving = false
    /// Whether the player's page is showing (the only one that drags).
    var isOnPlayerPage = true
    /// The page has finished opening and no close has begun: on the Duo's inner display the app keeps the
    /// half left of the hinge only then, so the page grows out of the mini-player over the whole app and
    /// shrinks back into it the same way (C30 bug 17).
    var isSettled = false

    func open() {
        guard !isPresented else { return }
        isOnPlayerPage = true
        isSettled = false
        isMoving = false
        readPlayerBar()
        withTransaction(\.disablesAnimations, true) { isPresented = true }
    }

    /// Reads where the mini-player is now, from UIKit: SwiftUI's geometry inside the system's accessory
    /// goes stale when UIKit moves it (C26). The art is 10 pt in and 36 pt big, or 9 pt and 28 pt inline.
    func readPlayerBar() {
        guard let capsule = UIKitTabBar.accessoryFrame() else { return }
        capsuleFrame = capsule
        let isInline = UIKitTabBar.isFolded
        let size: CGFloat = isInline ? 28 : 36
        miniArtFrame = CGRect(x: capsule.minX + (isInline ? 9 : 10), y: capsule.midY - size / 2, width: size, height: size)
    }

    /// Closes with the animation (the chevron, a page opened from the player, the queue running out).
    func close() {
        guard isPresented else { return }
        closeRequests += 1
    }

    /// The animation has ended in the mini-player.
    func finishClosing() {
        withTransaction(\.disablesAnimations, true) {
            isPresented = false
            isSettled = false
        }
        // The host goes in this same update, so its own report of the close's end may never come.
        isMoving = false
    }

    func coverMoved(to frame: CGRect) {
        guard !isMoving, frame.width > 1 else { return }
        coverFrame = frame
    }
}

/// The geometry of the morph, kept apart so it can be tested.
nonisolated enum NowPlayingMorph {
    /// The display's corner radius on the iPhone 17 Pro (UIKit's is private).
    static let displayCornerRadius: CGFloat = 55
    /// Past this share of the height, or faster than `closeSpeed` (pt/s), a drag closes the page.
    static let closeShare: CGFloat = 1.0 / 3.0
    static let closeSpeed: CGFloat = 800
    /// How small the page gets while dragged.
    static let smallestScale: CGFloat = 0.94
    static let miniArtRadius: CGFloat = 9
    static let coverRadius: CGFloat = 16

    static func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }

    static func lerp(_ a: CGRect, _ b: CGRect, _ t: CGFloat) -> CGRect {
        CGRect(
            x: lerp(a.minX, b.minX, t),
            y: lerp(a.minY, b.minY, t),
            width: lerp(a.width, b.width, t),
            height: lerp(a.height, b.height, t)
        )
    }

    /// 0 before `start`, 1 after `end`, straight in between.
    static func ramp(_ t: CGFloat, from start: CGFloat, to end: CGFloat) -> CGFloat {
        min(max((t - start) / (end - start), 0), 1)
    }

    /// How small the page is when dragged down by `drag` points in a window `height` tall: it reaches
    /// `smallestScale` at half the height.
    static func scale(forDrag drag: CGFloat, height: CGFloat) -> CGFloat {
        guard height > 0 else { return 1 }
        return 1 - (1 - smallestScale) * min(max(drag, 0) / (height / 2), 1)
    }

    /// `rect` as the page's scale and offset move it: scaled about `centre`, then moved down by `drag`.
    static func moved(_ rect: CGRect, scale: CGFloat, about centre: CGPoint, drag: CGFloat) -> CGRect {
        CGRect(
            x: centre.x + (rect.minX - centre.x) * scale,
            y: centre.y + (rect.minY - centre.y) * scale + drag,
            width: rect.width * scale,
            height: rect.height * scale
        )
    }

    /// Whether letting go closes the page.
    static func closes(drag: CGFloat, velocity: CGFloat, height: CGFloat) -> Bool {
        drag > height * closeShare || velocity > closeSpeed
    }

    /// The page's shape at progress `p` (0 in the mini-player, 1 open) and a drag: from the capsule to
    /// the window, moved with the drag.
    static func pageFrame(p: CGFloat, drag: CGFloat, capsule: CGRect, window: CGRect) -> CGRect {
        let scale = scale(forDrag: drag, height: window.height)
        let open = moved(window, scale: scale, about: CGPoint(x: window.midX, y: window.midY), drag: drag)
        return lerp(capsule, open, p)
    }

    /// The flying cover's frame at progress `p`: from the mini art to the big cover, moved with the drag.
    static func artFrame(p: CGFloat, drag: CGFloat, miniArt: CGRect, cover: CGRect, window: CGRect) -> CGRect {
        let scale = scale(forDrag: drag, height: window.height)
        let open = moved(cover, scale: scale, about: CGPoint(x: window.midX, y: window.midY), drag: drag)
        return lerp(miniArt, open, p)
    }

    /// The page's corner radius: the capsule's, the display's on the way and while dragged, and none at
    /// rest (the display's own corners round it then).
    static func cornerRadius(p: CGFloat, drag: CGFloat, capsule: CGRect) -> CGFloat {
        if p >= 1 { return displayCornerRadius * min(max(drag, 0) / 40, 1) }
        return lerp(capsule.height / 2, displayCornerRadius, p)
    }
}
