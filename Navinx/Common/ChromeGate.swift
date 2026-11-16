import os

private let chromeLog = Logger(subsystem: "com.cybinx.navinx.app", category: "chrome")

// The mini-player's gate (C41, D149, the user's design: "after the fix the animation cannot be ran until it
// has already completed").
//
// Once a fold or an unfold of the mini-player has started, whoever started it, no other may start until it
// has completed and a short settle time has passed. What is asked for meanwhile isn't queued: the gate keeps
// only that something was asked (the newest ask's look), and when it opens that look runs once, deciding
// from where the page, the finger and the bar are then; it starts at most one animation. A time limit opens
// a gate whose completion never arrives, so the bar can't be left stuck.
//
// C65 (the user's choice, 2026-11-16): a look kept while a fold ran knows it (`isLookingAfterFold`), and the
// phone's then doesn't force the bar open: the pop that followed a fold looked rushed.
//
// The phone's steps (`UIKitTabBar`: the nudge, its repeat, the lift, the confirm step, the retries, the forced
// opening and its flight) and the Duo's own fold (`DuoChrome`) all pass through `ChromeGate.shared`. The
// system's own fold and unfold can't be held: the gate only closes behind them (`began`), so nothing of the
// app's starts under them. No UIKit in here, and the time comes from `after`, so it is unit-tested on a test
// clock (`ChromeGateTests`).

@MainActor
final class ChromeGate {
    enum Kind: Equatable, CustomStringConvertible {
        case fold, unfold
        var description: String { self == .fold ? "fold" : "unfold" }
    }

    enum State: Equatable {
        case idle
        /// An animation is running.
        case busy(Kind)
        /// It has completed; the gate opens after the settle time.
        case settling(Kind)
    }

    /// Stands for one animation: only its own completion opens the gate.
    struct Token: Equatable {
        fileprivate let number: Int
    }

    typealias Schedule = @MainActor (Duration, @escaping @MainActor () -> Void) -> Void

    static let shared = ChromeGate()

    /// After a completion, before the gate opens (the layers' last frame drawn).
    static let settleTime: Duration = .milliseconds(100)
    /// The longest the gate stays closed: above the longest animation the app starts (the Duo's fold, about
    /// 1.15 s) and the forced opening's own 1.2 s limit, so it only fires when a completion went missing.
    static let timeLimit: Duration = .milliseconds(1500)

    private(set) var state = State.idle
    private var current = 0
    /// The newest ask's look, kept while the gate is closed (one, never a list).
    private var held: (@MainActor () -> Void)?
    /// Something was asked while a fold ran or settled (C65).
    private var heldThroughFold = false
    /// While a kept look runs: whether it was asked while a fold ran (C65, the user's choice: an unfold asked
    /// during a fold isn't forced through once the fold has completed; the bar stays folded until the next
    /// touch). False at any other time.
    private(set) var isLookingAfterFold = false
    private let after: Schedule

    init(after: @escaping Schedule = ChromeGate.sleep) {
        self.after = after
    }

    var isOpen: Bool { state == .idle }
    /// Whether something was asked while the gate is closed.
    var holdsAsk: Bool { held != nil }

    /// Whether `token` is the animation the gate is closed for (a step of an older one does nothing more).
    func isCurrent(_ token: Token) -> Bool {
        token.number == current && state != .idle
    }

    /// An animation the app wants to start. Open: the gate closes and gives its token, and the caller starts
    /// it. Closed: nothing starts, and `look` is kept (replacing any kept before) to run once when it opens.
    func start(_ kind: Kind, orLater look: @escaping @MainActor () -> Void) -> Token? {
        guard isOpen else {
            hold(look)
            return nil
        }
        return close(kind)
    }

    /// Something was asked that only a later look can answer: runs `look` now if the gate is open, else
    /// keeps it for when it opens.
    func hold(_ look: @escaping @MainActor () -> Void) {
        guard !isOpen else {
            look()
            return
        }
        chromeLog.debug("gate held")
        if state == .busy(.fold) || state == .settling(.fold) { heldThroughFold = true }
        held = look
    }

    /// An animation the app didn't start and can't hold (the system's own fold or unfold) is running: the
    /// gate closes behind it. Nil if the gate is already closed for that same animation (the report of an
    /// unfold the app itself began); an animation of the other kind replaces the one the gate was closed for.
    @discardableResult
    func began(_ kind: Kind) -> Token? {
        if state == .busy(kind) { return nil }
        return close(kind)
    }

    /// The animation has completed: the gate opens after the settle time.
    func finished(_ token: Token) {
        guard isCurrent(token), case .busy(let kind) = state else { return }
        state = .settling(kind)
        after(Self.settleTime) { [weak self] in
            guard let self, self.current == token.number, self.state == .settling(kind) else { return }
            self.open()
        }
    }

    /// What `token` stood for moved nothing after all (a nudge the system ignored): the gate opens at once.
    func withdrawn(_ token: Token) {
        guard isCurrent(token) else { return }
        open()
    }

    /// Open, with nothing kept (the Duo's display changed: every step under way was dropped).
    func reset() {
        current += 1
        held = nil
        heldThroughFold = false
        state = .idle
    }

    private func close(_ kind: Kind) -> Token {
        current += 1
        let number = current
        state = .busy(kind)
        chromeLog.debug("gate closed: \(kind)")
        after(Self.timeLimit) { [weak self] in
            guard let self, self.current == number, self.state != .idle else { return }
            chromeLog.debug("gate time limit")
            self.open()
        }
        return Token(number: number)
    }

    private func open() {
        state = .idle
        chromeLog.debug("gate open\(self.held != nil ? ", looking again" : "")")
        let look = held
        let afterFold = heldThroughFold
        held = nil
        heldThroughFold = false
        isLookingAfterFold = afterFold && look != nil
        look?()
        isLookingAfterFold = false
    }

    private static func sleep(_ delay: Duration, _ action: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(for: delay)
            action()
        }
    }
}
