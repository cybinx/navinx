import CoreGraphics
import Testing
@testable import Navinx

/// Now playing's open and close (C26, D104): the page's and the cover's frames along the way, and when a
/// drag closes it.
@Suite struct NowPlayingMorphTests {
    private let window = CGRect(x: 0, y: 0, width: 402, height: 874)
    private let capsule = CGRect(x: 20, y: 760, width: 362, height: 48)
    private let miniArt = CGRect(x: 30, y: 766, width: 36, height: 36)
    private let cover = CGRect(x: 40, y: 140, width: 322, height: 322)

    @Test func pageGrowsFromTheCapsuleToTheWindow() {
        #expect(NowPlayingMorph.pageFrame(p: 0, drag: 0, capsule: capsule, window: window) == capsule)
        #expect(NowPlayingMorph.pageFrame(p: 1, drag: 0, capsule: capsule, window: window) == window)
        let half = NowPlayingMorph.pageFrame(p: 0.5, drag: 0, capsule: capsule, window: window)
        #expect(half.minY == (capsule.minY + window.minY) / 2)
        #expect(half.width == (capsule.width + window.width) / 2)
    }

    @Test func coverFliesFromTheMiniArt() {
        #expect(NowPlayingMorph.artFrame(p: 0, drag: 0, miniArt: miniArt, cover: cover, window: window) == miniArt)
        #expect(NowPlayingMorph.artFrame(p: 1, drag: 0, miniArt: miniArt, cover: cover, window: window) == cover)
    }

    /// Dragged, the open page moves down 1:1 and shrinks, at most to 0.94 (at half the height).
    @Test func dragMovesAndShrinks() {
        let dragged = NowPlayingMorph.pageFrame(p: 1, drag: 100, capsule: capsule, window: window)
        #expect(dragged.width < window.width)
        #expect(abs(dragged.midY - (window.midY + 100)) < 0.001)
        #expect(NowPlayingMorph.scale(forDrag: 0, height: 874) == 1)
        #expect(abs(NowPlayingMorph.scale(forDrag: 437, height: 874) - 0.94) < 0.0001)
        #expect(abs(NowPlayingMorph.scale(forDrag: 2000, height: 874) - 0.94) < 0.0001)
    }

    /// Apple Music's: past a third of the height, or flicked faster than 800 pt/s.
    @Test func whenADragCloses() {
        #expect(!NowPlayingMorph.closes(drag: 200, velocity: 300, height: 874))
        #expect(NowPlayingMorph.closes(drag: 300, velocity: 0, height: 874))
        #expect(NowPlayingMorph.closes(drag: 60, velocity: 900, height: 874))
    }

    @Test func cornersRoundOnTheWayAndNotAtRest() {
        #expect(NowPlayingMorph.cornerRadius(p: 0, drag: 0, capsule: capsule) == 24)
        #expect(NowPlayingMorph.cornerRadius(p: 1, drag: 0, capsule: capsule) == 0)
        #expect(NowPlayingMorph.cornerRadius(p: 1, drag: 200, capsule: capsule) == NowPlayingMorph.displayCornerRadius)
        #expect(NowPlayingMorph.ramp(0.2, from: 0.3, to: 1) == 0)
        #expect(NowPlayingMorph.ramp(1, from: 0.3, to: 1) == 1)
    }
}
