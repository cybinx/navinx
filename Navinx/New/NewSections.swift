import SubsonicKit
import SwiftUI

/// Flutter `NewAlbumRow`: a sideways row of album tiles.
struct ArrivalsRow: View {
    static let arrivalSide: CGFloat = 150
    /// The artwork, 8 pt and two lines of text.
    static let height: CGFloat = arrivalSide + 8 + 38

    let albums: [Album]
    /// Defaults to the album's artist.
    var subtitle: ((Album) -> String)?
    let onOpen: (Album) -> Void
    let onPlay: (Album) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 12) {
                ForEach(albums) { album in
                    ArrivalTile(
                        album: album,
                        subtitle: subtitle?(album) ?? album.artist,
                        onOpen: { onOpen(album) },
                        onPlay: { onPlay(album) }
                    )
                }
            }
            .padding(.horizontal, 16)
        }
        .frame(height: Self.height)
        .scrollClipDisabled()
    }
}

/// Flutter `NewAlbumTile`: the cover with its glass play disc, a title and a second line.
private struct ArrivalTile: View {
    let album: Album
    let subtitle: String?
    let onOpen: () -> Void
    let onPlay: () -> Void

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 0) {
                AlbumArtwork(coverArt: album.coverArt, size: ArrivalsRow.arrivalSide, cornerRadius: 10)
                    .overlay(alignment: .bottomTrailing) {
                        ArtPlayDisc(size: 32, action: onPlay).accessibilityIdentifier("newTilePlay")
                    }
                Text(album.name)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
                    .padding(.top, 8)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 13))
                        .kerning(0.45)
                        .foregroundStyle(Palette.secondaryText)
                        .lineLimit(1)
                }
            }
            .frame(width: ArrivalsRow.arrivalSide, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

/// Flutter `NewAlbumRowPlaceholder`: its shimmer, held still, as on the other pages.
struct ArrivalsRowSkeleton: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(0..<4, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 10)
                    .fill(Palette.fieldFill)
                    .frame(width: ArrivalsRow.arrivalSide, height: ArrivalsRow.arrivalSide)
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .frame(height: ArrivalsRow.height)
        .clipped()
    }
}

// MARK: Hero

/// Flutter `FeaturedHeroCarousel`'s sizes.
private enum HeroMetrics {
    static let labelBlockHeight: CGFloat = 80
    static let gap: CGFloat = 12

    /// The page's width less its gutters, 420 pt at most.
    static func card(pageWidth: CGFloat) -> CGFloat {
        max(min(pageWidth - 32, 420), 0)
    }
}

/// The newest albums as large swipeable cards, each just showing the edge of the next.
struct FeaturedHero: View {
    let albums: [Album]
    let pageWidth: CGFloat
    let onOpen: (Album) -> Void
    let onPlay: (Album) -> Void

    @State private var currentID: Album.ID?

    var body: some View {
        let card = HeroMetrics.card(pageWidth: pageWidth)
        VStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: HeroMetrics.gap) {
                    ForEach(albums) { album in
                        FeaturePage(
                            album: album,
                            posterSide: card,
                            onOpen: { onOpen(album) },
                            onPlay: { onPlay(album) }
                        )
                    }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, max(pageWidth - card, 0) / 2, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned(limitBehavior: .alwaysByOne))
            .scrollPosition(id: $currentID, anchor: .center)
            .scrollClipDisabled()
            .frame(height: HeroMetrics.labelBlockHeight + card)
            // On the Duo the next card must not show in the side strip: the row ends where the pages do (C17).
            .clippedToPages()

            if albums.count > 1 {
                FeaturePageDots(count: albums.count, current: albums.firstIndex { $0.id == currentID } ?? 0)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct FeaturePage: View {
    let album: Album
    let posterSide: CGFloat
    let onOpen: () -> Void
    let onPlay: () -> Void

    var body: some View {
        let details = NewFeed.artistAndYear(album)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text("RECENTLY ADDED")
                    .font(.system(size: 11, weight: .semibold))
                    .kerning(0.6)
                    .foregroundStyle(Palette.secondaryText)
                Text(album.name)
                    .font(.system(size: 20, weight: .semibold))
                    .kerning(-0.6)
                    .lineLimit(1)
                    .padding(.top, 2)
                    .accessibilityIdentifier("newHeroTitle")
                if !details.isEmpty {
                    Text(details)
                        .font(.system(size: 15))
                        .kerning(0.35)
                        .foregroundStyle(Palette.secondaryText)
                        .lineLimit(1)
                }
            }
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .frame(height: HeroMetrics.labelBlockHeight)

            Button(action: onOpen) {
                AlbumArtwork(coverArt: album.coverArt, size: posterSide, cornerRadius: 16)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(album.name)
            .overlay(alignment: .bottomTrailing) {
                GlassPlayCapsule(height: 44, iconSize: 16, textSize: 16, padding: 18, action: onPlay)
                    .accessibilityIdentifier("newHeroPlay")
                    .padding(14)
            }
        }
        .frame(width: posterSide)
    }
}

/// Flutter's "Play" over a cover: white on glass. The glass stays dark so the white reads in light
/// mode too, since it sits on artwork rather than on the page.
private struct GlassPlayCapsule: View {
    let height: CGFloat
    let iconSize: CGFloat
    let textSize: CGFloat
    let padding: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: "play.fill").font(.system(size: iconSize))
                Text("Play").font(.system(size: textSize, weight: .semibold)).kerning(0.4)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, padding)
            .frame(height: height)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .appGlass(in: .capsule, interactive: true)
        .environment(\.colorScheme, .dark)
    }
}

/// Flutter `_PageDots` on its small glass capsule.
private struct FeaturePageDots: View {
    let count: Int
    let current: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    // A plain colour: glass would lighten `.primary`.
                    .fill(Color(light: .black, dark: .white).opacity(index == current ? 0.8 : 0.25))
                    .frame(width: index == current ? 16 : 6, height: 6)
            }
        }
        .padding(.horizontal, 11)
        .frame(height: 22)
        .appGlass(in: .capsule)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: current)
        .accessibilityHidden(true)
    }
}

/// Flutter's first-load hero: a square at the card's place, with the dots' room below it.
struct FeaturedHeroPlaceholder: View {
    let pageWidth: CGFloat

    var body: some View {
        let card = HeroMetrics.card(pageWidth: pageWidth)
        RoundedRectangle(cornerRadius: 16)
            .fill(Palette.fieldFill)
            .frame(width: card, height: card)
            .padding(.top, HeroMetrics.labelBlockHeight)
            .padding(.bottom, 22)
            .frame(maxWidth: .infinity)
    }
}

// MARK: Mix

private enum MixMetrics {
    static let featureHeight: CGFloat = 148
    static let mosaic: CGFloat = 120
    static let cornerRadius: CGFloat = 18
}

/// Flutter `MixForYouSection`'s card, over its first cover, blurred.
struct MixCard: View {
    let songs: [Song]
    let onPlay: () -> Void
    let onNewMix: () async -> Void

    @State private var isRolling = false

    var body: some View {
        let covers = NewFeed.mixCovers(songs)
        let artists = NewFeed.mixArtists(songs)
        HStack(spacing: 14) {
            MixMosaic(covers: covers)
            VStack(alignment: .leading, spacing: 0) {
                Text(songs.count == 1 ? "1 song" : "\(songs.count) songs")
                    .font(.system(size: 17, weight: .bold))
                    .kerning(0.5)
                    .foregroundStyle(.white)
                if !artists.isEmpty {
                    Text(artists)
                        .font(.system(size: 13))
                        .kerning(0.35)
                        .lineSpacing(3)
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(2)
                        .padding(.top, 4)
                }
                HStack(spacing: 8) {
                    GlassPlayCapsule(height: 40, iconSize: 14, textSize: 15, padding: 16, action: onPlay)
                        .accessibilityIdentifier("newMixPlay")
                    GlassCircleButton(label: "New mix", systemImage: "arrow.2.squarepath", size: 40, iconSize: 16) {
                        Task {
                            isRolling = true
                            await onNewMix()
                            isRolling = false
                        }
                    }
                    .disabled(isRolling)
                    .environment(\.colorScheme, .dark)
                }
                .padding(.top, 12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .frame(minHeight: MixMetrics.featureHeight)
        .background { MixBackdrop(cover: covers.first) }
        .clipShape(.rect(cornerRadius: MixMetrics.cornerRadius))
        .padding(.horizontal, 16)
    }
}

private struct MixBackdrop: View {
    let cover: String?

    var body: some View {
        ZStack {
            Color(hex: 0x2C2C2E)
            if let cover {
                AlbumArtwork(coverArt: cover, size: 96, cornerRadius: 0, flexible: true)
                    .blur(radius: 30, opaque: true)
            }
            Color.black.opacity(0.32)
        }
    }
}

/// Four different covers, or one cover filling it if there aren't four.
private struct MixMosaic: View {
    let covers: [String]

    var body: some View {
        let half = MixMetrics.mosaic / 2
        Group {
            if covers.count < 4 {
                AlbumArtwork(coverArt: covers.first, size: MixMetrics.mosaic, cornerRadius: 0)
            } else {
                Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                    GridRow {
                        AlbumArtwork(coverArt: covers[0], size: half, cornerRadius: 0)
                        AlbumArtwork(coverArt: covers[1], size: half, cornerRadius: 0)
                    }
                    GridRow {
                        AlbumArtwork(coverArt: covers[2], size: half, cornerRadius: 0)
                        AlbumArtwork(coverArt: covers[3], size: half, cornerRadius: 0)
                    }
                }
            }
        }
        .frame(width: MixMetrics.mosaic, height: MixMetrics.mosaic)
        .clipShape(.rect(cornerRadius: 10))
        .accessibilityHidden(true)
    }
}

struct MixCardPlaceholder: View {
    var body: some View {
        RoundedRectangle(cornerRadius: MixMetrics.cornerRadius)
            .fill(Color(light: 0xE0E0E0, dark: 0x181818))
            .frame(height: MixMetrics.featureHeight)
            .padding(.horizontal, 16)
    }
}
