import SwiftUI

extension EnvironmentValues {
    /// The room a tab's pages keep under their content while the bar can fold (`MainTabView.bottomRoom`).
    @Entry var pageBottomRoom: CGFloat = 0
}

extension View {
    /// Adds the tab's room (`pageBottomRoom`) to this page's bottom safe area, which its scroll view takes as
    /// room under its content. On each page inside its stack: added outside the stack it doesn't reach the
    /// pages, and as `contentMargins` it reached every scroll view, the horizontal rows too (the Library's chips
    /// bar grew by it).
    func keepsBottomRoom() -> some View {
        modifier(KeepsBottomRoom())
    }
}

private struct KeepsBottomRoom: ViewModifier {
    @Environment(\.pageBottomRoom) private var room

    func body(content: Content) -> some View {
        content.safeAreaPadding(.bottom, room)
    }
}
