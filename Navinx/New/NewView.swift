import PlaybackKit
import SubsonicKit
import SwiftUI

/// The New tab: Flutter `NewScreen`. All five sections stay, on the user's word.
struct NewView: View {
    @Environment(AccountModel.self) private var account
    @Environment(ToastCenter.self) private var toasts
    @Environment(PlayerModel.self) private var player

    /// Kept by `MainTabView`, so now playing can open a page here.
    @Binding var path: [LibraryRoute]
    @State private var model = NewModel()
    @State private var pageWidth: CGFloat = 0

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                if account.state == .offlineMode {
                    NeedsServerMessage()
                        .containerRelativeFrame(.vertical)
                } else {
                    sections
                }
            }
            // A separate task: a cancelled pull (the list changing under it) must not stop the load.
            .refreshable {
                let client = account.client
                let kept = await Task { await model.refresh(client: client) }.value
                // The sections kept what they showed: said, or the pull looks like it did nothing. Offline
                // mode's page already says it needs the server.
                guard !account.isOffline else { return }
                if kept.albums {
                    toasts.show("Error loading albums")
                } else if kept.songs {
                    toasts.show("Error loading songs")
                }
            }
            .onGeometryChange(for: CGFloat.self, of: \.size.width) { pageWidth = $0 }
            .scrollEdgeEffectStyle(.soft, for: .top)
            .keepsBottomRoom()
            .background(Palette.background)
            .navigationTitle("New")
            .toolbarTitleDisplayMode(.inlineLarge)
            .navigationDestination(for: LibraryRoute.self) { RouteDestination(route: $0, path: $path) }
        }
        .environment(\.openLibraryRoute) { path.append($0) }
        .task(id: account.client != nil) { model.start(client: account.client) }
    }

    /// Flutter's order, 32 pt apart.
    private var sections: some View {
        VStack(alignment: .leading, spacing: 32) {
            hero
            fresh
            rediscover
            latestAdditions
            mix
        }
        .padding(.top, 8)
        .padding(.bottom, 40)
    }

    private var hero: some View {
        ArrivalsSection(
            load: model.hero,
            client: account.client,
            showsHeader: false,
            title: "Featured",
            isEmpty: \.isEmpty,
            emptyMessage: "Albums you add to your server will be featured here.",
            emptyIcon: "music.note.square.stack"
        ) {
            FeaturedHeroPlaceholder(pageWidth: pageWidth)
        } content: { albums in
            FeaturedHero(albums: albums, pageWidth: pageWidth, onOpen: open, onPlay: play)
        }
    }

    private var fresh: some View {
        ArrivalsSection(
            load: model.fresh,
            client: account.client,
            title: "Fresh From Artists You Play",
            subtitle: { $0?.subtitle },
            isEmpty: { $0.albums.isEmpty },
            emptyMessage: "Play more music and new albums from your favorite artists will show up here.",
            emptyIcon: "person.2"
        ) {
            ArrivalsRowSkeleton()
        } content: { data in
            ArrivalsRow(albums: data.albums, subtitle: NewFeed.artistAndYear, onOpen: open, onPlay: play)
        }
    }

    private var rediscover: some View {
        ArrivalsSection(
            load: model.rediscover,
            client: account.client,
            title: "Rediscover",
            subtitle: { $0?.isEmpty == false ? "Loved, but not played lately" : nil },
            isEmpty: \.isEmpty,
            emptyMessage: "Star albums you love. When you haven't played them for a while, they'll come back here.",
            emptyIcon: "heart"
        ) {
            ArrivalsRowSkeleton()
        } content: { albums in
            ArrivalsRow(albums: albums, onOpen: open, onPlay: play)
        }
    }

    private var latestAdditions: some View {
        ArrivalsSection(
            load: model.latestAdditions,
            client: account.client,
            title: "Recently Added",
            onShowAll: { path.append(.latestReleases) },
            isEmpty: \.isEmpty,
            emptyMessage: "Nothing new on your server yet.",
            emptyIcon: "sparkles"
        ) {
            ArrivalsRowSkeleton()
        } content: { albums in
            ArrivalsRow(albums: albums, onOpen: open, onPlay: play)
        }
    }

    private var mix: some View {
        ArrivalsSection(
            load: model.mix,
            client: account.client,
            title: "Mix For You",
            subtitle: { $0?.isEmpty == false ? "A random mix from your library" : nil },
            isEmpty: \.isEmpty,
            emptyMessage: "Add some music to your server to get a mix.",
            emptyIcon: "shuffle",
            errorMessage: "Error loading songs"
        ) {
            MixCardPlaceholder()
        } content: { songs in
            MixCard(songs: songs) {
                player.playInOrder(songs)
            } onNewMix: {
                // The mix shown stays when no new one comes: said, so the button doesn't look dead.
                if await model.mix.load(client: account.client), !account.isOffline {
                    toasts.show("Error loading songs")
                }
            }
        }
    }

    private func open(_ album: Album) {
        path.append(.album(album))
    }

    private func play(_ album: Album) {
        Task { await player.playAlbum(album, client: account.client, toasts: toasts) }
    }
}

/// A section's header and its current state: placeholder, content, empty message or error with Retry.
private struct ArrivalsSection<Value: Sendable, Placeholder: View, Content: View>: View {
    let load: SectionLoad<Value>
    let client: SubsonicClient?
    var showsHeader = true
    let title: String
    var subtitle: (Value?) -> String? = { _ in nil }
    var onShowAll: (() -> Void)?
    let isEmpty: (Value) -> Bool
    let emptyMessage: String
    let emptyIcon: String
    var errorMessage = "Error loading albums"
    @ViewBuilder let placeholder: () -> Placeholder
    @ViewBuilder let content: (Value) -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showsHeader {
                ArrivalsHeader(
                    title: title,
                    subtitle: subtitle(load.data),
                    // Nothing to see all of until there's something here.
                    onShowAll: load.data.map(isEmpty) == false ? onShowAll : nil
                )
            }
            switch load.phase {
            case .placeholder:
                placeholder()
            case .content(let value) where isEmpty(value):
                ArrivalsNotice(icon: emptyIcon, message: emptyMessage)
            case .content(let value):
                content(value)
            case .failed:
                ArrivalsNotice(icon: "exclamationmark.triangle", message: errorMessage, actionLabel: "Retry") {
                    Task { await load.load(client: client) }
                }
            }
        }
    }
}

/// Flutter `NewSectionHeader` in its glass form: a bold title, with "See All" as a glass chip.
private struct ArrivalsHeader: View {
    let title: String
    let subtitle: String?
    let onShowAll: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 22, weight: .bold))
                    .kerning(-0.7)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let onShowAll {
                    Button(action: onShowAll) {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                            Text("See All").font(.system(size: 13, weight: .semibold))
                        }
                        .padding(.vertical, 2)
                    }
                    .appGlassButtonStyle()
                    .controlSize(.small)
                    .accessibilityIdentifier("newSeeAll")
                }
            }
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 14))
                    .kerning(0.35)
                    .foregroundStyle(Palette.secondaryText)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 16)
    }
}

/// Flutter `NewSectionMessage`: an empty or error message. Not glass in Flutter either, since the flat
/// page has nothing for glass to bend.
private struct ArrivalsNotice: View {
    let icon: String
    let message: String
    var actionLabel: String?
    var onAction: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(Palette.secondaryText)
                .frame(width: 22, height: 22)
            Text(message)
                .font(.system(size: 15))
                .kerning(0.45)
                .lineSpacing(3)
                .foregroundStyle(Palette.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let actionLabel, let onAction {
                Button(actionLabel, action: onAction)
                    .font(.system(size: 15, weight: .medium))
                    .padding(.leading, 8)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Palette.card, in: .rect(cornerRadius: 14))
        .padding(.horizontal, 16)
    }
}

/// Flutter `_NeedsServer`: every section needs the server, so offline mode shows this instead.
private struct NeedsServerMessage: View {
    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 38))
                .foregroundStyle(Palette.secondaryText)
            Text("New needs your server")
                .font(.system(size: 15, weight: .semibold))
                .padding(.top, 14)
            Text("Connect to your music server to see what's new, rediscover old favorites and get a fresh mix.")
                .font(.system(size: 15))
                .foregroundStyle(Palette.secondaryText)
                .padding(.top, 6)
        }
        .multilineTextAlignment(.center)
        .padding(40)
    }
}
