import SwiftUI

/// Flutter `ThickBarSlider`: the scrubber's thumb-less bar (the volume slider is the system's, C59). 6 pt
/// thick at rest, 12 pt while touched, in a 30 pt touch target. It tracks the finger itself while
/// dragging, so a parent that only acts on release still follows along.
struct BoldTrack: View {
    let value: Double
    let label: String
    var onChanged: (Double) -> Void = { _ in }
    var onEnded: (Double) -> Void = { _ in }
    /// Another gesture took the touch over (the pages' scroll, the page's own drag down), so
    /// `onEnded` never comes. Given the last value dragged to.
    var onCancelled: (Double) -> Void = { _ in }

    @State private var dragValue: Double?
    /// Back to false when the drag ends and also when it's cancelled, which `onEnded` doesn't hear.
    @GestureState private var isTouching = false

    var body: some View {
        GeometryReader { proxy in
            let shown = min(max(dragValue ?? value, 0), 1)
            ZStack(alignment: .leading) {
                Rectangle().fill(.white.opacity(0.3))
                Rectangle().fill(.white).frame(width: proxy.size.width * shown)
            }
            .frame(height: dragValue == nil ? 6 : 12)
            .clipShape(.capsule)
            .animation(dragValue == nil ? .easeInOut(duration: 0.2) : .easeOut(duration: 0.2), value: dragValue == nil)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($isTouching) { _, touching, _ in touching = true }
                    .onChanged { drag in
                        let new = Self.fraction(drag.location.x, width: proxy.size.width)
                        dragValue = new
                        onChanged(new)
                    }
                    .onEnded { drag in
                        dragValue = nil
                        onEnded(Self.fraction(drag.location.x, width: proxy.size.width))
                    }
            )
        }
        .frame(height: 30)
        .onChange(of: isTouching) { _, touching in
            // Ended normally, `onEnded` has already let go of the value.
            guard !touching, let last = dragValue else { return }
            dragValue = nil
            onCancelled(last)
        }
        .accessibilityRepresentation {
            Slider(
                value: Binding(
                    get: { value },
                    set: { new in
                        onChanged(new)
                        onEnded(new)
                    }
                ),
                in: 0...1
            ) {
                Text(label)
            }
        }
    }

    nonisolated static func fraction(_ x: CGFloat, width: CGFloat) -> Double {
        width > 0 ? min(max(x / width, 0), 1) : 0
    }
}
