import SwiftUI

/// A pushed page's large title, drawn by the page itself as the first thing on it, so it slides in and
/// out with the page. The bar's own large title (`.inlineLarge`) sits on a row of the navigation bar
/// under the back button and doesn't move with the page during a push or a pop (C11 for Settings, C66
/// for Favorites and Downloads). As that title looked and sat: 34 pt bold, on the leading edge.
struct PageTitle: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.largeTitle.bold())
            .accessibilityAddTraits(.isHeader)
            .padding(.horizontal, 16)
            .padding(.top, 3)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension View {
    /// Takes the title off the navigation bar for a page that draws its own `PageTitle`. The name stays
    /// for the back button and its history on the page pushed above.
    func ownPageTitle(_ title: String) -> some View {
        navigationTitle(title)
            .toolbarTitleDisplayMode(.inline)
            .toolbar(removing: .title)
    }
}
