import SwiftUI

/// Flutter `SettingsStorageTab`, cut to what this app has (D65): clearing the artwork cache and all
/// caches, and C10's two download rows. Flutter's cache switches did nothing, its song cache is
/// always empty here, and its other download rows, local music and BPM sections are left out. C37 adds
/// Smart Downloads first, where Flutter's hidden "Auto Download Favorites" was (D144).
struct StorageSettingsPage: View {
    @Environment(DownloadModel.self) private var downloads
    @Environment(SmartDownloads.self) private var smartDownloads
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.openLibraryRoute) private var openRoute

    @State private var artworkSize: Int64 = 0
    @State private var totalSize: Int64 = 0
    @State private var downloadsSize: Int64 = 0
    @State private var asksToDeleteDownloads = false
    /// The switch-on question (D144): how many songs, and about how much space.
    @State private var smartPlan: SmartDownloads.Plan?

    var body: some View {
        VStack(spacing: 24) {
            SettingsSection(title: "CACHE") {
                SettingsRow(title: "Artwork Cache", subtitle: "\(SettingsFormat.bytes(artworkSize)) used on disk") {
                    SettingsGlyph("photo.stack", colors: gradient(0xFF9500, 0xFFCC00))
                } trailing: {
                    Button("Clear image cache", systemImage: "xmark.bin") { clearArtwork() }
                        .labelStyle(.iconOnly)
                        .font(.system(size: 18))
                        .foregroundStyle(Color(hex: 0xFF3B30))
                        .frame(width: 40, height: 40)
                        .contentShape(.rect)
                        .buttonStyle(.plain)
                }
                SettingsRule()
                SettingsRow(title: "Clear All Cache", subtitle: "Total cache: \(SettingsFormat.bytes(totalSize))", action: clearAll) {
                    SettingsGlyph("xmark.bin.fill", colors: gradient(0xFF3B30, 0xFF453A))
                }
                .accessibilityIdentifier("clearAllCache")
            }
            SettingsSection(title: "DOWNLOADS") {
                SettingsSwitchRow(
                    title: "Smart Downloads",
                    subtitle: "Downloads your favorite songs and albums on Wi-Fi and keeps downloaded playlists up to date. Songs you unfavorite are removed.",
                    isOn: Binding(get: { smartDownloads.isEnabled }, set: { setSmartDownloads($0) }),
                    identifier: "smartDownloadsSwitch"
                ) {
                    SettingsGlyph("arrow.down.heart.fill", colors: gradient(0xE91E63, 0xF06292))
                }
                // Turning it on asks the server what it would download; off works offline too.
                .disabled(smartDownloads.isPreparing || (!smartDownloads.isEnabled && downloads.activeClient == nil))
                SettingsRule()
                SettingsRow(
                    title: "Playlist Downloads",
                    subtitle: SettingsFormat.songsDownloaded(downloads.downloadedIDs.count),
                    action: { openRoute(.playlistDownloads) }
                ) {
                    SettingsGlyph("arrow.down.circle.fill", colors: gradient(0x5856D6, 0x7B68EE))
                } trailing: {
                    chevron
                }
                .accessibilityIdentifier("playlistDownloadsRow")
                SettingsRule()
                SettingsRow(
                    title: "Delete All Downloads",
                    subtitle: "\(CountText.of(downloads.downloadedIDs.count, "song")) • \(SettingsFormat.bytes(downloadsSize))",
                    action: { asksToDeleteDownloads = true }
                ) {
                    SettingsGlyph("externaldrive.badge.minus", colors: gradient(0xFF3B30, 0xFF453A))
                }
                .disabled(downloads.downloadedIDs.isEmpty && downloads.records.queue.isEmpty)
                .accessibilityIdentifier("deleteAllDownloadsRow")
            }
        }
        .task { await measureCaches() }
        .task(id: downloads.downloadedIDs.count) {
            let size = await downloads.totalSize()
            if !Task.isCancelled { downloadsSize = size }
        }
        .alert(
            "Turn On Smart Downloads?",
            isPresented: Binding(get: { smartPlan != nil }, set: { if !$0 { smartPlan = nil } }),
            presenting: smartPlan
        ) { plan in
            Button("Cancel", role: .cancel) {}
            Button("Turn On") { smartDownloads.turnOn(with: plan) }
        } message: { plan in
            Text(Self.smartQuestion(plan))
        }
        // Cancel in the normal colour, not the accent (C66).
        .neutralAlert("Delete All Downloads", isPresented: $asksToDeleteDownloads) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                downloads.removeAll()
                toasts.show("All downloads deleted")
            }
        } message: {
            Text("Delete every downloaded song from this phone? They stay on the server.")
        }
    }

    private func setSmartDownloads(_ isOn: Bool) {
        guard isOn else {
            smartDownloads.turnOff()
            return
        }
        Task {
            guard let plan = await smartDownloads.prepare() else {
                toasts.show("Couldn't reach the server")
                return
            }
            // Nothing to download yet: nothing to ask.
            if plan.songCount == 0 {
                smartDownloads.turnOn(with: plan)
            } else {
                smartPlan = plan
            }
        }
    }

    /// `server`: named when the question comes by itself for a server just added (C47).
    static func smartQuestion(_ plan: SmartDownloads.Plan, server: String? = nil) -> String {
        let songs = plan.songCount == 1 ? "1 song" : "\(plan.songCount) songs"
        let size = plan.bytes > 0 ? " (about \(SettingsFormat.bytes(plan.bytes)))" : ""
        let start = server.map { "On \($0), this" } ?? "This"
        return "\(start) downloads \(songs)\(size) on Wi-Fi, and more as you add favorites."
    }

    private var chevron: some View {
        Image(systemName: "chevron.forward")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Palette.secondaryText)
    }

    /// The artwork cache, plus the system's shared web cache for "all" (Flutter: songs, images, BPMs).
    private func measureCaches() async {
        artworkSize = ArtworkCache.shared.diskUsage
        totalSize = artworkSize + Int64(URLCache.shared.currentDiskUsage)
    }

    private func clearArtwork() {
        ArtworkCache.shared.clear()
        toasts.show("Artwork cache cleared")
        Task { await measureCaches() }
    }

    private func clearAll() {
        ArtworkCache.shared.clear()
        URLCache.shared.removeAllCachedResponses()
        toasts.show("All cache cleared")
        Task { await measureCaches() }
    }
}
