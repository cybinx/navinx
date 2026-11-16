import Testing
@testable import Navinx

/// A clock the tests move by hand: what the gate schedules runs only when `advance` passes its time.
@MainActor
final class GateTestClock {
    private(set) var now: Duration = .zero
    private var pending: [(at: Duration, order: Int, action: @MainActor () -> Void)] = []
    private var count = 0

    func schedule(_ delay: Duration, _ action: @escaping @MainActor () -> Void) {
        count += 1
        pending.append((now + delay, count, action))
    }

    func advance(by delay: Duration) {
        let end = now + delay
        while let next = pending.filter({ $0.at <= end }).min(by: { ($0.at, $0.order) < ($1.at, $1.order) }) {
            pending.removeAll { $0.order == next.order }
            now = next.at
            next.action()
        }
        now = end
    }
}

/// C41 (D149): once a fold or an unfold has started, no other starts until it has completed; what was asked
/// meanwhile is kept (the newest only) and looked at once when the gate opens.
@MainActor struct ChromeGateTests {
    private let clock = GateTestClock()
    private var gate: ChromeGate { ChromeGate(after: clock.schedule) }

    @Test func anAskWhileBusyStartsNothing() {
        let gate = gate
        var looks = 0
        let token = gate.start(.unfold) { looks += 1 }
        #expect(token != nil)
        #expect(gate.state == .busy(.unfold))
        #expect(gate.start(.fold) { looks += 1 } == nil)
        #expect(gate.start(.unfold) { looks += 1 } == nil)
        #expect(gate.holdsAsk)
        clock.advance(by: .milliseconds(800))
        #expect(looks == 0)
        #expect(!gate.isOpen)
    }

    @Test func itOpensAtCompletionAfterTheSettleTimeAndLooksOnceWithTheNewestAsk() {
        let gate = gate
        var looked: [String] = []
        let token = gate.start(.unfold) { looked.append("first") }!
        clock.advance(by: .milliseconds(250))
        _ = gate.start(.fold) { looked.append("older") }
        _ = gate.start(.unfold) { looked.append("newest") }
        gate.finished(token)
        #expect(gate.state == .settling(.unfold))
        // Still closed while it settles: a further ask is kept, replacing the one before.
        #expect(gate.start(.fold) { looked.append("newer still") } == nil)
        clock.advance(by: ChromeGate.settleTime - .milliseconds(1))
        #expect(!gate.isOpen)
        #expect(looked.isEmpty)
        clock.advance(by: .milliseconds(1))
        #expect(gate.isOpen)
        #expect(looked == ["newer still"])
        // Nothing is replayed after that.
        clock.advance(by: .seconds(5))
        #expect(looked == ["newer still"])
    }

    @Test func itOpensAtTheTimeLimitWhenTheCompletionNeverComes() {
        let gate = gate
        var looks = 0
        _ = gate.start(.fold) { }
        gate.hold { looks += 1 }
        clock.advance(by: ChromeGate.timeLimit - .milliseconds(1))
        #expect(!gate.isOpen)
        #expect(looks == 0)
        clock.advance(by: .milliseconds(1))
        #expect(gate.isOpen)
        #expect(looks == 1)
    }

    @Test func theLookStartsAtMostOneAnimation() {
        let gate = gate
        var started: [ChromeGate.Token] = []
        var refused = 0
        let token = gate.start(.fold) { }!
        gate.hold {
            // What the look finds calls for an unfold; a second start from the same look is refused.
            if let next = gate.start(.unfold, orLater: { }) { started.append(next) }
            if gate.start(.unfold, orLater: { }) == nil { refused += 1 }
        }
        gate.finished(token)
        clock.advance(by: ChromeGate.settleTime)
        #expect(started.count == 1)
        #expect(refused == 1)
        #expect(gate.state == .busy(.unfold))
    }

    @Test func aLookThatFindsNothingToDoStartsNothing() {
        let gate = gate
        let token = gate.start(.unfold) { }!
        var looks = 0
        gate.hold { looks += 1 }
        gate.finished(token)
        clock.advance(by: ChromeGate.settleTime)
        #expect(looks == 1)
        #expect(gate.isOpen)
        // With nothing asked, opening looks at nothing.
        let next = gate.start(.fold) { }!
        gate.finished(next)
        clock.advance(by: ChromeGate.settleTime)
        #expect(looks == 1)
        #expect(gate.isOpen)
    }

    @Test func theSystemsOwnAnimationClosesItBehindIt() {
        let gate = gate
        // The system's fold, while open: closed.
        let fold = gate.began(.fold)
        #expect(fold != nil)
        #expect(gate.state == .busy(.fold))
        #expect(gate.start(.unfold) { } == nil)
        // The system's unfold under it (it can't be held): it replaces the fold, whose completion then opens nothing.
        let unfold = gate.began(.unfold)
        #expect(unfold != nil)
        // The report of an unfold the gate is already closed for is the same animation.
        #expect(gate.began(.unfold) == nil)
        gate.finished(fold!)
        clock.advance(by: ChromeGate.settleTime)
        #expect(gate.state == .busy(.unfold))
        gate.finished(unfold!)
        clock.advance(by: ChromeGate.settleTime)
        #expect(gate.isOpen)
    }

    @Test func aNudgeTheSystemIgnoredOpensItAtOnce() {
        let gate = gate
        var looks = 0
        let nudge = gate.start(.unfold) { }!
        gate.hold { looks += 1 }
        gate.withdrawn(nudge)
        #expect(gate.isOpen)
        #expect(looks == 1)
    }

    @Test func anOlderAnimationsStepsDontOpenANewerOne() {
        let gate = gate
        let first = gate.start(.unfold) { }!
        gate.finished(first)
        clock.advance(by: ChromeGate.settleTime)
        clock.advance(by: .milliseconds(100))
        let second = gate.start(.fold) { }!
        // The first one's time limit passes: the second stays closed.
        clock.advance(by: ChromeGate.timeLimit - .milliseconds(150))
        #expect(gate.state == .busy(.fold))
        // A late completion or withdrawal of the first does nothing.
        gate.finished(first)
        gate.withdrawn(first)
        #expect(gate.state == .busy(.fold))
        #expect(gate.isCurrent(second))
        #expect(!gate.isCurrent(first))
        // Its own limit opens it.
        clock.advance(by: .milliseconds(150))
        #expect(gate.isOpen)
    }

    /// C65: a look kept while a fold ran or settled knows it, so the phone doesn't force the bar open after
    /// the fold; one kept during an unfold, or run with the gate open, doesn't.
    @Test func aLookAskedDuringAFoldKnowsIt() {
        let gate = gate
        var seen: [Bool] = []
        // The system's fold, with the arrival's ask held under it.
        let fold = gate.began(.fold)!
        _ = gate.start(.unfold) { seen.append(gate.isLookingAfterFold) }
        gate.finished(fold)
        clock.advance(by: ChromeGate.settleTime)
        #expect(seen == [true])
        #expect(!gate.isLookingAfterFold)
        // Asked only while the fold settled: the same.
        let second = gate.began(.fold)!
        gate.finished(second)
        gate.hold { seen.append(gate.isLookingAfterFold) }
        clock.advance(by: ChromeGate.settleTime)
        #expect(seen == [true, true])
        // During an unfold, or with the gate open: not after a fold.
        let unfold = gate.start(.unfold) { }!
        gate.hold { seen.append(gate.isLookingAfterFold) }
        gate.finished(unfold)
        clock.advance(by: ChromeGate.settleTime)
        gate.hold { seen.append(gate.isLookingAfterFold) }
        #expect(seen == [true, true, false, false])
        // A reset forgets it.
        _ = gate.began(.fold)
        gate.hold { seen.append(gate.isLookingAfterFold) }
        gate.reset()
        let later = gate.start(.unfold) { }!
        gate.hold { seen.append(gate.isLookingAfterFold) }
        gate.finished(later)
        clock.advance(by: ChromeGate.settleTime)
        #expect(seen == [true, true, false, false, false])
    }

    @Test func aResetOpensItAndDropsTheAsk() {
        let gate = gate
        var looks = 0
        _ = gate.start(.fold) { }
        gate.hold { looks += 1 }
        gate.reset()
        #expect(gate.isOpen)
        clock.advance(by: .seconds(3))
        #expect(looks == 0)
    }

    @Test func theDuosFoldWaitsForTheGateThenGoesWhereThePageSays() async {
        let gate = gate
        let chrome = DuoChrome(gate: gate)
        // Something else is running.
        let other = gate.start(.unfold) { }!
        chrome.fold()
        // (Past the wait for a finger, which has none to wait for here.)
        for _ in 0..<5 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(!chrome.isFolded)
        #expect(gate.holdsAsk)
        // Asked to fold, then back up, then down again: only where the page is now counts.
        chrome.unfold()
        chrome.fold()
        gate.finished(other)
        clock.advance(by: ChromeGate.settleTime)
        #expect(chrome.isFolded)
        #expect(gate.state == .busy(.fold))
    }
}
