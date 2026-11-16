import HubKit
import SwiftUI

/// Search's section from the server (C27, Q2a): under the library's results, under every filter and
/// inside "No results" (Flutter's placement), for an account that has the server's tab. Nothing at
/// all otherwise: no request is sent and nothing is drawn. A caption over it says whose it is (C53, D190);
/// with no add-on, an empty answer, a failed one or one without content, there is no section, caption or
/// gap at all.
struct HubSearchSection: View {
    /// Extra space above it, only when it's there.
    var top: CGFloat = 0
    @Environment(HubModel.self) private var model

    var body: some View {
        if model.isShown, let page = model.searchSection, let first = page.screen.sections.first,
           page.screen.sections.contains(where: { !$0.parts.isEmpty || !($0.title ?? "").isEmpty }) {
            VStack(alignment: .leading, spacing: 4) {
                Text("From your server")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("hubSearchCaption")
                HubSectionsView(page: page, inSearch: true)
            }
            // The first section's gap, as it had under the library's results, now above the caption.
            .padding(.top, top + (first.gap ?? 16))
            .hubRefreshes(page)
        }
    }
}
