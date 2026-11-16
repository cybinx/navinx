import SwiftUI

/// Flutter `SettingsDisplayTab`: the theme and accent, the app icon (C52, D186; not in Flutter), star ratings (C22) and the live lyric under
/// the cover, Home's favourite playlists, the lyrics display, and the recommendations. Left out
/// (D63, D64): language, circular design, the volume bar and mini-player button switches, live
/// search and artwork resolution.
struct DisplaySettingsPage: View {
    @Environment(AppearanceModel.self) private var appearance
    @Environment(RecommendationModel.self) private var recommendations
    @Environment(ToastCenter.self) private var toasts

    @AppStorage(LyricsSettings.showsCurrentLineCapsule) private var showsLyricPill = false
    @AppStorage(PlayerDisplayOptions.showsRatingStars) private var showsStarRatings = false
    @AppStorage(PinnedPlaylistsModel.showOnHomeKey) private var showsPinnedPlaylists = false
    @AppStorage(LyricsSettings.softensOtherLines) private var softensOtherLines = false
    @AppStorage(LyricsSettings.alignment) private var alignment = "left"
    @AppStorage(LyricsSettings.glowsCurrentLine) private var glowsCurrentLine = true
    @AppStorage(LyricsSettings.holdsScreenAwake) private var keepsScreenOn = true

    @State private var confirmingClear = false

    var body: some View {
        VStack(spacing: 24) {
            SettingsSection(title: "THEME") { LookEditor() }
            if AppIconModel.shared.isAvailable {
                SettingsSection(title: "APP ICON") { AppIconPicker() }
            }
            SettingsSection(title: "NOW PLAYING") {
                SettingsSwitchRow(
                    title: "Show Star Ratings",
                    subtitle: "Rate songs and view ratings",
                    isOn: $showsStarRatings,
                    identifier: "showsRatingStars"
                ) { SettingsGlyph("star.leadinghalf.filled", colors: gradient(0xFFD700, 0xFFA500)) }
                SettingsRule(indent: 16)
                SettingsSwitchRow(
                    title: "Live Lyrics Under Artwork",
                    subtitle: "Show currently synced lyric line under the album cover in the full-screen player",
                    isOn: $showsLyricPill
                ) { SettingsGlyph("text.below.photo.fill", colors: gradient(0x5856D6, 0xAF52DE)) }
            }
            SettingsSection(title: "HOME") {
                SettingsSwitchRow(
                    title: "Favorite playlists on Home",
                    subtitle: "Show each favorite playlist as its own row at the top of the Home screen",
                    isOn: $showsPinnedPlaylists
                ) { SettingsGlyph("pin.fill", colors: gradient(0xFA243C, 0xFF2D55)) }
            }
            lyricsDisplay
            usesTailoredPicks
        }
        // Cancel in the normal colour, not the accent (C66).
        .neutralAlert("Clear Listening History", isPresented: $confirmingClear) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                recommendations.clear()
                toasts.show("Listening history cleared")
            }
        } message: {
            Text("This will reset all your listening data and recommendations. Are you sure?")
        }
    }

    /// Flutter's plain `SwitchListTile`s and the alignment's segmented buttons.
    private var lyricsDisplay: some View {
        SettingsSection(title: "LYRICS") {
            SettingsSwitchRow(
                title: "Blur Unfocused Lyrics",
                subtitle: "Add blur effect to past and upcoming lyric lines",
                isOn: $softensOtherLines
            )
            SettingsRule(indent: 16)
            SettingsRow(title: "Lyrics Alignment", subtitle: alignment == "center" ? "Centered" : "Left aligned") {
                EmptyView()
            } trailing: {
                Picker("Lyrics Alignment", selection: $alignment) {
                    Label("Left", systemImage: "text.justify.left").tag("left")
                    Label("Center", systemImage: "text.justify").tag("center")
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .accessibilityIdentifier("lyricsAlignment")
            }
            SettingsRule(indent: 16)
            SettingsSwitchRow(
                title: "Active Line Glow",
                subtitle: "Subtle glow effect on currently playing lyric line",
                isOn: $glowsCurrentLine
            )
            SettingsRule(indent: 16)
            SettingsSwitchRow(
                title: "Keep Screen On",
                subtitle: "Prevent the screen from turning off while reading lyrics",
                isOn: $keepsScreenOn,
                identifier: "lyricsHoldsScreenAwake"
            )
        }
    }

    private var usesTailoredPicks: some View {
        let stats = recommendations.data.listeningStats
        return SettingsSection(title: "RECOMMENDATIONS") {
            SettingsSwitchRow(
                title: "Recommendations",
                subtitle: "Get personalized music suggestions",
                isOn: Binding(get: { recommendations.data.isEnabled }, set: { recommendations.setEnabled($0) })
            ) { SettingsGlyph("wand.and.stars", colors: gradient(0xFF2D55, 0xFF6B6B)) }
            SettingsRule(indent: 16)
            SettingsRow(title: "Listening Data", subtitle: "\(stats.totalPlays) total plays") {
                EmptyView()
            } trailing: {
                Text(SettingsFormat.songs(stats.songs)).font(.system(size: 14))
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("listeningData")
            SettingsRule(indent: 16)
            SettingsRow(title: "Clear Listening History", titleColor: Color(hex: 0xFF3B30), action: { confirmingClear = true }) {
                EmptyView()
            }
            .accessibilityIdentifier("clearListeningHistory")
        }
    }
}

/// Flutter `_buildAppearanceEditor`: the theme's three tiles and the accent's circles, each under a
/// small tinted icon and a label.
private struct LookEditor: View {
    @Environment(AppearanceModel.self) private var appearance
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            editorRow("sun.lefthalf.filled", color: Color(hex: 0x5856D6), label: "Theme") {
                HStack(spacing: 6) {
                    ForEach(AppearanceModel.Theme.allCases) { theme in
                        themeTile(theme)
                    }
                }
            }
            editorRow("swatchpalette.fill", color: Color(hex: 0xFF9500), label: "Accent color") {
                HStack(spacing: 10) {
                    ForEach(AppearanceModel.Accent.allCases) { accent in
                        accentCircle(accent)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func editorRow(_ systemImage: String, color: Color, label: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(color.opacity(0.15))
                    .frame(width: 28, height: 28)
                    .overlay {
                        Image(systemName: systemImage)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(color)
                    }
                Text(label).font(.system(size: 14, weight: .semibold))
            }
            content()
        }
    }

    private func themeTile(_ theme: AppearanceModel.Theme) -> some View {
        let isSelected = appearance.theme == theme
        let unselected: Color = colorScheme == .dark ? .white.opacity(0.7) : .black.opacity(0.54)
        return Button {
            withAnimation(.easeOut(duration: 0.18)) { appearance.theme = theme }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: theme.systemImage).font(.system(size: 16))
                Text(theme.title).font(.system(size: 11, weight: isSelected ? .semibold : .medium))
            }
            .foregroundStyle(isSelected ? .white : unselected)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                isSelected ? Palette.accent : (colorScheme == .dark ? .white.opacity(0.08) : .black.opacity(0.06)),
                in: .rect(cornerRadius: 10)
            )
            .contentShape(.rect(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("theme-\(theme.title)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func accentCircle(_ accent: AppearanceModel.Accent) -> some View {
        let isSelected = appearance.accent == accent
        return Button {
            withAnimation(.easeOut(duration: 0.16)) { appearance.accent = accent }
        } label: {
            Circle()
                .fill(accent.color)
                .frame(width: 32, height: 32)
                .overlay { if isSelected { Circle().strokeBorder(.white, lineWidth: 2.5) } }
                .overlay {
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .shadow(color: isSelected ? accent.color.opacity(0.6) : .clear, radius: 5)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accent.title)
        .accessibilityIdentifier("accent-\(accent.rawValue)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The home screen icon (C52, D186; Flutter has no such choice): the five options in one row (six
/// until C54), each a tile in the icon's own shape with its name under it, the current one ringed
/// and its name in semibold, as the theme tiles above mark theirs. The tiles share the row's width
/// (64 pt at most) and the row is centred, so five fit any iPhone without scrolling.
private struct AppIconPicker: View {
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.colorScheme) private var colorScheme
    private let icons = AppIconModel.shared

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ForEach(AppIconChoice.allCases) { choice in
                tile(choice)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity)
    }

    private func tile(_ choice: AppIconChoice) -> some View {
        let isSelected = icons.current == choice
        let unselected: Color = colorScheme == .dark ? .white.opacity(0.7) : .black.opacity(0.54)
        return Button {
            Task {
                do {
                    try await icons.choose(choice)
                } catch {
                    toasts.show("Couldn't change the app icon")
                }
            }
        } label: {
            VStack(spacing: 6) {
                Image(choice.previewImageName)
                    .resizable()
                    .aspectRatio(1, contentMode: .fit)
                    .clipShape(IconTileShape())
                    .padding(4.5)
                    .overlay {
                        if isSelected { IconTileShape().strokeBorder(Palette.accent, lineWidth: 2.5) }
                    }
                    .frame(maxWidth: 64)
                Text(choice.title)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? Color.primary : unselected)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(choice.title)
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(choice.accessibilityIdentifier)
    }
}
