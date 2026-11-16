import SwiftUI
import UIKit
import os

private let chromeLog = Logger(subsystem: "com.cybinx.navinx.app", category: "chrome")

// The tab bar's forced unfold, drawn (C32). When the system won't unfold the bar itself (the touch that
// folded it came back to the top and lifted: no nudge after that is taken), `UIKitTabBar` flips it open,
// which the system does in one frame. So that the mini-player doesn't jump, the app draws its own copy of
// it, the way the Duo's fold does (`DuoFoldedPlayerBar`): the copy starts over the folded accessory, the
// real accessory, glass and all, is made transparent (the alpha of the one view that holds it), and the copy
// rises and widens into the open accessory's place on the system's own timing (about 0.2 s, measured in its
// frames), its inline content giving way to the full one. After a flip UIKit draws the accessory over the
// bar for up to 0.7 s while its frame already says open: hiding only its content left that empty glass
// there (the user's phone, C32). Once the copy has landed and the real accessory is drawn where it belongs,
// it comes back and the copy goes in the same update. Nothing of UIKit's is moved: moving the accessory's
// views (C32's first try) left it over the bar for a second. (A SwiftUI opacity on the content also made
// XCUITest find the mini-player unhittable afterwards, though taps worked.)

/// The copy's flight: where it is, and whether the real accessory's content is hidden meanwhile.
@MainActor @Observable
final class UnfoldFlight {
    static let shared = UnfoldFlight()

    enum Stage: Equatable {
        case none
        /// The copy over the folded accessory, about to fly (the open frame isn't laid out yet).
        case waiting(from: CGRect)
        /// Flying to (or landed in) the open accessory's place; `progress` animates 0 to 1.
        case flying(from: CGRect, to: CGRect)
    }

    private(set) var stage = Stage.none
    private(set) var progress: CGFloat = 0
    /// The real accessory is transparent while the copy stands in for it.
    var hidesRealContent: Bool { stage != .none }

    /// Where the copy flies from and to (the same place until the open one is known).
    var frames: (from: CGRect, to: CGRect)? {
        switch stage {
        case .none: nil
        case .waiting(let from): (from, from)
        case .flying(let from, let to): (from, to)
        }
    }

    /// Bumped by every flight, so the steps of one that has ended do nothing.
    private var turn = 0
    private var landed = false

    /// The flight's spring: the system's unfold settles in about 0.2 s (C32's frames).
    static let flightDuration: Double = 0.24
    /// The longest the copy stands in, landing and hand-over included.
    static let timeLimit: Duration = .milliseconds(1200)

    /// The copy goes over the folded accessory and the real content is hidden, before the flip.
    /// `accessory` is the view that holds the system accessory's glass and content and nothing else: it is
    /// made transparent until the hand-over, or its empty glass stays over the bar while UIKit's layer lags.
    /// `onEnd` runs once, however the flight ends (C41: the gate's completion of the forced opening).
    func begin(from folded: CGRect, hiding accessory: UIView? = nil, onEnd: (@MainActor () -> Void)? = nil) {
        end()
        turn += 1
        let mine = turn
        landed = false
        chromeLog.debug("flight begin \(String(describing: folded))")
        self.onEnd = onEnd
        hiddenAccessory = accessory
        accessory?.alpha = 0
        withTransaction(\.disablesAnimations, true) {
            progress = 0
            stage = .waiting(from: folded)
        }
        Task { @MainActor in
            try? await Task.sleep(for: Self.timeLimit)
            guard turn == mine, stage != .none else { return }
            chromeLog.debug("flight time limit")
            end()
        }
    }

    /// The bar is open: the copy flies to `open` (the accessory's frame in the open layout).
    func fly(to open: CGRect?) {
        guard case .waiting(let from) = stage else { return }
        guard let open, open.width > 1, open != from else {
            end()
            return
        }
        let mine = turn
        chromeLog.debug("flight to \(String(describing: open))")
        withTransaction(\.disablesAnimations, true) { stage = .flying(from: from, to: open) }
        withAnimation(.spring(duration: Self.flightDuration, bounce: 0)) {
            progress = 1
        } completion: { [weak self] in
            guard let self, self.turn == mine else { return }
            self.landed = true
            self.handOverWhenReady(mine)
        }
    }

    /// Back to the real accessory once it is drawn in its open place (its layer can lag behind its frame).
    private func handOverWhenReady(_ mine: Int) {
        Task { @MainActor in
            while turn == mine, stage != .none {
                if UIKitTabBar.accessoryIsSettled() {
                    chromeLog.debug("flight hand-over")
                    end()
                    return
                }
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    /// Ends the flight at once, from wherever it is: the real content back, the copy gone, in one update.
    /// Every way out goes through here (a fold, a touch, a push, now playing, the accessory going, the limit).
    func end() {
        guard stage != .none else { return }
        turn += 1
        hiddenAccessory?.alpha = 1
        hiddenAccessory = nil
        withTransaction(\.disablesAnimations, true) {
            stage = .none
            progress = 0
        }
        let ended = onEnd
        onEnd = nil
        ended?()
    }

    @ObservationIgnored private var onEnd: (@MainActor () -> Void)?

    /// The system accessory's view made transparent for the flight (weak: an accessory rebuilt meanwhile is
    /// a new view, at its own alpha).
    @ObservationIgnored private weak var hiddenAccessory: UIView?
}

/// The copy, drawn over the whole window (the phone only; nothing while no flight runs).
struct UnfoldFlightCopy: View {
    let onOpen: () -> Void
    private var flight: UnfoldFlight { .shared }

    var body: some View {
        GeometryReader { _ in
            ZStack(alignment: .topLeading) {
                Color.clear
                // One view from the wait to the landing, so the flight animates (two branches swapped it).
                if let frames = flight.frames {
                    FlightGlass(t: flight.progress, from: frames.from, to: frames.to, onOpen: onOpen)
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(flight.stage != .none)
    }
}

/// The copy's glass at a point `t` of the flight, from the folded accessory to the open one.
private struct FlightGlass: View, Animatable {
    var t: CGFloat
    let from: CGRect
    let to: CGRect
    let onOpen: () -> Void

    var animatableData: CGFloat {
        get { t }
        set { t = newValue }
    }

    var body: some View {
        let frame = CGRect(
            x: lerp(from.minX, to.minX),
            y: lerp(from.minY, to.minY),
            width: lerp(from.width, to.width),
            height: lerp(from.height, to.height)
        )
        // The inline form gives way to the full one, which the system shows last (Next appears late).
        let full = min(max((t - 0.35) / 0.5, 0), 1)
        return ZStack {
            PlayerBar(forcesInline: true, onOpen: onOpen)
                .opacity(1 - full)
            PlayerBar(onOpen: onOpen)
                .opacity(full)
        }
        .frame(width: frame.width, height: frame.height)
        .clipShape(.capsule)
        .appGlass(in: .capsule)        .position(x: frame.midX, y: frame.midY)
        .accessibilityHidden(true)
    }

    private func lerp(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * t }
}
