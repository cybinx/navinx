import CoreFoundation
import CoreGraphics
import SubsonicKit
import Testing
import UIKit
@testable import Navinx

/// C30 bugs 3 and 4: Settings and Add Server, and the pages above them, have neither the tab bar nor the
/// mini-player; the pages under them keep both.
@MainActor struct TabChromeTests {
    private let album = LibraryRoute.album(Album(id: "a", name: "A"))

    @Test func settingsAndAddServerHideTheChrome() {
        #expect(LibraryRoute.settings.hidesTabChrome)
        #expect(LibraryRoute.addServer.hidesTabChrome)
        #expect(!album.hidesTabChrome)
        #expect(!LibraryRoute.playlistDownloads.hidesTabChrome)
    }

    @Test func aStackHidesItWhileEitherIsOnIt() {
        #expect(![LibraryRoute]().hidesTabChrome)
        #expect(![album, .favorites].hidesTabChrome)
        #expect([.settings].hidesTabChrome)
        #expect([.settings, .addServer].hidesTabChrome)
        #expect([album, .addServer].hidesTabChrome)
    }

    @Test func pagesAboveSettingsHideItAndPagesUnderItDont() {
        let path: [LibraryRoute] = [album, .settings, .playlistDownloads]
        #expect(!path.hidesTabChrome(at: album))
        #expect(path.hidesTabChrome(at: .settings))
        #expect(path.hidesTabChrome(at: .playlistDownloads))
        // A page no longer on the stack (on its way out) answers by itself and the stack.
        #expect([album].hidesTabChrome(at: .settings))
        #expect(![album].hidesTabChrome(at: .favorites))
    }

    /// C65: a swipe out of Settings brings the bar back only onto a page that shows it.
    @Test func whetherThePageUnderOneHidesIt() {
        let path: [LibraryRoute] = [album, .settings, .playlistDownloads]
        #expect(!path.hidesTabChrome(below: .settings))
        #expect(path.hidesTabChrome(below: .playlistDownloads))
        #expect(![LibraryRoute.settings].hidesTabChrome(below: .settings))
    }
}

/// C32: the forced unfold's drawn copy of the mini-player, and the real one's content hidden meanwhile.
@MainActor struct UnfoldFlightTests {
    private let folded = CGRect(x: 90, y: 798, width: 222, height: 48)
    private let open = CGRect(x: 21, y: 735, width: 360, height: 48)

    @Test func theCopyWaitsOverTheFoldedPlaceThenFlies() {
        let flight = UnfoldFlight()
        #expect(!flight.hidesRealContent)
        #expect(flight.frames == nil)
        flight.begin(from: folded)
        #expect(flight.hidesRealContent)
        #expect(flight.frames?.from == folded)
        #expect(flight.frames?.to == folded)
        flight.fly(to: open)
        #expect(flight.frames?.from == folded)
        #expect(flight.frames?.to == open)
        flight.end()
        #expect(!flight.hidesRealContent)
        #expect(flight.frames == nil)
    }

    @Test func noOpenPlaceEndsItAtOnce() {
        let flight = UnfoldFlight()
        flight.begin(from: folded)
        flight.fly(to: nil)
        #expect(!flight.hidesRealContent)
        flight.begin(from: folded)
        flight.fly(to: folded)
        #expect(!flight.hidesRealContent)
    }

    /// Waits for the flight's own end (`onEnd`), not a fixed time: under a full suite the main actor can run
    /// the limit's step late. Ending only after the limit shows it was the limit that ended it.
    @Test(.timeLimit(.minutes(1))) func aFlightThatNeverFliesEndsByItsTimeLimit() async {
        let flight = UnfoldFlight()
        let accessory = UIView()
        let clock = ContinuousClock()
        let started = clock.now
        await withCheckedContinuation { (ended: CheckedContinuation<Void, Never>) in
            flight.begin(from: folded, hiding: accessory) { ended.resume() }
        }
        #expect(clock.now - started >= UnfoldFlight.timeLimit)
        #expect(!flight.hidesRealContent)
        // The real accessory is never left invisible.
        #expect(accessory.alpha == 1)
    }

    @Test func theRealAccessoryIsHiddenOnlyWhileTheCopyIsUp() {
        let flight = UnfoldFlight()
        let accessory = UIView()
        flight.begin(from: folded, hiding: accessory)
        #expect(accessory.alpha == 0)
        flight.fly(to: open)
        #expect(accessory.alpha == 0)
        flight.end()
        #expect(accessory.alpha == 1)
        // A second flight begun over the first puts the first one's accessory back.
        let rebuilt = UIView()
        flight.begin(from: folded, hiding: accessory)
        flight.begin(from: folded, hiding: rebuilt)
        #expect(accessory.alpha == 1)
        #expect(rebuilt.alpha == 0)
        flight.fly(to: nil)
        #expect(rebuilt.alpha == 1)
    }
}

/// C30 bug 13: a swipe on the mini-player, left for Next and right for Previous.
struct PlayerBarSwipeTests {
    @Test func farEnoughOrFastEnoughSkips() {
        #expect(PlayerBar.skipDirection(translation: -60, velocity: 0) == -1)
        #expect(PlayerBar.skipDirection(translation: 60, velocity: 0) == 1)
        #expect(PlayerBar.skipDirection(translation: -20, velocity: -800) == -1)
        #expect(PlayerBar.skipDirection(translation: 20, velocity: 800) == 1)
    }

    @Test func aShortSlowOrReversedSwipeGoesBack() {
        #expect(PlayerBar.skipDirection(translation: -30, velocity: -100) == 0)
        #expect(PlayerBar.skipDirection(translation: 30, velocity: 100) == 0)
        // Flung back the other way at the end: it settles, it doesn't skip the other way.
        #expect(PlayerBar.skipDirection(translation: -30, velocity: 900) == 0)
        #expect(PlayerBar.skipDirection(translation: 0, velocity: 0) == 0)
    }
}
