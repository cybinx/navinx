import CoreGraphics
import Testing
@testable import Navinx

/// The iPhone Duo in C30 (bugs 17 and 18): now playing beside the app on the inner display, and the top
/// bar's corner clearance.
struct DuoSplitTests {
    private let inner = CGSize(width: 951, height: 669)
    private let cover = CGSize(width: 466, height: 678)

    @Test func theInnerDisplaySplitsOpenAndHalfOpen() {
        #expect(DuoSplit.applies(hinge: .fullyOpen, window: inner))
        #expect(DuoSplit.applies(hinge: .partiallyOpen, window: inner))
    }

    @Test func closedOrNoHingeOrANarrowWindowDoesnt() {
        #expect(!DuoSplit.applies(hinge: .closed, window: inner))
        #expect(!DuoSplit.applies(hinge: .none, window: inner))
        // The cover display, either way up, and a phone in landscape.
        #expect(!DuoSplit.applies(hinge: .fullyOpen, window: cover))
        #expect(!DuoSplit.applies(hinge: .fullyOpen, window: CGSize(width: 678, height: 466)))
        #expect(!DuoSplit.applies(hinge: .none, window: CGSize(width: 874, height: 402)))
    }

    @Test func nowPlayingTakesTheHalfRightOfTheHinge() {
        let area = DuoSplit.playerArea(in: inner)
        #expect(area.minX == 476)
        #expect(area.maxX == 951)
        #expect(area.minY == 0)
        #expect(area.height == 669)
    }
}

struct NowPlayingCornersTests {
    @Test func aPhoneKeepsItsMargins() {
        // Portrait: a top inset. Landscape: insets on both sides.
        let portrait = NowPlayingCorners.topBarSides(top: 62, leading: 0, trailing: 0, isLandscape: false)
        #expect(portrait == (18, 18))
        let landscape = NowPlayingCorners.topBarSides(top: 0, leading: 62, trailing: 62, isLandscape: true)
        #expect(landscape == (12, 12))
    }

    @Test func aBareSideWithNoTopInsetClearsTheCorner() {
        // The Duo's cover display: the strip on the trailing side, nothing on top.
        let portrait = NowPlayingCorners.topBarSides(top: 0, leading: 0, trailing: 84, isLandscape: false)
        #expect(portrait == (34, 18))
        let landscape = NowPlayingCorners.topBarSides(top: 0, leading: 84, trailing: 0, isLandscape: true)
        #expect(landscape == (12, 28))
    }

    @Test func theHingeIsNoCorner() {
        let half = NowPlayingCorners.topBarSides(top: 0, leading: 0, trailing: 84, isLandscape: false, leadingIsHinge: true)
        #expect(half == (18, 18))
        let bare = NowPlayingCorners.topBarSides(top: 0, leading: 0, trailing: 0, isLandscape: false, leadingIsHinge: true)
        #expect(bare == (18, 34))
    }
}

/// The mini-player's fold on the cover display (C17, D78): pages scrolled where it's off don't fold it.
@MainActor
struct DuoChromeScrollTests {
    @Test func scrollingWhileTheChromeIsHiddenDoesntFold() {
        let chrome = DuoChrome()
        chrome.ignoresScrolling = true
        chrome.scrolled(to: 0)
        chrome.scrolled(to: 400)
        #expect(!chrome.isFolded)
    }
}
