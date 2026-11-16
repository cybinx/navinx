import SubsonicKit
import CoreFoundation
import CoreGraphics
import Testing
@testable import Navinx

struct NowPlayingLogicTests {
    // MARK: Times

    @Test func timesHaveTwoDigitMinutesUntilAnHour() {
        #expect(PlayerTime.format(0) == "00:00")
        #expect(PlayerTime.format(65.9) == "01:05")
        #expect(PlayerTime.format(3599) == "59:59")
        #expect(PlayerTime.format(3723) == "1:02:03")
    }

    @Test func oddTimesShowAsZero() {
        #expect(PlayerTime.format(-4) == "00:00")
        #expect(PlayerTime.format(.nan) == "00:00")
        #expect(PlayerTime.format(.infinity) == "00:00")
    }

    @Test func remainingTimeNeverGoesPastZero() {
        #expect(PlayerTime.remaining(position: 30, duration: 90) == "-01:00")
        #expect(PlayerTime.remaining(position: 95, duration: 90) == "-00:00")
    }

    // MARK: The scrubber's drag

    @Test func aDragShowsTheFingerAndSeeksWhereItLifts() {
        var drag = ScrubDrag()
        drag.move(to: 40, song: "a")
        #expect(drag.position == 40)
        #expect(drag.end(at: 55, song: "a") == 55)
        #expect(drag == ScrubDrag())
    }

    @Test func aDragHeldIntoTheNextSongSeeksNothing() {
        var drag = ScrubDrag()
        drag.move(to: 40, song: "a")
        drag.songChanged()
        drag.move(to: 50, song: "b")
        #expect(drag.position == nil)
        #expect(drag.end(at: 50, song: "b") == nil)
    }

    /// Re-check item 3 (2026-11-15): a touch the page's swipe took over left the bar and times frozen,
    /// and the next song's first drag neither followed nor sought.
    @Test func aCancelledDragLetsGoWithoutSeekingAndTheNextDragWorks() {
        var drag = ScrubDrag()
        drag.move(to: 40, song: "a")
        drag.cancel()
        #expect(drag.position == nil && !drag.isDragging)
        drag.move(to: 70, song: "b")
        #expect(drag.position == 70)
        #expect(drag.end(at: 75, song: "b") == 75)
    }

    // MARK: Layout

    @Test func aTallPhoneGetsTheFullSpacing() {
        let metrics = NowPlayingMetrics(width: 402, height: 900, top: 62, bottom: 34)
        #expect(!metrics.isSmall)
        #expect(metrics.topBarGap == 52)
        #expect(metrics.artHorizontal == 32)
        #expect(metrics.artVertical == 8)
        #expect(metrics.titleVertical == 10)
        #expect(metrics.sliderBottom == 14)
        #expect(metrics.controlsBottom == 18)
        #expect(metrics.bottomActions == 4)
    }

    @Test func aShortScreenTightensUp() {
        let small = NowPlayingMetrics(width: 375, height: 667, top: 20, bottom: 0)
        #expect(small.isSmall)
        #expect(!small.isTinyScreen)
        #expect(small.topBarGap == 46)
        #expect(small.artVertical == 4)
        #expect(small.sliderBottom == 4)
        #expect(small.controlsBottom == 6)
        #expect(small.bottomActions == 6)

        let verySmall = NowPlayingMetrics(width: 320, height: 568, top: 0, bottom: 0)
        #expect(verySmall.isTinyScreen)
        // No top inset: the buttons end 60 pt down, so the artwork's space starts at 68 (C17).
        #expect(verySmall.topBarGap + verySmall.artVertical == 68)
        #expect(verySmall.artHorizontal == 24)
        #expect(verySmall.artVertical == 2)
        #expect(verySmall.controlsBottom == 4)
        #expect(verySmall.titleVertical == 4)
    }

    @Test func theDuosCoverDisplayKeepsTheCoverClearOfTheTopButtons() {
        // 466 x 678 with no top inset: the buttons span y 22 to 60, the cover starts 8 pt under them.
        let duo = NowPlayingMetrics(width: 466, height: 678, top: 0, bottom: 34)
        #expect(duo.isSmall)
        #expect(duo.topBarGap + duo.artVertical >= 68)
    }

    @Test func aWideScreenKeepsTheCoverAt380() {
        #expect(NowPlayingMetrics(width: 699, height: 1017, top: 0, bottom: 0).artHorizontal == 120)
        #expect(NowPlayingMetrics(width: 500, height: 1017, top: 0, bottom: 0).artHorizontal == 60)
        #expect(NowPlayingMetrics(width: 481, height: 1017, top: 0, bottom: 0).artHorizontal == 50.5)
    }

    // MARK: Backdrop brightness

    private func pixels(_ colors: [(count: Int, red: UInt8, green: UInt8, blue: UInt8)]) -> [UInt8] {
        colors.flatMap { color in
            Array(repeating: [color.red, color.green, color.blue, 255], count: color.count).flatMap { $0 }
        }
    }

    @Test func aBlackCoverIsDarkAndAWhiteCoverBright() throws {
        let black = try #require(CoverLuminance.estimate(rgba: pixels([(100, 0, 0, 0)])))
        let white = try #require(CoverLuminance.estimate(rgba: pixels([(100, 255, 255, 255)])))
        #expect(black < 0.001)
        #expect(white > 0.99)
    }

    @Test func noPixelsGiveNoEstimate() {
        #expect(CoverLuminance.estimate(rgba: []) == nil)
    }

    @Test func aSmallBrightAreaStillPullsTheEstimateUp() throws {
        // A sun: 5 % white on black, so 0.4 of the brightest colour counts.
        let sun = try #require(CoverLuminance.estimate(rgba: pixels([(95, 0, 0, 0), (5, 255, 255, 255)])))
        #expect(abs(sun - 0.4) < 0.01)
    }

    @Test func specksTooSmallToBeAColourDontCount() throws {
        let specks = try #require(CoverLuminance.estimate(rgba: pixels([(199, 0, 0, 0), (1, 255, 255, 255)])))
        #expect(specks < 0.001)
    }

    @Test func theScrimFollowsFlutterAndStaysInRange() {
        let dark = CoverLuminance.scrim(brightness: 0)
        #expect(dark.top == 0.30)
        #expect(dark.middle == 0.22)
        #expect(dark.bottom == 0.58)
        let bright = CoverLuminance.scrim(brightness: 5)
        #expect(abs(bright.top - 0.55) < 0.0001)
        #expect(abs(bright.middle - 0.58) < 0.0001)
        #expect(abs(bright.bottom - 0.82) < 0.0001)
    }

    // MARK: The bar

    @Test func theBarReadsTheFingersPlaceWithinItself() {
        #expect(BoldTrack.fraction(50, width: 200) == 0.25)
        #expect(BoldTrack.fraction(-10, width: 200) == 0)
        #expect(BoldTrack.fraction(500, width: 200) == 1)
        #expect(BoldTrack.fraction(10, width: 0) == 0)
    }
}

@Suite struct PlaylistMembershipTests {
    @Test func theSameIDIsOnIt() {
        let song = Song(id: "1", title: "A")
        #expect(PlaylistMembership.contains(song, in: [Song(id: "1", title: "Different")]))
    }

    @Test func theSameTitleAndArtistIsOnIt() {
        let song = Song(id: "1", title: " Song ", artist: "Someone")
        #expect(PlaylistMembership.contains(song, in: [Song(id: "2", title: "song", artist: " SOMEONE ")]))
    }

    @Test func anotherArtistIsNot() {
        let song = Song(id: "1", title: "Song", artist: "Someone")
        #expect(!PlaylistMembership.contains(song, in: [Song(id: "2", title: "Song", artist: "Else")]))
        #expect(!PlaylistMembership.contains(song, in: []))
    }

    @Test func countsReadAsInFlutter() {
        #expect(PlaylistMembership.countText(nil) == "No songs")
        #expect(PlaylistMembership.countText(0) == "No songs")
        #expect(PlaylistMembership.countText(1) == "1 song")
        #expect(PlaylistMembership.countText(12) == "12 songs")
    }
}
