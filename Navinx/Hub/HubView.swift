import HubKit
import SwiftUI
import UIKit

/// The server's own tab (C27, D106): its own stack, the root screen the server sent, pull to
/// refresh, and the sheets and pushed screens its actions open.
struct HubTabView: View {
    @Bindable var model: HubModel

    var body: some View {
        NavigationStack(path: $model.path) {
            Group {
                if let root = model.root {
                    HubPageView(page: root, isRoot: true).keepsBottomRoom()
                }
            }
            .navigationDestination(for: HubRoute.self) { route in
                switch route {
                case .library(let library):
                    RouteDestination(route: library, path: libraryPath)
                case .screen(let id):
                    // As `RouteDestination` does for the pages it shows: a stack's destinations don't inherit the root's.
                    if let page = model.page(id) { HubPageView(page: page, isRoot: false).keepsBottomRoom().expandsTabBarAtTop() }
                }
            }
        }
        .environment(\.openLibraryRoute) { model.path.append(.library($0)) }
        .onChange(of: model.path) { model.pathChanged() }
        .sheet(item: $model.sheet) { page in
            HubSheetView(page: page)
        }
    }

    /// The library pages on the stack, as `RouteDestination` keeps them.
    private var libraryPath: Binding<[LibraryRoute]> {
        Binding(
            get: { model.path.compactMap { if case .library(let route) = $0 { route } else { nil } } },
            set: { model.path = $0.map(HubRoute.library) }
        )
    }
}

/// A full page: today's Add look (D30, D72): the accent backdrop, the cards on it, an inline large title.
struct HubPageView: View {
    let page: HubPage
    let isRoot: Bool
    @Environment(HubModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HubSectionsView(page: page)
                if isRoot { HubOwnerNote() }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 40)
        }
        .scrollDismissesKeyboard(.immediately)
        .modifier(HubPullToRefresh(enabled: isRoot))
        .background { HubBackdrop().ignoresSafeArea() }
        .navigationTitle(page.screen.title)
        .toolbarTitleDisplayMode(.inlineLarge)
        .hubRefreshes(page)
    }
}

/// Under the root screen's last section, so nobody takes the tab for the app's own (C53, D190).
private struct HubOwnerNote: View {
    var body: some View {
        Text("This tab comes from your server.")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 16)
            .accessibilityIdentifier("hubOwnerNote")
    }
}

private struct HubPullToRefresh: ViewModifier {
    let enabled: Bool
    @Environment(HubModel.self) private var model

    func body(content: Content) -> some View {
        if enabled {
            content.refreshable { await model.reload() }
        } else {
            content
        }
    }
}

/// A screen shown as a sheet, with today's detents when the server gives a height, and large always
/// there: what doesn't fit scrolls.
struct HubSheetView: View {
    let page: HubPage

    var body: some View {
        ScrollView {
            HubSectionsView(page: page)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 28)
                .padding(.bottom, 20)
        }
        // Content that fits doesn't bounce, as the sheet didn't before it scrolled.
        .scrollBounceBehavior(.basedOnSize)
        .presentationDetents(detents)
        .presentationDragIndicator(.visible)
        .hubRefreshes(page)
    }

    private var detents: Set<PresentationDetent> {
        guard let height = page.screen.sheetHeight, height > 0 else { return [.medium, .large] }
        return [.height(height), .medium, .large]
    }
}

/// A screen's sections, one under the other.
struct HubSectionsView: View {
    let page: HubPage
    /// In Search the section titles are smaller (the first section's gap goes above Search's caption,
    /// `HubSearchSection`).
    var inSearch = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(page.screen.sections.enumerated()), id: \.element.id) { index, section in
                HubSectionView(section: section, page: page, inSearch: inSearch)
                    .padding(.top, index == 0 ? 0 : section.gap ?? 16)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One section: its title (and the title's button), then its parts in a card or on the backdrop.
private struct HubSectionView: View {
    let section: HubSection
    let page: HubPage
    let inSearch: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title = section.title, !title.isEmpty {
                header(title)
                card.padding(.top, titleGap)
            } else {
                card
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("hub-section-\(section.id)")
    }

    /// Under a title: the first part's own gap, else today's (10, or 6 beside a title's button).
    private var titleGap: CGFloat {
        if let gap = section.parts.first?.gap { return gap }
        return section.button == nil ? 10 : 6
    }

    private func header(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: inSearch ? 18 : 22, weight: .bold))
                .tracking(inSearch ? 0 : -0.4)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            if let button = section.button {
                HubIconButton(button: button, page: page)
            }
        }
    }

    @ViewBuilder private var card: some View {
        let parts = HubPartsView(parts: section.parts, page: page)
        let allRows = !section.parts.isEmpty && section.parts.allSatisfy { if case .row = $0 { true } else { false } }
        let padding = allRows
            ? EdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 14)
            : EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16)
        switch section.card {
        case .glass: HubCard(padding: padding) { parts }
        case .plain: HubCard(padding: padding, glass: false) { parts }
        case .none: parts
        }
    }
}

// MARK: - Refresh

extension View {
    /// Fetches the page again every `refresh` seconds while it's on screen and the app is in front,
    /// paused while one of its actions is on its way.
    func hubRefreshes(_ page: HubPage) -> some View {
        modifier(HubRefreshes(page: page))
    }
}

private struct HubRefreshes: ViewModifier {
    let page: HubPage
    @Environment(HubModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    private struct Key: Equatable {
        let seconds: Int?
        let active: Bool
        let sending: Bool
        let screen: String
    }

    func body(content: Content) -> some View {
        content.task(id: Key(
            seconds: page.screen.refresh, active: scenePhase == .active, sending: page.isSending, screen: page.screen.id
        )) {
            guard let seconds = page.screen.refresh, scenePhase == .active, !page.isSending else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled else { return }
                await model.refresh(page)
            }
        }
    }
}

// MARK: - The tab's symbol

enum HubSymbol {
    static let fallback = "circle.grid.2x2"

    /// The server's SF Symbol, or the fallback when this system doesn't have it.
    static func resolve(_ name: String) -> String {
        UIImage(systemName: name) == nil ? fallback : name
    }
}
