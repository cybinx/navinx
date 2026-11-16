import SwiftUI
import UIKit
import os

private let chromeLog = Logger(subsystem: "com.cybinx.navinx.app", category: "chrome")

// The tab bar comes back at the top of a page (the user's report, 2026-11-07; D80 (3), now fixed).
//
// The system folds the bar when a page scrolls down (`.tabBarMinimizeBehavior(.onScrollDown)`, D74) and
// unfolds it when a fling lands on the top of the page or the circle is tapped. A finger that drags the page
// back to its top and lifts, or pulls past it, leaves the bar folded. There's no call to unfold the bar, and
// flipping the behaviour to `.never` and back (or an animation block, or hiding the bar) unfolds it with
// no animation at all (measured in `docs/log/C15.md`). What does bring the system's own animation is a
// scroll that lands on the top: so when a page arrives at its top, under a finger or with momentum, its
// scroll view is nudged one point down and straight back, which the bar reads as a scroll landing there.
// (Done after the finger lifts, or on a page at rest, it does nothing: the nudge has to be made on arrival.)
// A bar still folded when the finger lifts at the top is flipped open then (C32: the user's slow scroll up).
//
// A quick scroll down and straight back up (C26, D104) reaches the top while the system's fold is still
// running or hasn't started, so the nudge on arrival is spent before the bar is folded. The mini-player
// reports when the bar has folded (its accessory goes inline). When a page comes to rest at its top with
// the bar still folded (a fold that landed after the arrival, or a nudge the system ignored, which a fast
// arrival often gets), the bar's behaviour is flipped off and on, which unfolds it at once (the system
// animates none of it, so the bar is cross-faded; the only call that works on a page at rest).
//
// A nudge the system ignores used to leave the bar folded until the page came to rest, then 310 ms more:
// 0.7 to 0.8 s after the finger lifted, and up to 2.6 s after the page reached its top under a held finger
// (C30 bug 1, measured with the nudge skipped). So 200 ms after a nudge made by momentum, a bar still
// folded on a page still at its top is flipped open there and then (about 210 ms after the arrival). The iOS 27
// `toolbarMinimizationRestoration(.atScrollEdge, for: .tabBar)` was tried first: the tab bar ignores it
// (`docs/log/C30.md`).
//
// All of these pass one gate (C41, D149, `ChromeGate`): once a fold or an unfold has started, none of them
// starts another until it has completed.
//
// C65 (the user's choice, 2026-11-16): an unfold asked while the system's fold was running (the arrival, the
// lift or the fold's own look, all held by the gate) is no longer forced through once the fold has completed.
// The forced pop that followed the fold looked rushed; the bar now stays folded at the top until the next
// touch (a scroll, the circle). A nudge while the page still moves is the system's own unfold and is kept.

extension View {
    /// Unfolds the tab bar when the pages under this view come to rest at their top (after a drag that
    /// stopped there, a pull past it, or a fling).
    func expandsTabBarAtTop() -> some View {
        modifier(ExpandsTabBarAtTop())
    }
}

private struct ExpandsTabBarAtTop: ViewModifier {
    @Environment(DuoChrome.self) private var chrome
    @Environment(\.sideInsets) private var sideInsets

    func body(content: Content) -> some View {
        content.onScrollGeometryChange(for: Bool.self) { geometry in
            // At rest at the top the offset is minus the top inset; a pull past it is further up.
            geometry.contentOffset.y <= -geometry.contentInsets.top + 1
        } action: { wasAtTop, isAtTop in
            if isAtTop != wasAtTop { chromeLog.debug("top \(isAtTop)") }
            guard isAtTop, !wasAtTop else { return }
            // The Duo's side rail never folds, so there's nothing to nudge open; the mini-player's own
            // fold is brought back instead (C17, D78).
            if sideInsets.hasRail {
                chrome.unfold()
            } else {
                UIKitTabBar.expand()
            }
        }
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            // How far past the top (negative), while at it; beyond a point down it doesn't matter.
            min(geometry.contentOffset.y + geometry.contentInsets.top, 2)
        } action: { old, offset in
            // Only on the way up or further past the top: a scroll down from the top (a page pushed onto a
            // folded bar, D80) is no arrival.
            if offset <= 1, offset < old, !sideInsets.hasRail { UIKitTabBar.stillAtTop() }
        }
        // The finger lifting at the top opens a bar still folded there; a scroll that comes to rest at the top
        // with the bar still folded (a fold that landed after the arrival) is opened too (C26).
        .onScrollPhaseChange { old, phase in
            chromeLog.debug("phase \(String(describing: phase))")
            guard !sideInsets.hasRail else { return }
            // A new touch ends a forced unfold's drawn copy at once (the overlay doesn't draw under a finger).
            if phase == .interacting {
                UnfoldFlight.shared.end()
                UIKitTabBar.touched()
            }
            if old == .interacting, phase != .interacting { UIKitTabBar.fingerLifted() }
            // (Only a scroll that came to rest: a page pushed onto a folded bar reports a rest too, and the bar
            // stays folded across a push, D80. C32: it was flipped open 350 ms into the push.)
            if phase == .idle, old == .interacting || old == .decelerating {
                UIKitTabBar.unfoldIfFoldedAtTop(after: .milliseconds(250))
            }
        }
        .foldsPlayerBarOnScroll()
    }
}

/// The tab bar's UIKit side, which SwiftUI's `TabView` is built on.
///
/// C41 (D149): every step here that could start an unfold (the nudge and its repeat, the lift, the confirm
/// step, the retries, the forced opening and its flight) asks `ChromeGate.shared` first, and the system's own
/// fold and unfold close it behind them. While it is closed nothing starts; the ask is kept, and once the
/// animation has completed `look` decides once from where the page, the finger and the bar are then.
@MainActor
enum UIKitTabBar {
    private static var pendingRetry: Task<Void, Never>?
    private static var gate: ChromeGate { .shared }

    /// Nudges the visible page's scroll view as it arrives at its top, which unfolds the tab bar with the
    /// system's own animation. Does nothing for a page that can't scroll.
    static func expand() {
        guard let scroll = pageScrollView() else { return }
        // Only a scroll that arrives (a finger, or the momentum after it) is nudged: a page pushed or shown at
        // its top reports an arrival too, and the bar stays folded across a push (D80).
        let isTracking = scroll.isTracking
        guard isTracking || scroll.isDecelerating else { return }
        chromeLog.debug("arrival nudge\(isTracking ? " under the finger" : "")")
        // A nudge the system ignores: momentum is confirmed a moment later; under a finger, the bar opens as
        // the finger lifts (`fingerLifted`), not under it.
        if sendNudge(scroll), !isTracking { confirmUnfold(scroll) }
    }

    /// A finger still on the page at its top, or pulling past it, with the bar still folded: the nudge again,
    /// at most every 150 ms (the system takes some and lets others go).
    static func stillAtTop() {
        guard isFolded, let scroll = pageScrollView(), scroll.isTracking,
              ContinuousClock.now - lastNudge > .milliseconds(150) else { return }
        if sendNudge(scroll) { chromeLog.debug("nudge again") }
    }

    private static var lastNudge = ContinuousClock.now

    /// The finger left the page at its top, or pulled past it, with the bar still folded (the nudge on arrival
    /// was ignored, or the page was already at its top): it opens now, as the finger lifts (C32). A nudge then
    /// does nothing, from 1, 40 or 120 pt.
    static func fingerLifted() {
        guard isFolded, let scroll = pageScrollView(), isAtTop(scroll) else { return }
        forceOpen(scroll, "lift flip")
    }

    private static var pendingConfirm: Task<Void, Never>?

    /// A nudge the system ignores (a fast arrival often gets one on the phone, C26) leaves the bar folded at
    /// the top until the page comes to rest. So shortly after the nudge, if the bar is still folded and the
    /// page is still at its top, it's flipped open there and then (C30 bug 1).
    private static func confirmUnfold(_ scroll: UIScrollView) {
        pendingConfirm?.cancel()
        pendingConfirm = Task { @MainActor [weak scroll] in
            try? await Task.sleep(for: confirmDelay)
            // Still the visible page: a tab switch or a push meanwhile leaves the bar as it is (D80).
            guard !Task.isCancelled, isFolded, let scroll, scroll === pageScrollView(), isAtTop(scroll) else { return }
            forceOpen(scroll, "confirm flip")
        }
    }

    /// Long enough for the system's own unfold to have begun after a nudge it took (it reports 10 to 60 ms
    /// after the nudge in the simulator).
    private static let confirmDelay: Duration = .milliseconds(200)

    /// The bar folded or unfolded (the mini-player's accessory went inline or back). A fold that lands on a
    /// page already back at its top (a quick scroll down and up) is undone once it has completed.
    static func barFolded(_ isFolded: Bool) {
        let changed = isFolded != self.isFolded
        self.isFolded = isFolded
        chromeLog.debug("bar folded: \(isFolded)")
        // The system's own animation, or the report of one the app began (then the gate is closed for it
        // already): nothing of the app's starts until it has completed.
        if changed, let token = gate.began(isFolded ? .fold : .unfold) { watchSystem(token) }
        if isFolded {
            UnfoldFlight.shared.end()
            // Looked at again once the fold has completed (C26's retry 350 ms after the report, now the gate's).
            if let scroll = pageScrollView() { gate.hold { [weak scroll] in look(scroll) } }
        } else {
            pendingRetry?.cancel()
            staysFolded = nil
        }
    }

    /// The page an unfold asked during a fold was given up on (C65): no forced opening on it until the next
    /// touch, or until the bar unfolds some other way.
    private static weak var staysFolded: UIScrollView?

    /// A finger came down on a page: what C65 gave up on may be asked for again.
    static func touched() {
        staysFolded = nil
    }

    /// Whether the bar is folded, as the mini-player's accessory last reported (false with no song).
    private(set) static var isFolded = false

    /// The accessory was switched off (no song, Settings, the Duo's split): nothing reports the fold until
    /// it's back, when the mini-player reports it again. Until then nothing is retried on a stale fold.
    static func accessoryWent() {
        UnfoldFlight.shared.end()
        guard isFolded else { return }
        chromeLog.debug("accessory off")
        isFolded = false
        staysFolded = nil
        pendingRetry?.cancel()
        pendingConfirm?.cancel()
    }

    /// The minimise behaviour `MainTabView` asks for now, which a flip puts back (C32: not the one it read
    /// before, which the first song or the Duo's rail may have changed meanwhile, and SwiftUI doesn't set
    /// an unchanged value again).
    static var minimizeBehavior: UITabBarController.MinimizeBehavior = .never

    /// After `delay` (a fold still on its way, unreported), if the bar is folded and the visible page is at
    /// rest at its top, flips it open.
    static func unfoldIfFoldedAtTop(after delay: Duration) {
        guard isFolded else { return }
        pendingRetry?.cancel()
        pendingRetry = Task { @MainActor in
            try? await Task.sleep(for: delay)
            let scroll = pageScrollView()
            chromeLog.debug("retry: folded \(isFolded) scroll \(scroll != nil) tracking \(scroll?.isTracking ?? false) decel \(scroll?.isDecelerating ?? false) offset \(scroll.map { $0.contentOffset.y + $0.adjustedContentInset.top } ?? -1)")
            guard !Task.isCancelled, isFolded, let scroll, !scroll.isTracking, !scroll.isDecelerating,
                  isAtTop(scroll) else { return }
            // A nudge now, at rest, does nothing (C15, and again in C26 and C32 from 40 and 120 pt down), so
            // the bar's behaviour is flipped off and back on, which unfolds it at once. (C41: the once-every-2-s
            // limit per page is gone; a second retry for the same settle is held by the gate and then finds the
            // bar open.)
            forceOpen(scroll, "retry flip")
        }
    }

    // MARK: The gate's side (C41)

    /// The gate has opened on an ask made for `asked`: from where things are now, at most one step. A bar still
    /// folded on that page at its top opens: by the nudge while a finger or momentum moves the page (the
    /// system's own animation, momentum confirmed as on arrival), by the forced opening at rest, unless the ask
    /// came while a fold ran (C65: then nothing is forced, at rest or after the nudge). Anything else
    /// (the bar open, the page away from its top, another page or tab, D80) starts nothing.
    private static func look(_ asked: UIScrollView?) {
        guard isFolded, let asked, let scroll = pageScrollView(), scroll === asked, isAtTop(scroll) else {
            chromeLog.debug("look: nothing to start")
            return
        }
        // Asked while the fold ran (C65): the bar isn't forced open now, nor by a retry or confirm step after.
        if gate.isLookingAfterFold {
            chromeLog.debug("look after a fold: no forced opening")
            staysFolded = scroll
        }
        if scroll.isTracking {
            if sendNudge(scroll) { chromeLog.debug("look: nudge") }
        } else if scroll.isDecelerating {
            if sendNudge(scroll) {
                chromeLog.debug("look: nudge")
                confirmUnfold(scroll)
            }
        } else {
            forceOpen(scroll, "look flip")
        }
    }

    /// The nudge, through the gate. With the bar folded it may start the system's unfold, so the gate closes
    /// for it, and opens again at once if the system ignored it. With the bar open (a fold may still be on its
    /// way, unreported) it is sent as before, unless something is running. Returns whether it was sent.
    @discardableResult
    private static func sendNudge(_ scroll: UIScrollView) -> Bool {
        guard isFolded else {
            guard gate.isOpen else { return false }
            nudge(scroll)
            return true
        }
        guard let token = gate.start(.unfold, orLater: { [weak scroll] in look(scroll) }) else {
            chromeLog.debug("nudge held")
            return false
        }
        let sent = ContinuousClock.now
        nudge(scroll)
        Task { @MainActor in
            // The system reports an unfold it takes 10 to 60 ms after the nudge (C26, C32).
            try? await Task.sleep(for: nudgeWindow)
            guard gate.isCurrent(token) else { return }
            if isFolded {
                gate.withdrawn(token)
            } else {
                await waitForAccessoryAtRest(token, since: sent)
                gate.finished(token)
            }
        }
        return true
    }

    private static let nudgeWindow: Duration = .milliseconds(100)

    /// The system's own fold or unfold, reported by the mini-player: the gate opens once the accessory is at
    /// rest (its time limit backs that up).
    private static func watchSystem(_ token: ChromeGate.Token) {
        let start = ContinuousClock.now
        Task { @MainActor in
            await waitForAccessoryAtRest(token, since: start)
            gate.finished(token)
        }
    }

    /// Until the system's animation has run: not before its shortest measured length (0.15 to 0.25 s, D80
    /// (4); the report can come before the animation is on the layers), then until the accessory is drawn
    /// where its frame says. Ends early if the gate is no longer closed for `token`.
    private static func waitForAccessoryAtRest(_ token: ChromeGate.Token, since start: ContinuousClock.Instant) async {
        while gate.isCurrent(token) {
            if ContinuousClock.now - start >= systemAnimation, accessoryIsSettled() { return }
            try? await Task.sleep(for: .milliseconds(16))
        }
    }

    private static let systemAnimation: Duration = .milliseconds(150)

    /// The forced opening, through the gate. A bar that can't minimise (no song, the Duo's rail) has nothing
    /// to unfold; while something runs it is held for the look.
    private static func forceOpen(_ scroll: UIScrollView, _ step: String) {
        guard minimizeBehavior != .never, let tabs = controller else { return }
        guard scroll !== staysFolded else {
            chromeLog.debug("\(step, privacy: .public) skipped: asked during a fold")
            return
        }
        guard let token = gate.start(.unfold, orLater: { [weak scroll] in look(scroll) }) else {
            chromeLog.debug("\(step, privacy: .public) held")
            return
        }
        chromeLog.debug("\(step, privacy: .public)")
        flipMinimizeBehavior(tabs, token)
    }

    private static func isAtTop(_ scroll: UIScrollView) -> Bool {
        scroll.contentOffset.y <= -scroll.adjustedContentInset.top + 1
    }

    /// Unfolds the bar at once: its minimise behaviour off, then back on a moment later (C15's measurement:
    /// anything sooner is merged and does nothing). The system animates none of it, so the bar cross-fades from
    /// folded to open (C32: it jumped in one frame). Completes, for the gate, when the flight ends, or with the
    /// cross-fade when there is no flight. (C41: the one-flip-at-a-time flag is gone; the gate does its job.)
    private static func flipMinimizeBehavior(_ tabs: UITabBarController, _ token: ChromeGate.Token) {
        // The mini-player is drawn flying from its folded place to its open one (`UnfoldFlight`); the bar itself
        // cross-fades under it.
        let folded = isFolded && !UIAccessibility.isReduceMotionEnabled ? accessoryFrame() : nil
        if let folded {
            // However the flight ends (landed, a touch, a push, its limit), that is the opening's completion.
            UnfoldFlight.shared.begin(from: folded, hiding: accessoryHolder(in: tabs)) { gate.finished(token) }
        }
        if let band = barGroup(in: tabs) {
            UIView.transition(with: band, duration: crossFade, options: [.transitionCrossDissolve, .allowUserInteraction]) {
                tabs.tabBarMinimizeBehavior = .never
            }
        } else {
            tabs.tabBarMinimizeBehavior = .never
        }
        // Once UIKit has laid the open bar out (forcing it here left the accessory's layer behind).
        if folded != nil {
            DispatchQueue.main.async { UnfoldFlight.shared.fly(to: accessoryFrame()) }
        } else {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(crossFade))
                gate.finished(token)
            }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(60))
            tabs.tabBarMinimizeBehavior = minimizeBehavior
        }
    }

    private static let crossFade: TimeInterval = 0.2

    /// The view that holds the tab bar and the accessory, and not the page: the nearest one that has both. (A
    /// cross-fade of the whole tab view doubled a page still moving under it.)
    private static func barGroup(in tabs: UITabBarController) -> UIView? {
        guard let accessory = tabs.bottomAccessory?.contentView else { return tabs.tabBar.superview }
        var view: UIView? = tabs.tabBar.superview
        while let candidate = view, candidate !== tabs.view {
            if accessory.isDescendant(of: candidate) { return candidate }
            view = candidate.superview
        }
        return nil
    }

    /// One point down and straight back, with no animation, which the bar reads as a scroll landing on the top
    /// (C32). C15's way back up was animated: under a finger it took the page from it for 0.3 s (the page
    /// stood still, then jumped to the finger) and could read as a scroll down that folded the bar; and the
    /// system ignored it more often (in the simulator, after 2 of 10 quick scrolls and 3 of 4 slow drags that
    /// stopped at the top; this way, with `stillAtTop`, after none of 10 quick ones and none of 12 slow ones).
    private static func nudge(_ scroll: UIScrollView) {
        lastNudge = .now
        let top = -scroll.adjustedContentInset.top
        let x = scroll.contentOffset.x
        // Down from where the page is (a page one point short of its top would otherwise not move down).
        scroll.contentOffset = CGPoint(x: x, y: max(scroll.contentOffset.y, top) + 1)
        scroll.contentOffset = CGPoint(x: x, y: top)
    }

    /// The page's vertical scroll view: the front-most large one in the selected tab.
    private static func pageScrollView() -> UIScrollView? {
        guard let tabs = controller, let root = tabs.selectedViewController?.view else { return nil }
        let screen = root.window?.bounds.size ?? root.bounds.size
        var found: UIScrollView?
        func visit(_ view: UIView) {
            if let scroll = view as? UIScrollView, scroll.window != nil, !scroll.isHidden, scroll.alpha > 0.01,
               // Taller than what shows between its insets (C32: Search's Browse page is shorter than the
               // screen but scrolls under the bars and the keyboard, and folded the bar with no way back).
               scroll.contentSize.height > scroll.bounds.height - scroll.adjustedContentInset.top
                   - scroll.adjustedContentInset.bottom,
               scroll.contentSize.width <= scroll.bounds.width + 1,
               scroll.bounds.width * scroll.bounds.height >= screen.width * screen.height * 0.4 {
                found = scroll
            }
            view.subviews.forEach(visit)
        }
        visit(root)
        return found
    }

    /// Whether a finger is on the visible page's scroll view.
    static var isPageTracking: Bool { pageScrollView()?.isTracking ?? false }

    /// Waits while a finger is on the visible page (at most `limit`): the root view's overlay doesn't draw
    /// while a page's scroll view tracks a finger (measured in C26), so an animation there waits for it.
    static func waitForFingerUp(limit: Duration = .seconds(10)) async {
        let deadline = ContinuousClock.now + limit
        while isPageTracking, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(40))
        }
    }

    /// The tab bar's bottom accessory (the mini-player's capsule) in the window, read now: UIKit moves it
    /// without SwiftUI's geometry hearing of it, so a frame measured earlier can be stale (C26).
    static func accessoryFrame() -> CGRect? {
        guard let tabs = controller, let window = tabs.view.window,
              let view = tabs.bottomAccessory?.contentView, view.window != nil else { return nil }
        let frame = view.convert(view.bounds, to: window)
        return frame.width > 1 ? frame : nil
    }

    /// The view that holds the accessory's glass and content and nothing of the tab bar's (on iOS 27.2 the
    /// accessory's own container, whose one subview is the content): made transparent during a forced
    /// unfold's flight. Nil if the hierarchy isn't that, and then only the content is hidden.
    private static func accessoryHolder(in tabs: UITabBarController) -> UIView? {
        guard let content = tabs.bottomAccessory?.contentView, let holder = content.superview,
              holder.subviews.count == 1, holder !== tabs.view, !tabs.tabBar.isDescendant(of: holder) else { return nil }
        return holder
    }

    /// Whether the accessory is drawn where its frame says: no layer between it and the window is still on its
    /// way (UIKit's own placement can lag its frame after a flip).
    static func accessoryIsSettled() -> Bool {
        guard let view = controller?.bottomAccessory?.contentView, view.window != nil else { return true }
        var layer: CALayer? = view.layer
        while let current = layer {
            if current.animationKeys()?.isEmpty == false { return false }
            if let shown = current.presentation() {
                let moved = abs(shown.position.x - current.position.x) > 0.5 || abs(shown.position.y - current.position.y) > 0.5
                if moved || shown.bounds.size != current.bounds.size { return false }
            }
            layer = current.superlayer
        }
        return true
    }

    /// The side rail's top tab button in the window (the Duo, where the rail stands in the trailing strip):
    /// the topmost of the system's tab buttons in the strip, whichever tabs the rail has (C30 bug 20). The
    /// tab buttons carry their titles only while accessibility is running (a UI test, VoiceOver), so they're
    /// told by their kind: UIKit's tab button control (`_UITabButton` on iOS 27.2), not the toolbar's bar
    /// buttons above it. Hidden ones (the folded layout's Search circle) don't count. Nil if none is laid out.
    static func railTopButtonFrame() -> CGRect? {
        guard let tabs = controller, let window = tabs.view.window else { return nil }
        let strip = window.bounds.width - window.safeAreaInsets.right
        var top: CGRect?
        func visit(_ view: UIView) {
            guard view.window != nil, !view.isHidden, view.alpha > 0.01 else { return }
            if view is UIControl, String(describing: type(of: view)).contains("TabButton") {
                let frame = view.convert(view.bounds, to: window)
                if frame.midX > strip, frame.minY < top?.minY ?? .infinity { top = frame }
                return
            }
            view.subviews.forEach(visit)
        }
        visit(tabs.view)
        return top
    }

    static var controller: UITabBarController? {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        for window in windows {
            if let found = find(in: window.rootViewController) { return found }
        }
        return nil
    }

    private static func find(in controller: UIViewController?) -> UITabBarController? {
        guard let controller else { return nil }
        if let tabs = controller as? UITabBarController { return tabs }
        for child in controller.children {
            if let found = find(in: child) { return found }
        }
        return find(in: controller.presentedViewController)
    }
}

// The tab bar comes back with the finger on a swipe out of Settings (C65, the user's report, 2026-11-16).
//
// Settings and Add Server hide the tab bar (`RouteDestination`, `.toolbarVisibility(.hidden, for: .tabBar)`)
// and the mini-player (`MainTabView`). On an edge swipe back, NavigationStack changes its path, and so the
// bar's visibility, only when the finger lifts: the bar then played its own appear after the page had gone,
// and the mini-player faded in after it. So the page's controller watches its own pop: when a swipe starts
// taking it off the stack onto a page that shows the bar, the bar is shown along with the swipe (it follows
// the finger), and `TabChromeReturn` lets `MainTabView` turn the mini-player back on at once. A swipe let go
// halfway hides both again. (The bar's fold is kept across a hide and a show, C15.) Only on the phone: on the
// Duo's inner display hiding the bar takes away the side rail (D124), and its cover display has the rail.

/// A swipe is taking a page that hides the tab chrome off its stack (C65): the mini-player comes back now,
/// not when the path changes at the swipe's end.
@MainActor @Observable
final class TabChromeReturn {
    static let shared = TabChromeReturn()
    private(set) var isReturning = false

    func began() { isReturning = true }
    /// The swipe was let go, or the path has caught up.
    func ended() { if isReturning { isReturning = false } }
}

extension View {
    /// On a page that hides the tab bar: an edge swipe back to a page that shows it brings the bar and the
    /// mini-player back with the finger (C65).
    func returnsTabChromeOnSwipe(_ isOn: Bool) -> some View {
        background { TabChromeSwipeWatcher(isOn: isOn).frame(width: 0, height: 0) }
    }
}

private struct TabChromeSwipeWatcher: UIViewControllerRepresentable {
    let isOn: Bool
    @Environment(\.sideInsets) private var sideInsets
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    func makeUIViewController(context: Context) -> Watcher { Watcher() }

    func updateUIViewController(_ watcher: Watcher, context: Context) {
        watcher.isOn = isOn && !sideInsets.hasRail && horizontalSizeClass == .compact
    }

    final class Watcher: UIViewController {
        var isOn = false

        override func viewDidLoad() {
            super.viewDidLoad()
            view.isUserInteractionEnabled = false
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            guard isOn, let coordinator = transitionCoordinator, coordinator.isInteractive,
                  let page = coordinator.viewController(forKey: .from), isPopped(page, by: coordinator),
                  let tabs = UIKitTabBar.controller, tabs.isTabBarHidden else { return }
            chromeLog.debug("swipe out: the tab bar follows")
            TabChromeReturn.shared.began()
            coordinator.animate(alongsideTransition: { _ in
                tabs.setTabBarHidden(false, animated: false)
            }, completion: { context in
                guard context.isCancelled else {
                    // `MainTabView` ends it when the path catches up; this only backs that up.
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(600))
                        TabChromeReturn.shared.ended()
                    }
                    return
                }
                // Let go halfway: the page stays, and so does its hidden bar.
                tabs.setTabBarHidden(true, animated: false)
            })
            coordinator.notifyWhenInteractionChanges { context in
                if context.isCancelled {
                    chromeLog.debug("swipe out let go")
                    TabChromeReturn.shared.ended()
                }
            }
        }

        /// Whether this watcher's page is the one leaving its navigation stack (not one covered by a push).
        private func isPopped(_ page: UIViewController, by coordinator: UIViewControllerTransitionCoordinator) -> Bool {
            var ancestor: UIViewController? = self
            while let current = ancestor, current !== page { ancestor = current.parent }
            guard ancestor != nil, let stack = page.navigationController?.viewControllers else { return false }
            guard let from = stack.firstIndex(of: page) else { return true }
            guard let to = coordinator.viewController(forKey: .to), let below = stack.firstIndex(of: to) else { return false }
            return below < from
        }
    }
}
