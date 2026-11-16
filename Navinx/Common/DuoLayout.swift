import SwiftUI
import UIKit

// The iPhone Duo (C17). On its cover display (466 x 678 pt) the system keeps an 84 pt strip down one
// side of the window for the clock and the side rail (the tab bar stood on its end, with the toolbar's
// buttons), and the app's pages get the 382 pt that is left as their safe area. The strip is on the
// trailing edge in portrait and on either edge in landscape. Views that run the full width of the
// window, like a chip row, would run into it, so they read how wide the strip is here.
//
// Nothing here looks at the device model: the strip is what tells the Duo's cover display from a phone
// (no iPhone has 60 pt or more of safe area on a side).

/// How much of the window's width the system keeps on each side.
nonisolated struct SideInsets: Equatable, Sendable {
    var leading: CGFloat = 0
    var trailing: CGFloat = 0

    /// True on the Duo's cover display, where the system's side rail stands in the strip.
    var hasRail: Bool { leading + trailing >= 60 }

    var width: CGFloat { max(leading, trailing) }
}

extension EnvironmentValues {
    @Entry var sideInsets = SideInsets()
}

extension View {
    /// Reads the window's side insets for everything below (set once, on the root of the tabs), and keeps
    /// them in `insets` for the view that owns it.
    func readsSideInsets(_ insets: Binding<SideInsets>) -> some View {
        modifier(ReadsSideInsets(insets: insets))
    }

    /// Keeps a row that scrolls past its frame (a chip row, Settings' tab strip, the hero) out of the
    /// Duo's side strip: what it draws ends where the pages do. A scroll view draws into the safe area
    /// (and with `scrollClipDisabled` past it), so it's masked to its layout frame, with room above and
    /// below for the glass's shadow. Nothing changes on a phone.
    func clippedToPages() -> some View {
        modifier(ClippedToPages())
    }
}

private struct ReadsSideInsets: ViewModifier {
    @Binding var insets: SideInsets

    func body(content: Content) -> some View {
        content
            .environment(\.sideInsets, insets)
            .onGeometryChange(for: SideInsets.self) { proxy in
                SideInsets(leading: proxy.safeAreaInsets.leading, trailing: proxy.safeAreaInsets.trailing)
            } action: { insets = $0 }
    }
}

private struct ClippedToPages: ViewModifier {
    @Environment(\.sideInsets) private var sideInsets

    @ViewBuilder
    func body(content: Content) -> some View {
        if sideInsets.hasRail {
            content.mask { Rectangle().padding(.vertical, -60) }
        } else {
            content
        }
    }
}

/// The Duo's inner display with now playing open (C30 bug 17, D122): the app with its tabs keeps the half
/// left of the hinge, as it is with the player closed but without the mini-player, and now playing takes
/// the half right of it. Open or half open alike; the cover display (closed) keeps the full-screen player.
/// The inner display runs the app in landscape, 951 x 669 pt, two halves of about the cover display's size
/// side by side, with the hinge down the middle. UIKit says how far the hinge is open but not where it is,
/// so its place is the window's middle.
nonisolated enum DuoSplit {
    /// The narrowest window that splits: the inner display is 951 pt wide, the cover display at most 678.
    static let minimumWidth: CGFloat = 800

    static func applies(hinge: HingePosture, window: CGSize) -> Bool {
        guard hinge == .fullyOpen || hinge == .partiallyOpen else { return false }
        return window.width >= minimumWidth && window.width > window.height
    }

    /// The hinge's place across the window.
    static func hinge(in window: CGSize) -> CGFloat { (window.width / 2).rounded() }

    /// Now playing's half, in the window, the strip's part of it included.
    static func playerArea(in window: CGSize) -> CGRect {
        let hinge = hinge(in: window)
        return CGRect(x: hinge, y: 0, width: window.width - hinge, height: window.height)
    }
}

extension EnvironmentValues {
    /// Where now playing opens to, in the window, when it isn't the whole window (the Duo's inner display,
    /// `DuoSplit`); nil in the full-screen presentation.
    @Entry var nowPlayingArea: CGRect?
}

#if DEBUG
/// `-UITestOrientation left|right|portrait` (debug builds, for the UI tests and screenshots): turns the
/// scene by asking for the geometry. On the iPhone Duo `XCUIDevice.orientation` does nothing, but this
/// rotates the scene with the real insets (`landscapeLeft` puts the strip on the right).
struct UITestOrientation: UIViewControllerRepresentable {
    static var requested: UIInterfaceOrientationMask? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-UITestOrientation"), index + 1 < arguments.count else { return nil }
        switch arguments[index + 1] {
        case "left": return .landscapeLeft
        case "right": return .landscapeRight
        case "portrait": return .portrait
        default: return nil
        }
    }

    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) {}

    final class Controller: UIViewController {
        override func viewDidLoad() {
            super.viewDidLoad()
            view.isUserInteractionEnabled = false
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard let mask = UITestOrientation.requested, let scene = view.window?.windowScene else { return }
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
        }
    }
}
#endif
