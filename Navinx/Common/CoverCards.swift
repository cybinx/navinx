import SwiftUI

/// Flutter `HorizontalScrollSection`: a title over a sideways row of cards, each `posterSide` wide.
struct HorizontalSection<Content: View>: View {
    let title: String
    var horizontalPadding: CGFloat = 16
    let posterSide: CGFloat
    var onShowAll: (() -> Void)?
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 22, weight: .bold))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let onShowAll {
                    Button("See All", action: onShowAll)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.tint)
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, horizontalPadding)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 16, content: content)
                    .padding(.horizontal, horizontalPadding)
            }
            .frame(height: posterSide + 84)
            .scrollClipDisabled()
        }
    }
}

/// Flutter `MediaCard`: artwork on a card, with the glass play disc when the card can play. Its
/// clear 3 pt border and 12 pt padding make the inset 15, so the artwork is 30 narrower than the card.
struct CoverCard<Artwork: View>: View {
    static var inset: CGFloat { 15 }

    let title: String
    let subtitle: String?
    let size: CGFloat
    let onTap: () -> Void
    var onPlay: (() -> Void)?
    @ViewBuilder let artwork: () -> Artwork

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 0) {
                artwork()
                    .overlay(alignment: .bottomTrailing) {
                        if let onPlay { ArtPlayDisc(action: onPlay) }
                    }
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                    .padding(.top, 12)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.secondaryText)
                        .lineLimit(2)
                        .padding(.top, 4)
                }
            }
            .padding(Self.inset)
            .frame(width: size, height: size + 84, alignment: .topLeading)
            .background(Palette.card, in: .rect(cornerRadius: 8))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

extension CoverCard where Artwork == AlbumArtwork {
    init(
        title: String,
        subtitle: String?,
        coverArt: String?,
        size: CGFloat,
        isRound: Bool = false,
        onTap: @escaping () -> Void,
        onPlay: (() -> Void)? = nil
    ) {
        self.init(title: title, subtitle: subtitle, size: size, onTap: onTap, onPlay: onPlay) {
            AlbumArtwork(coverArt: coverArt, size: size - 2 * Self.inset, cornerRadius: isRound ? (size - 2 * Self.inset) / 2 : 4)
        }
    }
}

/// Flutter `QuickAccessTile`: Home's top grid. Flutter's play button only shows on hover, so phones never see it.
struct ShortcutTile<Artwork: View>: View {
    let title: String
    let onTap: () -> Void
    @ViewBuilder let artwork: () -> Artwork

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 0) {
                artwork().frame(width: 56, height: 56)
                Text(title)
                    .font(.system(size: 13, weight: .bold))
                    .lineLimit(2)
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 56)
            .background(Color(light: 0xF3F4F6, dark: 0x282828))
            .clipShape(.rect(cornerRadius: 6))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

/// Flutter `TopResultCard`: a frosted glass panel. Its play disc stays solid, as glass can't sit on glass.
struct BestMatchCard: View {
    let title: String
    let subtitle: String
    let typeLabel: String
    let coverArt: String?
    var isArtist = false
    let onTap: () -> Void
    let onPlay: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let isDark = colorScheme == .dark
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 0) {
                AlbumArtwork(coverArt: coverArt, size: 72, cornerRadius: isArtist ? 36 : 8)
                Text(title)
                    .font(.system(size: 20, weight: .bold))
                    .lineLimit(1)
                    .padding(.top, 14)
                HStack(spacing: 8) {
                    Text(typeLabel.uppercased())
                        .font(.system(size: 10, weight: .heavy))
                        .kerning(0.5)
                        .foregroundStyle(isDark ? .white.opacity(0.7) : .black.opacity(0.87))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(isDark ? .black.opacity(0.45) : .black.opacity(0.12), in: .rect(cornerRadius: 10))
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.secondaryText)
                        .lineLimit(1)
                }
                .padding(.top, 6)
                // Leaves the disc's corner clear of the text.
                .padding(.trailing, 56)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottomTrailing) {
            Button("Play", systemImage: "play.fill", action: onPlay)
                .labelStyle(.iconOnly)
                .font(.system(size: 20))
                .foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .background(.tint, in: .circle)
                .shadow(color: .black.opacity(0.38), radius: 4, y: 4)
                .buttonStyle(.plain)
                .padding(16)
        }
        .appGlass(in: .rect(cornerRadius: 16))
    }
}
