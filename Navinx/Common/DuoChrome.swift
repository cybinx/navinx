import PlaybackKit
import SubsonicKit
import SwiftUI
import os

private let duoLog = Logger(subsystem: "com.cybinx.navinx.app", category: "duo")

// The mini-player on the iPhone Duo's cover display (C17, D78; the melt, C26, D104).
//
// The system's bottom capsule stays in the content pane, but on this display the side rail never
// folds (the system's minimise on scroll does nothing there: `docs/log/C14.md`), so the fold is built
// here. Scrolling a page down by about as much as the system needs (70 pt) folds the mini-player, and a
// page that arrives at its top, or a tap on what it folded into, brings it back:
// - Portrait: the capsule goes and the album cover stands in the strip as its own glass circle, above the
//   side rail, centred on it. The strip has little room.
// - Landscape: the capsule shrinks to its inline form (the cover, the title and play/pause) in the
//   content pane's foot.
//
// The fold melts (C26): the system draws the accessory, out of SwiftUI's reach, so at the fold it's
// switched off with no animation and an identical copy is put in its place, which then turns into the
// circle (or the small capsule), one glass whose frame and corners animate, the cover moving with it. The
// unfold is the same backwards, ending with the system's accessory switched back on under the copy. With
// Reduce Motion it cross-fades.
//
// In portrait the copy moves like a water drop (C30 bug 19, the user's): it gathers into a drop running
// right along the foot of the page to the strip, rises up the strip to its place above the rail, and lands
// there with a little jiggle; the unfold runs the other way, down the strip and left into the capsule
// (`DuoDrop`). Landscape's small capsule keeps C26's straight melt.

/// Whether the mini-player is folded, what the overlay draws, and how far the page has gone down.
@MainActor @Observable
final class DuoChrome {
    /// What the overlay draws over the system's accessory.
    enum Stage {
        /// Nothing: the system's accessory shows.
        case none
        /// The copy of the accessory's capsule, where the accessory was.
        case capsule
        /// The circle (portrait) or the small capsule (landscape).
        case folded
    }

    /// Folded, or on its way there: what the last animation started went to.
    private(set) var isFolded = false
    private(set) var stage = Stage.none
    /// The system's accessory is switched off (once the copy covers it).
    private(set) var hidesAccessory = false
    /// The system accessory's frame in the window, where the copy goes.
    private(set) var accessoryFrame: CGRect = .zero
    /// Where portrait's drop is on its way (`DuoDrop`): 0 the capsule, 1 landed in the circle.
    private(set) var dropProgress: CGFloat = 0
    /// What the page last asked for (C41: the newest ask only, never a list). The gate lets one fold or
    /// unfold run at a time; when it opens, this says which, if any, comes next.
    private var wantsFolded = false
    /// Waiting for a finger to lift before the next animation may start.
    private var waitsForFinger = false
    /// Bumped by every fold, unfold and reset: a step of one that a reset has dropped does nothing more.
    private var turn = 0
    private var lastOffset: CGFloat = 0
    private var downRun: CGFloat = 0
    /// Settings or Add Server is open, with no mini-player to fold: their scrolling is ignored, or the
    /// page under them would come back to a folded circle nothing unfolds.
    var ignoresScrolling = false
    private let gate: ChromeGate

    init(gate: ChromeGate = .shared) {
        self.gate = gate
    }

    /// How far down a page goes before the mini-player folds (the system's own is 65 to 75 pt).
    static let foldDistance: CGFloat = 70
    /// Landscape's melt (C26: a little bounce, as a drop settling).
    static let melt = Animation.spring(duration: 0.45, bounce: 0.15)
    static let fade = Animation.easeInOut(duration: 0.2)
    /// How long the system takes to fade its accessory out or in, which it does whatever the transaction
    /// says (measured in C26): the copy covers it meanwhile.
    private static let accessoryFade: Duration = .milliseconds(220)

    /// A page's vertical scroll offset, 0 at its top. A page that can't scroll reports 0.
    func scrolled(to offset: CGFloat) {
        guard !ignoresScrolling else { return }
        defer { lastOffset = offset }
        if offset <= 1 {
            unfold()
            return
        }
        let change = offset - lastOffset
        if change < 0 {
            downRun = 0
        } else {
            downRun += change
            if downRun > Self.foldDistance, !wantsFolded { fold() }
        }
    }

    func fold() {
        wantsFolded = true
        settle()
    }

    func unfold() {
        downRun = 0
        wantsFolded = false
        settle()
    }

    /// The overlay doesn't draw under a finger (C26): the next animation waits for it to lift, then looks.
    private func settle() {
        guard wantsFolded != isFolded, !waitsForFinger else { return }
        waitsForFinger = true
        Task { @MainActor in
            await UIKitTabBar.waitForFingerUp()
            // (After a reset there is nothing to look for: it asks for the open state it has put back.)
            waitsForFinger = false
            look()
        }
    }

    /// Starts the one animation the page now calls for, if the gate is open (C41). Closed (a fold or unfold
    /// still running), nothing starts and the gate calls this again once it has completed. (C32's reversal
    /// mid-melt, which turned the drop round where it was, is gone with it: a reversal waits for the melt.)
    private func look() {
        guard wantsFolded != isFolded else { return }
        guard !UIKitTabBar.isPageTracking else {
            settle()
            return
        }
        let folds = wantsFolded
        guard let token = gate.start(folds ? .fold : .unfold, orLater: { [weak self] in self?.look() }) else {
            duoLog.debug("duo \(folds ? "fold" : "unfold") held")
            return
        }
        isFolded = folds
        turn += 1
        if folds { runFold(token, turn) } else { runUnfold(token, turn) }
    }

    private func finish(_ token: ChromeGate.Token, _ mine: Int) {
        guard turn == mine else { return }
        gate.finished(token)
    }

    private func runFold(_ token: ChromeGate.Token, _ mine: Int) {
        duoLog.debug("duo fold")
        Task { @MainActor in
            guard !UIAccessibility.isReduceMotionEnabled, let frame = UIKitTabBar.accessoryFrame() else {
                withAnimation(Self.fade) {
                    hidesAccessory = true
                    stage = .folded
                    dropProgress = 1
                } completion: { self.finish(token, mine) }
                return
            }
            accessoryFrame = frame
            duoLog.debug("duo copy at \(String(describing: frame))")
            // The copy goes over the accessory first, then the accessory goes under it, and once it has
            // faded the copy melts.
            withTransaction(\.disablesAnimations, true) {
                stage = .capsule
                dropProgress = 0
            }
            try? await Task.sleep(for: .milliseconds(30))
            guard turn == mine else { return }
            withTransaction(\.disablesAnimations, true) { hidesAccessory = true }
            duoLog.debug("duo accessory off")
            try? await Task.sleep(for: Self.accessoryFade)
            guard turn == mine else { return }
            duoLog.debug("duo melt")
            // The progress runs evenly; `DuoDrop` eases each leg itself. (Landscape's capsule animates
            // `stage` with its own spring.) The melt's last step is the fold's completion.
            withAnimation(.linear(duration: DuoDrop.foldDuration)) {
                stage = .folded
                dropProgress = 1
            } completion: { self.finish(token, mine) }
        }
    }

    private func runUnfold(_ token: ChromeGate.Token, _ mine: Int) {
        duoLog.debug("duo unfold")
        guard stage == .folded, !UIAccessibility.isReduceMotionEnabled, accessoryFrame.width > 1 else {
            withAnimation(Self.fade) {
                hidesAccessory = false
                stage = .none
                dropProgress = 0
            } completion: { [weak self] in self?.finish(token, mine) }
            return
        }
        // Back from the landing (the jiggle isn't played backwards): down the strip and into the capsule. (The
        // fold has always landed by now: the gate let nothing start during its melt.)
        withTransaction(\.disablesAnimations, true) { dropProgress = DuoDrop.landing }
        withAnimation(.linear(duration: DuoDrop.unfoldDuration)) {
            stage = .capsule
            dropProgress = 0
        } completion: { [weak self] in
            guard let self, self.turn == mine, self.stage == .capsule else { return }
            // The system's accessory comes back under the copy, which goes once it has faded in: the unfold's
            // completion.
            withTransaction(\.disablesAnimations, true) { self.hidesAccessory = false }
            Task { @MainActor in
                try? await Task.sleep(for: Self.accessoryFade)
                guard self.turn == mine else { return }
                withTransaction(\.disablesAnimations, true) { self.stage = .none }
                self.finish(token, mine)
            }
        }
    }

    /// Straight back to the system's accessory (the strip went away: a rotation to a phone-like layout).
    func reset() {
        downRun = 0
        isFolded = false
        wantsFolded = false
        waitsForFinger = false
        turn += 1
        gate.reset()
        withTransaction(\.disablesAnimations, true) {
            hidesAccessory = false
            stage = .none
            dropProgress = 0
        }
    }
}

/// Portrait's water drop (C30 bug 19): where the glass is at a point `t` of the fold, from the accessory's
/// capsule (0) to the circle above the rail (1). Three legs on one even clock:
/// 1. **Run** (to `turn`): the capsule gathers into a drop, wider than tall as it moves, and runs right
///    along the page's foot to below the circle's place, speeding up.
/// 2. **Rise** (to `landing`): it rises up the strip, taller than wide as it goes, slowing into its place.
/// 3. **Settle**: it lands round and jiggles, a damped squash and stretch, as a drop settling.
/// The unfold runs legs 2 and 1 backwards, from `landing` to 0.
nonisolated enum DuoDrop {
    static let runTime: Double = 0.22
    static let riseTime: Double = 0.26
    static let settleTime: Double = 0.42
    static let foldDuration = runTime + riseTime + settleTime
    static let unfoldDuration = runTime + riseTime
    /// Where the run ends and the rise starts, and where the rise ends, on the 0...1 clock.
    static let turn = CGFloat(runTime / foldDuration)
    static let landing = CGFloat((runTime + riseTime) / foldDuration)

    /// The drop's stretch while it runs (wide) and rises (tall), and the jiggle's size, as shares of the circle.
    static let stretch: CGFloat = 0.28
    static let jiggle: CGFloat = 0.18

    /// The glass's frame at `t`; `circle` is where it lands.
    static func frame(at t: CGFloat, capsule: CGRect, circle: CGRect) -> CGRect {
        let d = circle.width
        let t = min(max(t, 0), 1)
        if t < turn {
            // The run: the capsule's shape gives way to a wide drop, its centre moving right at the capsule's height.
            let e = easeIn(t / turn)
            let width = lerp(capsule.width, d * (1 + stretch), e)
            let height = lerp(capsule.height, d * (1 - stretch * 0.7), e)
            let x = lerp(capsule.midX, circle.midX, e)
            return centred(x: x, y: capsule.midY, width: width, height: height)
        }
        if t < landing {
            // The rise: wide turns tall early on, then round as it slows into place.
            let u = (t - turn) / (landing - turn)
            let e = easeOut(u)
            let tall = ramp(u, 0, 0.3) - ramp(u, 0.55, 1)
            let wide = 1 - ramp(u, 0, 0.3)
            let width = d * (1 + stretch * wide - stretch * 0.7 * tall)
            let height = d * (1 - stretch * 0.7 * wide + stretch * tall)
            return centred(x: circle.midX, y: lerp(capsule.midY, circle.midY, e), width: width, height: height)
        }
        // The settle: still moving up, it stretches, then squashes, smaller each time, and is round at the end.
        let u = (t - landing) / (1 - landing)
        let wobble = jiggle * exp(-3 * u) * sin(3 * .pi * u)
        return centred(x: circle.midX, y: circle.midY, width: d * (1 - wobble * 0.8), height: d * (1 + wobble))
    }

    /// How much of the capsule's look (the title and the buttons) is left at `t`: gone early in the run.
    static func capsuleOpacity(at t: CGFloat) -> CGFloat { 1 - ramp(t, 0, turn * 0.6) }

    /// How far the cover has gone from its place in the capsule to the drop's middle: there by the turn.
    static func artProgress(at t: CGFloat) -> CGFloat { easeInOut(min(max(t / turn, 0), 1)) }

    private static func centred(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) -> CGRect {
        CGRect(x: x - width / 2, y: y - height / 2, width: width, height: height)
    }

    static func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }
    private static func ramp(_ t: CGFloat, _ start: CGFloat, _ end: CGFloat) -> CGFloat {
        min(max((t - start) / (end - start), 0), 1)
    }
    private static func easeIn(_ t: CGFloat) -> CGFloat { t * t }
    private static func easeOut(_ t: CGFloat) -> CGFloat { 1 - (1 - t) * (1 - t) }
    private static func easeInOut(_ t: CGFloat) -> CGFloat { t < 0.5 ? 2 * t * t : 1 - 2 * (1 - t) * (1 - t) }
}

extension View {
    /// Reports the pages' vertical scrolling to `DuoChrome`, on the Duo's cover display only.
    func foldsPlayerBarOnScroll() -> some View {
        modifier(FoldsPlayerBarOnScroll())
    }
}

private struct FoldsPlayerBarOnScroll: ViewModifier {
    @Environment(DuoChrome.self) private var chrome
    @Environment(\.sideInsets) private var sideInsets

    func body(content: Content) -> some View {
        content.onScrollGeometryChange(for: CGFloat.self) { geometry in
            // A page too short to scroll counts as at its top; so does a sideways row.
            guard geometry.contentSize.height > geometry.containerSize.height + 1 else { return 0 }
            return max(geometry.contentOffset.y + geometry.contentInsets.top, 0)
        } action: { _, offset in
            if sideInsets.hasRail { chrome.scrolled(to: offset) }
        }
    }
}

/// What the mini-player folds into: in portrait the cover as a glass circle centred on the side rail, in
/// landscape a small capsule in the pane's foot; and, while it melts, the glass on its way there from the
/// system's capsule. A tap brings the full mini-player back (D78).
///
/// The melt is one piece of glass whose frame, corners and place animate from the accessory's capsule to
/// the circle (the cover moving and growing from its place in the capsule to the circle's middle, the
/// title and buttons fading out early), and back. (A `glassEffectID` morph between two views was tried
/// first: the capsule faded where it was and the circle appeared at the end, `docs/log/C26.md`.) In
/// portrait it goes the water drop's way (`DuoDrop`, C30 bug 19).
struct DuoFoldedPlayerBar: View {
    @Environment(PlayerModel.self) private var player
    @Environment(DuoChrome.self) private var chrome
    @Environment(\.sideInsets) private var sideInsets
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    /// Settings or Add Server is open (C30 bugs 3, 4), or now playing is beside the app (bug 17).
    var isHidden = false

    private var isLandscape: Bool { verticalSizeClass == .compact }

    /// The gap between the circle and the rail's top tab button (C30 bug 20: it was 10, which with the
    /// button's own room above its icon left the cover 31 pt above the first tab's icon, more than the 23 pt
    /// between the tabs' icons). The rail's glass starts 2 pt above its top button (measured on the inner
    /// display), so the circle now stands 4 pt clear of the rail's glass rather than 8.
    static let railGap: CGFloat = 6
    static let circleSize: CGFloat = 56
    private static let artSize: CGFloat = 44
    private static let compactSize = CGSize(width: 240, height: 48)

    /// The side rail's top tab button, in the window (C26, D104: the circle was centred on the whole strip,
    /// 6 pt off the icons). Read from the rail, whichever tabs it has (C30 bug 20).
    @State private var rail: CGRect?

    var body: some View {
        GeometryReader { proxy in
            let window = proxy.size
            ZStack(alignment: .topLeading) {
                Color.clear
                if !isHidden, sideInsets.hasRail, chrome.stage != .none, let song = player.currentSong {
                    if isLandscape {
                        compactGlass(song, window: window)
                    } else {
                        DropGlass(
                            t: chrome.dropProgress,
                            capsule: capsuleFrame(in: window),
                            circle: circleFrame(in: window),
                            coverArt: song.coverArt,
                            artSize: Self.artSize,
                            isFolded: chrome.stage == .folded
                        ) { chrome.unfold() }
                        .transition(.opacity)
                    }
                }
            }
            .frame(width: window.width, height: window.height)
        }
        .ignoresSafeArea()
        .onChange(of: chrome.stage, initial: true) { readRail() }
        .onChange(of: sideInsets) { readRail() }
    }

    private func readRail() {
        guard sideInsets.hasRail, !isLandscape, let frame = UIKitTabBar.railTopButtonFrame() else { return }
        if frame != rail { duoLog.debug("duo rail top at \(String(describing: frame))") }
        rail = frame
    }

    /// The system accessory's capsule, where the copy starts.
    private func capsuleFrame(in window: CGSize) -> CGRect {
        chrome.accessoryFrame.width > 1 ? chrome.accessoryFrame : circleFrame(in: window)
    }

    /// Portrait's circle: centred on the rail, just above its top tab. Until the rail has been read, the
    /// middle of the strip.
    private func circleFrame(in window: CGSize) -> CGRect {
        let size = Self.circleSize
        let centre = if let rail {
            CGPoint(x: rail.midX, y: rail.minY - Self.railGap - size / 2)
        } else {
            CGPoint(x: window.width - sideInsets.trailing / 2, y: window.height / 2)
        }
        return CGRect(x: centre.x - size / 2, y: centre.y - size / 2, width: size, height: size)
    }

    /// Landscape's small capsule in the pane's foot.
    private func compactFrame(in window: CGSize) -> CGRect {
        let pane = window.width - sideInsets.leading - sideInsets.trailing
        let size = Self.compactSize
        return CGRect(
            x: sideInsets.leading + (pane - size.width) / 2,
            y: window.height - 24 - size.height,
            width: size.width,
            height: size.height
        )
    }

    /// Landscape: C26's melt, straight from the capsule to the small capsule and back.
    private func compactGlass(_ song: Song, window: CGSize) -> some View {
        let isFolded = chrome.stage == .folded
        let capsule = chrome.accessoryFrame.width > 1 ? chrome.accessoryFrame : compactFrame(in: window)
        let folded = compactFrame(in: window)
        let frame = isFolded ? folded : capsule
        let radius = frame.height / 2
        return Button {
            chrome.unfold()
        } label: {
            ZStack(alignment: .topLeading) {
                // The full mini-player's title and buttons, at the capsule's size, fading out first.
                if !isFolded {
                    PlayerBar(hidesArt: true) {}
                        .frame(width: capsule.width, height: capsule.height)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .transition(.opacity.animation(.easeOut(duration: 0.12)))
                }
                PlayerBar(forcesInline: true) { chrome.unfold() }
                    .frame(width: folded.width, height: folded.height)
                    .opacity(isFolded ? 1 : 0)
                    .animation(isFolded ? .easeIn(duration: 0.2).delay(0.2) : .easeOut(duration: 0.12), value: isFolded)
                    .accessibilityHidden(!isFolded)
            }
            .frame(width: frame.width, height: frame.height, alignment: .topLeading)
            .clipShape(.rect(cornerRadius: radius))
            .appGlass(in: .rect(cornerRadius: radius), interactive: isFolded)
        }
        .buttonStyle(.plain)
        .disabled(!isFolded)
        .position(x: frame.midX, y: frame.midY)
        .animation(DuoChrome.melt, value: chrome.stage)
        .modifier(FoldedIdentity(isFolded: isFolded, isLandscape: true))
        .transition(.opacity)
    }
}

/// Portrait's glass at a point of the water drop (`DuoDrop`); `t` animates.
private struct DropGlass: View, Animatable {
    var t: CGFloat
    let capsule: CGRect
    let circle: CGRect
    let coverArt: String?
    let artSize: CGFloat
    let isFolded: Bool
    let unfold: () -> Void

    var animatableData: CGFloat {
        get { t }
        set { t = newValue }
    }

    var body: some View {
        let frame = DuoDrop.frame(at: t, capsule: capsule, circle: circle)
        let radius = min(frame.width, frame.height) / 2
        // The cover: from its place in the capsule (36 pt, 10 pt in) to the drop's middle, then with it.
        let art = DuoDrop.artProgress(at: t)
        let artCentre = CGPoint(
            x: DuoDrop.lerp(capsule.minX + 10 + 18, frame.midX, art) - frame.minX,
            y: frame.height / 2
        )
        return Button(action: unfold) {
            ZStack(alignment: .topLeading) {
                // The full mini-player's title and buttons, at the capsule's place, fading out early (and gone
                // from the tree once faded: inside the button's label they'd still be found).
                if DuoDrop.capsuleOpacity(at: t) > 0 {
                    PlayerBar(hidesArt: true) {}
                        .frame(width: capsule.width, height: capsule.height)
                        .offset(x: capsule.minX - frame.minX, y: capsule.minY - frame.minY)
                        .opacity(DuoDrop.capsuleOpacity(at: t))
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                AlbumArtwork(coverArt: coverArt, size: artSize, cornerRadius: 0)
                    .clipShape(.rect(cornerRadius: DuoDrop.lerp(11, artSize / 2, art)))
                    .scaleEffect(DuoDrop.lerp(36 / artSize, 1, art))
                    .position(artCentre)
            }
            .frame(width: frame.width, height: frame.height, alignment: .topLeading)
            .clipShape(.rect(cornerRadius: radius))
            .appGlass(in: .rect(cornerRadius: radius), interactive: isFolded)
        }
        .buttonStyle(.plain)
        .disabled(!isFolded)
        .position(x: frame.midX, y: frame.midY)
        .modifier(FoldedIdentity(isFolded: isFolded, isLandscape: false))
    }
}

/// What the UI tests and VoiceOver find: the circle, or the small capsule (C17).
private struct FoldedIdentity: ViewModifier {
    let isFolded: Bool
    let isLandscape: Bool

    func body(content: Content) -> some View {
        if isLandscape {
            content
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(isFolded ? "duoPlayerBarCompact" : "duoPlayerBarMelting")
        } else {
            content
                .accessibilityLabel("Show Mini-Player")
                .accessibilityIdentifier(isFolded ? "duoPlayerBarCircle" : "duoPlayerBarMelting")
        }
    }
}
