import HubKit
import PlaybackKit
import SwiftUI
import SubsonicKit
import SharedKit

@main
struct NavinxApp: App {
    @UIApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var account: AccountModel
    @State private var toasts: ToastCenter
    @State private var player: PlayerModel
    /// The lock screen and the audio session. Nothing reads it; it lives as long as the app.
    @State private var systemMedia: SystemMediaBridge
    @State private var recommendations: RecommendationModel
    @State private var downloads: DownloadModel
    /// Settings → Storage's Smart Downloads (C37).
    @State private var smartDownloads: SmartDownloads
    @State private var appearance: AppearanceModel
    /// Wi-Fi or mobile data, for the streaming quality. Nothing reads it; it lives as long as the app.
    @State private var network: NetworkMonitor
    /// The equalizer bars' levels for the queue's next songs (C20). Nothing reads it but the bars.
    @State private var levels: LevelPreloader
    /// Pages asked from Spotlight, Siri, Shortcuts, quick actions and links (C39).
    @State private var navigator = AppNavigator.shared

    init() {
        #if DEBUG
        let account = UITestHooks.makeAccountModel() ?? AccountModel(devices: .live)
        #else
        let account = AccountModel(devices: .live)
        #endif
        let player = PlayerModel()
        let recommendations = RecommendationModel()
        let downloads = DownloadModel()
        let toasts = ToastCenter()
        // After the test hooks, which may reset its switch.
        let smartDownloads = SmartDownloads(downloads: downloads)
        player.onListen = {
            recommendations.handle($0)
            smartDownloads.handle($0)
        }
        player.localFile = { downloads.localFile(for: $0) }
        player.offlineSongs = { downloads.offlineSongs }
        player.favouriteGenres = { recommendations.data.topGenres($0) }
        downloads.onMessage = { toasts.show($0) }
        // A removed file lined up as the next song: lined up again from the server (or not, offline).
        downloads.onFilesRemoved = { player.refreshTranscoding() }
        player.onQueueTaken = { toasts.show("Picked up from another device") }
        account.hasDownloads = { DownloadModel.hasDownloads(profileID: $0) }
        account.removeDownloads = { id in
            if downloads.profileID == id { downloads.removeAll() }
            DownloadModel.removeDownloads(profileID: id)
        }
        // Keychain items an earlier build left under another service, removed on every launch (D116).
        KeychainTidy.run()
        BackgroundDownloader.shared.start()
        // After the test hooks, which may reset its keys.
        _appearance = State(initialValue: AppearanceModel.shared)
        let network = NetworkMonitor()
        player.isOnMobileData = { network.isOnMobileData }
        network.onChange = { player.refreshTranscoding() }
        // Leaving home Wi-Fi with the app open: off the LAN address that no longer answers.
        network.onPathChange = { account.networkChanged() }
        // Smart Downloads (C37): Wi-Fi only, after the user's own downloads, a catch-up at every connection.
        smartDownloads.allowsNetwork = { network.allowsAutomaticDownloads }
        smartDownloads.currentSongID = { player.currentSong?.id }
        downloads.allowsAutomatic = { smartDownloads.mayDownload }
        downloads.keepsAutomatic = { smartDownloads.isEnabled }
        downloads.onConnect = { smartDownloads.connected() }
        downloads.onProfileChange = { smartDownloads.serverChanged() }
        downloads.onPlaylistChanged = { smartDownloads.playlistChanged(songs: $0, old: $1) }
        network.onAutomaticDownloadsChange = { smartDownloads.networkChanged() }
        account.onMessage = { toasts.show($0) }
        // The hub's session ends with the sign-in; a profile's key id goes with the profile.
        account.onSignOut = { Task { await HubSessions.shared.dropAll() } }
        account.forgetKey = { AppKey.forget(profileID: $0) }
        network.start()
        _network = State(initialValue: network)
        _downloads = State(initialValue: downloads)
        _smartDownloads = State(initialValue: smartDownloads)
        _toasts = State(initialValue: toasts)
        _recommendations = State(initialValue: recommendations)
        _account = State(initialValue: account)
        _player = State(initialValue: player)
        _levels = State(initialValue: LevelPreloader(
            player: player, client: { account.client }, profile: { account.active?.id }
        ))
        _systemMedia = State(initialValue: SystemMediaBridge.forApp(player: player, account: account))
        // The Home Screen widgets' snapshot (C40), after the bridge: it chains the player's hook.
        WidgetSnapshotWriter(player: player, account: account)?.install()
        // Siri, Shortcuts, Spotlight and the icon's quick actions reach these same models, with or without
        // a window (C39): registered before anything can run an intent.
        IntentServices(
            account: account, player: player, downloads: downloads, toasts: toasts, navigator: AppNavigator.shared
        ).register()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                #if DEBUG
                .background { UITestOrientation() }
                #endif
                .environment(account)
                .environment(toasts)
                .environment(player)
                .environment(recommendations)
                .environment(downloads)
                .environment(smartDownloads)
                .environment(appearance)
                .environment(network)
                .environment(navigator)
                .environment(\.levelMeter, levels.meter)
                .appAppearance(appearance)
                // Tried on every return to the app until iOS takes it (C54 part 4).
                .task(id: scenePhase) {
                    if scenePhase == .active { await AppIconModel.shared.retireRemovedIcon() }
                }
        }
    }
}

#if DEBUG
/// Launch arguments for `NavinxUITests` only (debug builds):
/// - `-UITestReset`: start signed out with no saved servers or downloads, Settings' choices at
///   their defaults, and no equalizer levels kept (C20).
/// - `-UITestUnreachable`: every request fails as "cannot connect", after 1.5 s, so the
///   connecting and unreachable screens can be shown without taking the server down.
/// - `-UITestOpenPlayer`: now playing opens once the mini-player has its song (C30: pictures of the
///   Duo's displays, where XCUITest's own pictures come out black). `-UITestPlayerCycle`: it opens, closes,
///   opens and closes again, 3 s apart, for films of the motion.
/// - `-UITestFakeTranslation`: lyrics are "translated" by a stand-in into French, on from the start
///   (C38: the simulator can't translate); `-UITestLyricsPage`: now playing opens on its lyrics page.
/// - `-UITestDuoFoldCycle`: on a display with the Duo's side rail, the mini-player folds, unfolds, folds
///   and unfolds, 3 s apart, as a page scrolled down and back would (C30 bug 19's films).
enum UITestHooks {
    @MainActor
    static func foldIfAsked(player: PlayerModel, chrome: DuoChrome) async {
        guard ProcessInfo.processInfo.arguments.contains("-UITestDuoFoldCycle") else { return }
        while player.currentSong == nil {
            try? await Task.sleep(for: .milliseconds(200))
            if Task.isCancelled { return }
        }
        for step in 0..<4 {
            try? await Task.sleep(for: .seconds(step == 0 ? 2 : 3))
            if step.isMultiple(of: 2) { chrome.fold() } else { chrome.unfold() }
        }
    }

    @MainActor
    static func openPlayerIfAsked(player: PlayerModel, nowPlaying: PlayerOpening) async {
        let arguments = ProcessInfo.processInfo.arguments
        let cycles = arguments.contains("-UITestPlayerCycle")
        guard cycles || arguments.contains("-UITestOpenPlayer") else { return }
        while player.currentSong == nil {
            try? await Task.sleep(for: .milliseconds(200))
            if Task.isCancelled { return }
        }
        try? await Task.sleep(for: .seconds(2))
        nowPlaying.open()
        guard cycles else { return }
        for step in 0..<3 {
            try? await Task.sleep(for: .seconds(3))
            if step.isMultiple(of: 2) { nowPlaying.close() } else { nowPlaying.open() }
        }
    }

    /// `-UITestOpenLink <navinx://…>`: the link is handled as if opened, once signed in (C39's look; the
    /// system asks "Open in Navinx?" for `simctl openurl`, and nothing here can answer it).
    @MainActor
    static func openLinkIfAsked(account: AccountModel, navigator: AppNavigator) async {
        guard let text = UserDefaults.standard.string(forKey: "UITestOpenLink"), let url = URL(string: text),
              let destination = NavinxLink.destination(from: url) else { return }
        while account.state != .authenticated && account.state != .offlineMode {
            try? await Task.sleep(for: .milliseconds(200))
            if Task.isCancelled { return }
        }
        navigator.open(destination)
    }

    static func makeAccountModel() -> AccountModel? {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-UITestReset") || arguments.contains("-UITestUnreachable") else { return nil }
        let store = ProfileStore()
        if arguments.contains("-UITestReset") {
            store.clearActive()
            store.savedProfiles.forEach(store.delete)
            DownloadStore.removeEverything()
            WidgetStore.shared?.clear()
            resetSettings()
            KeychainTidy.run()
            try? FileManager.default.removeItem(at: URL.cachesDirectory.appending(path: "Levels"))
        }
        guard arguments.contains("-UITestUnreachable") else { return AccountModel(store: store, devices: .live) }
        return AccountModel(store: store, transport: UnreachableTransport())
    }

    /// Settings' own choices back to their defaults (C11), so every walk starts from the same place.
    private static func resetSettings() {
        let keys = [
            ReplayGainSettings.modeKey, ReplayGainSettings.preampKey, ReplayGainSettings.preventsClippingKey,
            ReplayGainSettings.fallbackKey, TranscodingSettings.enabledKey, TranscodingSettings.wifiBitRateKey,
            TranscodingSettings.mobileBitRateKey, TranscodingSettings.formatKey, AppearanceModel.themeKey,
            AppearanceModel.accentKey, PinnedPlaylistsModel.showOnHomeKey,
            CrossfadeSettings.secondsKey, FadeSettings.enabledKey, FadeSettings.durationKey,
            RefillSettings.modeKey, RefillSettings.refillCountKey, RefillSettings.lastModeKey,
            PlayerDisplayOptions.showsRatingStars, SmartDownloads.enabledKey, SmartDownloads.answersKey,
            LyricsSettings.translate,
        ]
        keys.forEach(UserDefaults.standard.removeObject)
    }

    struct UnreachableTransport: HTTPTransport {
        func get(_ url: URL, timeout: TimeInterval) async throws -> (Data, HTTPURLResponse) {
            try await Task.sleep(for: .seconds(1.5))
            throw URLError(.cannotConnectToHost)
        }
    }
}
#endif
