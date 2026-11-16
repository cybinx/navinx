import PlaybackKit
import SubsonicKit
import SwiftUI
import SharedKit

/// Shows the screen for the connection state: Flutter `AuthWrapper` (`lib/main.dart`). Upstream
/// Musly's welcome tour, privacy dialog and update check are dropped (Scope).
struct RootView: View {
    @Environment(AccountModel.self) private var account
    @Environment(ToastCenter.self) private var toasts
    @Environment(PlayerModel.self) private var player
    @Environment(DownloadModel.self) private var downloads
    @Environment(SmartDownloads.self) private var smartDownloads
    @Environment(AppNavigator.self) private var navigator
    @Environment(\.scenePhase) private var scenePhase
    /// Set on the way to the background, so only a real return looks at the server's queue (C36),
    /// not Control Center or a notification pulled down.
    @State private var wasInBackground = false

    private enum Screen { case loading, login, connecting, unreachable, app }

    /// One screen per case, so the login form keeps what was typed while it logs in.
    private var screen: Screen {
        switch account.state {
        case .unknown: .loading
        case .authenticated, .offlineMode: .app
        case .serverUnreachable: .unreachable
        case .authenticating: account.active == nil ? .login : .connecting
        case .unauthenticated, .error: .login
        }
    }

    /// What the player and downloads follow (C39: shared with Siri and Shortcuts, `PlaybackConnection`).
    private var connection: PlaybackConnection { PlaybackConnection(account) }

    var body: some View {
        ZStack {
            switch screen {
            case .loading: LoadingView()
            case .login: LoginView()
            case .connecting: ConnectingView()
            case .unreachable: ServerUnreachableView()
            case .app:
                // Flutter's column: the banner, then the app below it.
                VStack(spacing: 0) {
                    if account.isOffline { OfflineBanner() }
                    // Made again for another account, also one Edit Server put under the same profile.
                    MainTabView().id(account.active?.accountKey)
                }
            }
            // A server that approves each device and hasn't approved this one (C45): over everything, so
            // the screen below (a half-typed login, the app) is there again when it goes.
            if let flow = account.approval {
                DeviceApprovalView(flow: flow)
                    .transition(.opacity)
            }
        }
        .animation(.snappy, value: account.approval?.id)
        .overlay(alignment: .bottom) {
            // The tabs show their own, just above the mini-player or the bar (`showsToasts`, C65).
            if screen != .app, let toast = toasts.current {
                ToastView(toast: toast)
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: toasts.current)
        .task { await account.start() }
        // One handler, so the old server's reset always comes before the new one's connect: Add
        // Server changes the server and the client while the state stays signed in.
        .onChange(of: connection, initial: true) { old, new in
            PlaybackConnection.apply(
                from: old, to: new, windowless: false, account: account, player: player, downloads: downloads
            )
        }
        // A `navinx://` link (C39): only pages open, nothing plays. Signed out, it's dropped. One that
        // started the app (a widget's tap) comes while the saved login is still being read: it's kept,
        // and opens once the tabs are up (C47, the check's D2).
        .onOpenURL { url in
            guard account.storedProfileID != nil, let destination = NavinxLink.destination(from: url) else { return }
            navigator.open(destination)
        }
        // Smart Downloads' question for a server not answered for yet (C47, D164).
        .alert(
            "Turn On Smart Downloads?",
            isPresented: Binding(get: { smartDownloads.question != nil }, set: { _ in }),
            presenting: smartDownloads.question
        ) { plan in
            Button("Not Now", role: .cancel) { smartDownloads.decline(plan) }
            Button("Turn On") { smartDownloads.turnOn(with: plan) }
        } message: { plan in
            Text(StorageSettingsPage.smartQuestion(plan, server: account.active?.shownServerName))
        }
        #if DEBUG
        .task { await UITestHooks.openLinkIfAsked(account: account, navigator: navigator) }
        #endif
        .onChange(of: scenePhase) {
            if scenePhase != .active {
                player.saveNow()
                downloads.saveNow()
            }
            if scenePhase == .background { wasInBackground = true }
            // Back from the background: another device may have played meanwhile (C36).
            if scenePhase == .active, wasInBackground {
                wasInBackground = false
                player.checkServerQueue()
                // Favourites changed elsewhere (C37): at most every 15 minutes.
                smartDownloads.returnedToForeground()
            }
        }
    }
}

/// Before the saved login is read (Flutter: black with a spinner).
private struct LoadingView: View {
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ProgressView().controlSize(.large).tint(Palette.accent)
        }
    }
}

/// Checking the saved server (Flutter `_AuthenticatingScreen`). After 5 seconds it says it's slow;
/// Flutter's text there is Italian ("La connessione ci sta mettendo un po'..."), English here (D6).
private struct ConnectingView: View {
    @Environment(AccountModel.self) private var account
    @State private var isSlow = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                ProgressView().controlSize(.large).tint(Palette.accent)
                if isSlow {
                    Text("The connection is taking a while...")
                        .font(.system(size: 15))
                        .foregroundStyle(.gray)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                        .padding(.top, 32)
                    if account.hasAnythingOffline {
                        Button("Open in offline mode", systemImage: "checkmark.circle") {
                            account.switchToOffline()
                        }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                        .padding(.top, 24)
                    }
                }
            }
        }
        .task {
            try? await Task.sleep(for: .seconds(5))
            isSlow = true
        }
    }
}

/// Flutter's orange offline banner (`main_screen.dart`), above everything, with the app below it.
private struct OfflineBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.slash").font(.system(size: 16))
            Text("Offline Mode – Playing downloaded music only")
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(.white)
        .padding(.vertical, 8)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
        .background(Color(hex: 0xFF9800).ignoresSafeArea(edges: .top))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("offlineBanner")
    }
}

/// The saved server didn't answer (Flutter `_ServerUnreachableScreen`). "Disconnect" signs out
/// and keeps the saved servers and this server's downloads (D58).
private struct ServerUnreachableView: View {
    @Environment(AccountModel.self) private var account
    @State private var choosingServer = false
    @State private var editing: ServerProfile?

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 72))
                .foregroundStyle(.gray)
            Text("Cannot reach server")
                .font(.system(size: 20, weight: .semibold))
                .multilineTextAlignment(.center)
                .padding(.top, 24)
            Text("Check your connection or server settings.")
                .foregroundStyle(.gray)
                .multilineTextAlignment(.center)
                .padding(.top, 8)

            VStack(spacing: 12) {
                Button {
                    Task { await account.retry() }
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("retry")

                // The server may have moved: its address, filled in, to change (D139).
                if let active = account.active {
                    Button {
                        editing = active
                    } label: {
                        Label("Edit Server", systemImage: "square.and.pencil").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("editServer")
                }

                if !account.otherProfiles.isEmpty {
                    Button {
                        choosingServer = true
                    } label: {
                        Label("Switch Server", systemImage: "arrow.left.arrow.right").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }

                if account.hasAnythingOffline {
                    Button {
                        account.switchToOffline()
                    } label: {
                        Label("Open in offline mode", systemImage: "checkmark.circle").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }

                Button {
                    account.disconnect()
                } label: {
                    Label("Disconnect", systemImage: "rectangle.portrait.and.arrow.right").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("disconnect")
            }
            .controlSize(.large)
            .buttonBorderShape(.capsule)
            .padding(.top, 32)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.background)
        .sheet(isPresented: $choosingServer) {
            SwitchProfileSheet()
        }
        .sheet(item: $editing) { profile in
            EditServerSheet(profile: profile)
        }
    }
}

/// The unreachable screen's list of the other saved logins (Flutter `_showSwitchProfileDialog`).
private struct SwitchProfileSheet: View {
    @Environment(AccountModel.self) private var account
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Text("Switch Server")
                .font(.system(size: 18, weight: .bold))
                .padding(.top, 24)
                .padding(.bottom, 8)
            List(account.otherProfiles) { profile in
                Button {
                    dismiss()
                    Task { await account.switchTo(profile) }
                } label: {
                    HStack(spacing: 16) {
                        Image(systemName: "person").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile.chipLabel)
                            Text(profile.serverURL)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.clear)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}
