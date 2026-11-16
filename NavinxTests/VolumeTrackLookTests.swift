import CoreGraphics
import Testing
import UIKit
@testable import Navinx

/// Now playing's volume slider (C60): where the dressed `MPVolumeView` puts its fill and its knob.
struct VolumeTrackLookTests {
    /// A 274 pt row, with the view reaching past it on both sides and a slider's track kept 3 pt in.
    private let row: CGFloat = 274
    private var track: CGRect {
        let bounds = CGRect(x: 0, y: 0, width: row + 2 * VolumeTrackLook.overhang, height: 30)
        return bounds.insetBy(dx: VolumeTrackLook.trackInset, dy: 12)
    }

    /// The fill's end in the row's own space.
    private func fillInRow(_ value: Float) -> CGFloat {
        VolumeTrackLook.fillEnd(in: track, value: value) - VolumeTrackLook.overhang
    }

    @Test func fillRunsFromTheRowsLeftEdgeToItsRightEdge() {
        #expect(fillInRow(0) == 0)
        #expect(abs(fillInRow(1) - row) < 0.001)
        #expect(abs(fillInRow(0.5) - row / 2) < 0.001)
    }

    @Test func fillOnlyGrowsWithTheVolume() {
        let ends = stride(from: Float(0), through: 1, by: 0.05).map(fillInRow)
        #expect(zip(ends, ends.dropFirst()).allSatisfy { $0 < $1 })
    }

    @Test func oddValuesStayOnTheBar() {
        #expect(fillInRow(-0.5) == 0)
        #expect(abs(fillInRow(1.7) - row) < 0.001)
        #expect(fillInRow(.nan) == 0)
    }

    @Test func knobAlwaysHoldsTheFillsEnd() {
        for value in stride(from: Float(0), through: 1, by: 0.1) {
            let end = VolumeTrackLook.fillEnd(in: track, value: value)
            let knob = VolumeTrackLook.thumbRect(in: track, value: value)
            #expect(knob.contains(CGPoint(x: end, y: track.midY)))
            #expect(abs(knob.midX - end) < 0.001)
            #expect(knob.size == VolumeTrackLook.grabSize)
            // The grab area at the ends stays inside the view, which reaches past the row.
            #expect(knob.minX >= 0)
            #expect(knob.maxX <= row + 2 * VolumeTrackLook.overhang)
        }
    }

    /// The slider is the whole view, so the bar (at rest and pressed) is centred on the row up and down.
    @Test func sliderIsTheWholeViewCentredOnTheRow() {
        let bounds = CGRect(x: 0, y: 0, width: 318, height: 30)
        let rect = VolumeTrackLook.sliderRect(in: bounds)
        #expect(rect == bounds)
        #expect(rect.midY == bounds.midY)
        let knob = VolumeTrackLook.thumbRect(in: rect, value: 0.5)
        #expect(knob.midY == bounds.midY)
    }

    @MainActor @Test func trackImagesAreCapsulesWithTheDragsMargins() {
        for thickness in [VolumeTrackLook.restingThickness, VolumeTrackLook.pressedThickness] {
            let image = VolumeTrackLook.trackImage(thickness: thickness, filled: true)
            #expect(image.size.height == thickness)
            #expect(image.capInsets.left == VolumeTrackLook.dragInset + thickness / 2)
            #expect(image.capInsets.right == VolumeTrackLook.dragInset + thickness / 2)
            #expect(image.capInsets.top == 0)
        }
        #expect(VolumeTrackLook.thumbImage().size == VolumeTrackLook.grabSize)
    }
}
