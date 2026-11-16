import SwiftUI

extension View {
    /// The chip rows' look (Home, the Library, Search): glass in the primary colour, not red (D72).
    /// The selected chip is filled with it (black, or white in dark mode) and its text takes the
    /// background's colour; the others are plain glass with primary text.
    @ViewBuilder
    func filterChipStyle(selected: Bool) -> some View {
        if selected {
            foregroundStyle(Palette.background)
                .buttonStyle(.glassProminent)
                .tint(.primary)
        } else {
            foregroundStyle(.primary)
                .appGlassButtonStyle()
                .tint(.primary)
        }
    }
}
