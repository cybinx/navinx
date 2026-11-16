import CoreGraphics
import Testing
@testable import Navinx

/// The water drop's path on the Duo's rail (C30 bug 19): the mini-player's fold into the circle.
struct DuoDropTests {
    private let capsule = CGRect(x: 16, y: 597, width: 350, height: 48)
    private let circle = CGRect(x: 395, y: 332, width: 56, height: 56)

    @Test func itStartsAsTheCapsuleAndLandsAsTheCircle() {
        #expect(DuoDrop.frame(at: 0, capsule: capsule, circle: circle) == capsule)
        let landed = DuoDrop.frame(at: DuoDrop.landing, capsule: capsule, circle: circle)
        #expect(abs(landed.minX - circle.minX) < 0.01 && abs(landed.minY - circle.minY) < 0.01)
        #expect(abs(landed.width - 56) < 0.01 && abs(landed.height - 56) < 0.01)
        let end = DuoDrop.frame(at: 1, capsule: capsule, circle: circle)
        #expect(abs(end.width - 56) < 0.01 && abs(end.height - 56) < 0.01)
        #expect(abs(end.midY - circle.midY) < 0.01)
    }

    @Test func itRunsRightAlongTheFootThenRisesUpTheStrip() {
        let turn = DuoDrop.frame(at: DuoDrop.turn, capsule: capsule, circle: circle)
        // At the turn: under the circle, still at the capsule's height, wider than tall.
        #expect(abs(turn.midX - circle.midX) < 0.01)
        #expect(turn.midY == capsule.midY)
        #expect(turn.width > turn.height)
        var lastX = capsule.midX
        for step in 1...10 {
            let frame = DuoDrop.frame(at: DuoDrop.turn * CGFloat(step) / 10, capsule: capsule, circle: circle)
            #expect(frame.midY == capsule.midY)
            #expect(frame.midX >= lastX)
            lastX = frame.midX
        }
        var lastY = capsule.midY
        for step in 1...10 {
            let t = DuoDrop.turn + (DuoDrop.landing - DuoDrop.turn) * CGFloat(step) / 10
            let frame = DuoDrop.frame(at: t, capsule: capsule, circle: circle)
            #expect(abs(frame.midX - circle.midX) < 0.01)
            #expect(frame.midY <= lastY)
            lastY = frame.midY
        }
        // Mid-rise it's taller than wide.
        let rising = DuoDrop.frame(at: (DuoDrop.turn + DuoDrop.landing) / 2, capsule: capsule, circle: circle)
        #expect(rising.height > rising.width)
    }

    @Test func itJiggles() {
        let sizes = stride(from: DuoDrop.landing, through: 1, by: 0.01).map {
            DuoDrop.frame(at: $0, capsule: capsule, circle: circle).height
        }
        #expect(sizes.contains { $0 > 58 })
        #expect(sizes.contains { $0 < 54 })
        #expect(sizes.allSatisfy { abs($0 - 56) < 56 * DuoDrop.jiggle })
    }

    @Test func theCapsulesLookGoesEarlyAndTheCoverIsInTheDropByTheTurn() {
        #expect(DuoDrop.capsuleOpacity(at: 0) == 1)
        #expect(DuoDrop.capsuleOpacity(at: DuoDrop.turn) == 0)
        #expect(DuoDrop.artProgress(at: 0) == 0)
        #expect(DuoDrop.artProgress(at: DuoDrop.turn) == 1)
    }

    @Test func theTimingsAddUp() {
        #expect(abs(DuoDrop.foldDuration - 0.9) < 0.001)
        #expect(DuoDrop.turn < DuoDrop.landing && DuoDrop.landing < 1)
    }
}
