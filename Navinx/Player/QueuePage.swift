import PlaybackKit
import SubsonicKit
import SwiftUI

/// Flutter `QueueView`: Up Next, with the playing row on glass, past songs dimmed, and handles for
/// reordering. On arriving, the current song sits right under the top bar. Auto DJ's songs come last,
/// under "Autoplay", and the ∞ button turns it on and off (C21, D90: Apple Music's Autoplay).
struct QueuePage: View {
    let metrics: NowPlayingMetrics
    let isLandscape: Bool
    let isActive: Bool

    @Environment(PlayerModel.self) private var player

    private var topBarGap: CGFloat {
        metrics.top > 0 ? metrics.top + (isLandscape ? 44 : 64) : (isLandscape ? 48 : 64)
    }

    var body: some View {
        if player.queue.isEmpty {
            Text("No songs in queue")
                .font(.system(size: 18))
                .foregroundStyle(.white.opacity(0.7))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            list
        }
    }

    private var list: some View {
        let places = Array(zip(player.playQueue.entryIDs, player.queue).enumerated())
        let autoplayStart = min(player.playQueue.autoplayStart, places.count)
        return ScrollViewReader { proxy in
            List {
                HStack {
                    Text("Up Next")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(.white)
                    Spacer(minLength: 8)
                    RefillButton()
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 24, trailing: 4))
                // Two groups, each reordered within itself: the user's songs, then Auto DJ's.
                rows(places[..<autoplayStart], from: 0)
                if autoplayStart < places.count {
                    Text("Autoplay")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.white)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 20, leading: 8, bottom: 12, trailing: 0))
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("autoplayHeading")
                    rows(places[autoplayStart...], from: autoplayStart)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollIndicators(.hidden)
            .scrollEdgeEffectHidden(true)
            .environment(\.editMode, .constant(.active))
            .contentMargins(.horizontal, 24, for: .scrollContent)
            .contentMargins(.top, topBarGap, for: .scrollContent)
            .contentMargins(.bottom, 40 + metrics.bottom, for: .scrollContent)
            .accessibilityIdentifier("queueList")
            .onChange(of: isActive) { _, isActive in
                if isActive { revealCurrent(proxy) }
            }
        }
        // The list fills the screen, up under the top bar. A frame larger than its page is centred
        // on it, so this moves it the rest of the way.
        .frame(height: metrics.height)
        .offset(y: (metrics.bottom - metrics.top) / 2)
    }

    /// The queue's rows from `start` on, reordered among themselves.
    private func rows(_ places: ArraySlice<(offset: Int, element: (UUID, Song))>, from start: Int) -> some View {
        let currentIndex = player.currentIndex
        return ForEach(Array(places), id: \.element.0) { index, pair in
            let isPlaying = index == currentIndex
            QueueRow(song: pair.1, isPlaying: isPlaying, isPast: index < currentIndex) {
                player.skip(toIndex: index)
            }
            .listRowBackground(rowBackground(isPlaying: isPlaying))
            .listRowSeparator(.hidden)
            // Flutter's 80 pt `ListTile`s; the playing one has 2 pt more each side, around its glass.
            .listRowInsets(EdgeInsets(top: isPlaying ? 6 : 4, leading: 8, bottom: isPlaying ? 6 : 4, trailing: 4))
        }
        .onMove { from, to in
            if let from = from.first { player.reorderQueue(from: start + from, to: start + to) }
        }
    }

    /// Flutter's glass capsule, 18 pt corners.
    @ViewBuilder
    private func rowBackground(isPlaying: Bool) -> some View {
        if isPlaying {
            Color.clear
                .appGlass(in: .rect(cornerRadius: 18))
                .padding(.vertical, 2)
                .accessibilityIdentifier("queueCurrentGlass")
        } else {
            Color.clear
        }
    }

    private func revealCurrent(_ proxy: ScrollViewProxy) {
        guard player.currentIndex > 0, player.playQueue.entryIDs.indices.contains(player.currentIndex) else { return }
        // Right under the top bar: `.top` would put it behind, since it ignores the content margin.
        proxy.scrollTo(
            player.playQueue.entryIDs[player.currentIndex],
            anchor: UnitPoint(x: 0.5, y: topBarGap / metrics.height)
        )
    }
}

/// Auto DJ on and off (Apple Music's Autoplay button): on brings back the last mode chosen in
/// Settings, Similar Songs the first time (D90). A glass circle, filled with the accent when on.
private struct RefillButton: View {
    @Environment(PlayerModel.self) private var player

    var body: some View {
        let isOn = player.isRefillOn
        Button("Autoplay", systemImage: "infinity") { player.toggleRefill() }
            .labelStyle(.iconOnly)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(isOn ? .white : .white.opacity(0.7))
            .frame(width: 36, height: 36)
            .contentShape(.circle)
            .appGlass(in: .circle, interactive: true, tint: isOn ? Palette.accent : nil)
            .buttonStyle(.plain)
            .accessibilityIdentifier("refillToggle")
            .accessibilityValue(isOn ? player.refillSource.label : "Off")
            .sensoryFeedback(.selection, trigger: isOn)
    }
}

private struct QueueRow: View {
    let song: Song
    let isPlaying: Bool
    let isPast: Bool
    let onTap: () -> Void

    @Environment(PlayerModel.self) private var player

    private var titleColor: Color {
        isPlaying ? Palette.accent : .white.opacity(isPast ? 0.38 : 1)
    }

    private var artistColor: Color {
        isPlaying ? Palette.accent.opacity(0.8) : .white.opacity(isPast ? 0.24 : 0.7)
    }

    var body: some View {
        HStack(spacing: 16) {
            AlbumArtwork(coverArt: song.coverArt, size: 48, cornerRadius: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .font(.system(size: 16, weight: isPlaying ? .bold : .regular))
                    .foregroundStyle(titleColor)
                    .lineLimit(1)
                Text(song.artist ?? "Unknown Artist")
                    .font(.system(size: 14))
                    .foregroundStyle(artistColor)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if isPlaying {
                LevelBars(color: Palette.accent, isPlaying: player.isPlaying)
            }
            SongOptionsButton(song: song, systemImage: "ellipsis", rotated: true, color: .white.opacity(0.7), width: 32)
        }
        .frame(minHeight: 72)
        .contentShape(.rect)
        .onTapGesture(perform: onTap)
        .songContextMenu(song)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(song.title)
        .accessibilityIdentifier("queueRow")
        .accessibilityValue(isPlaying ? "Playing" : "")
        .accessibilityAction(named: "Play", onTap)
    }
}
