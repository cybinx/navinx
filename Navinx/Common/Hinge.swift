import SwiftUI
import UIKit

// The iPhone Duo's hinge (C17, D79). UIKit says how far the Duo is open with a `UIHingeInteraction`
// (iOS 27.1): closed (the cover display), partially open, or fully open (the inner display). A phone
// gives no hinge, so its posture stays `.none`. Open or half open, now playing takes the half right of the
// hinge on the inner display and the app keeps the other (`DuoSplit`, C30 bug 17); half open looks as open
// does.
//
// In DEBUG, `-UITestHinge closed|partial|open` fakes the posture (the simulator's posture can only be
// changed with DeviceHub's buttons, which nothing here can press).

nonisolated enum HingePosture: Equatable, Sendable {
    /// No hinge (a phone), or none reported yet.
    case none
    case closed
    case partiallyOpen
    case fullyOpen
}

extension EnvironmentValues {
    @Entry var hingePosture = HingePosture.none
}

extension View {
    /// Reads the hinge for everything below, and keeps the posture in `posture` for the view that owns it.
    func readsHinge(_ posture: Binding<HingePosture>) -> some View {
        modifier(ReadsHinge(posture: posture))
    }
}

private struct ReadsHinge: ViewModifier {
    @Binding var posture: HingePosture

    func body(content: Content) -> some View {
        content
            .environment(\.hingePosture, posture)
            .background {
                HingeReader {
                    #if DEBUG
                    NSLog("HingePosture reported: %@", String(describing: $0))
                    #endif
                    posture = faked ?? $0
                }
            }
            .onAppear { if let faked { posture = faked } }
    }

    /// The posture a debug build was launched with, if any.
    private var faked: HingePosture? {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-UITestHinge"), index + 1 < arguments.count else { return nil }
        switch arguments[index + 1] {
        case "closed": return .closed
        case "partial": return .partiallyOpen
        case "open": return .fullyOpen
        default: return nil
        }
        #else
        nil
        #endif
    }
}

/// A view that carries the `UIHingeInteraction`; the handler gets the status at once and on each change.
private struct HingeReader: UIViewRepresentable {
    let onChange: (HingePosture) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        let onChange = onChange
        // The app's floor is iOS 27.0 and the hinge API came with 27.1 (the only availability check here).
        if #available(iOS 27.1, *) {
            view.addInteraction(UIHingeInteraction { _, update in
                // A nil hinge: not in a hierarchy that has one (a phone, or the view has left its window).
                onChange(update.hinge.map { HingePosture($0.status) } ?? .none)
            })
        }
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {}
}

@available(iOS 27.1, *)
private extension HingePosture {
    init(_ status: UIHinge.Status) {
        switch status {
        case .closed: self = .closed
        case .partiallyOpen: self = .partiallyOpen
        case .fullyOpen: self = .fullyOpen
        default: self = .none
        }
    }
}
