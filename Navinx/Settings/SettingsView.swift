import SwiftUI

/// Flutter `SettingsScreen` (`lib/screens/settings/settings_screen.dart`): the title on the left, a
/// scrolling strip of tabs under it, and one page per tab, which also swipe. Flutter's Android Auto
/// and Support tabs are left out (D63).
struct SettingsView: View {
    nonisolated enum Page: String, CaseIterable, Identifiable {
        case playback, storage, server, display, about
        var id: Self { self }

        /// What the strip shows (D210): "Servers" and "Appearance" for the server and display pages.
        var title: String {
            switch self {
            case .playback: "Playback"
            case .storage: "Storage"
            case .server: "Servers"
            case .display: "Appearance"
            case .about: "About"
            }
        }

        /// Kept from the earlier titles ("settingsTab-Server", "settingsTab-Display"): the UI tests find
        /// the pages by these.
        var identifier: String { "settingsTab-\(rawValue.capitalized)" }

        var systemImage: String {
            switch self {
            case .playback: "waveform"
            case .storage: "internaldrive"
            case .server: "server.rack"
            case .display: "circle.lefthalf.filled"
            case .about: "questionmark.circle"
            }
        }
    }

    @State private var page: Page = .playback

    var body: some View {
        TabView(selection: $page) {
            ForEach(Page.allCases) { page in
                ScrollView {
                    content(page)
                        .padding(.top, 16)
                        .padding(.bottom, 40)
                }
                .scrollEdgeEffectStyle(.soft, for: .top)
                .tag(page)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .background(Palette.background)
        .safeAreaBar(edge: .top) {
            VStack(alignment: .leading, spacing: 0) {
                PageTitle("Settings")
                strip
            }
        }
        // The title is drawn above the strip, not by the bar: the bar's own large title
        // (`.inlineLarge`, on its row under a pushed page's back button) didn't leave with the page
        // when it had a top `safeAreaBar`, but stayed over the page behind and faded out after the
        // pop (the C11 review). The name stays for the back button's history.
        .ownPageTitle("Settings")
    }

    @ViewBuilder
    private func content(_ page: Page) -> some View {
        switch page {
        case .playback: PlaybackSettingsPage()
        case .storage: StorageSettingsPage()
        case .server: ServerSettingsPage()
        case .display: DisplaySettingsPage()
        case .about: AboutSettingsPage()
        }
    }

    /// Flutter's scrollable `TabBar`: icon over label, the selected one in the primary colour
    /// (black, or white in dark mode) with the accent's underline, the others grey (D72).
    private var strip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(Page.allCases) { item in
                        let isSelected = item == page
                        Button {
                            withAnimation(.snappy) { page = item }
                        } label: {
                            VStack(spacing: 4) {
                                Image(systemName: item.systemImage)
                                    .font(.system(size: 17))
                                    .frame(height: 22)
                                Text(item.title)
                                    .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
                            }
                            .foregroundStyle(isSelected ? Color.primary : Palette.secondaryText)
                            .padding(.horizontal, 16)
                            .padding(.top, 6)
                            .padding(.bottom, 9)
                            .overlay(alignment: .bottom) {
                                if isSelected {
                                    Capsule()
                                        .fill(Palette.accent)
                                        .frame(height: 3)
                                        .padding(.horizontal, 12)
                                }
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .id(item)
                        .accessibilityIdentifier(item.identifier)
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 4)
            }
            .onChange(of: page) { withAnimation { proxy.scrollTo(page, anchor: .center) } }
        }
        // On the Duo the strip ends where the pages do, not under the clock (C17).
        .clippedToPages()
    }
}
