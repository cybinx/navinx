import SwiftUI

/// Flutter `SettingsServerTab`: the active server's card, the saved servers, and Sign Out. Music
/// folders and jukebox mode are left out (D63). "Switch" and "Manage" open the server switcher, a
/// sheet as before; it no longer has a Settings row, since it opens from here (D14).
struct ServerSettingsPage: View {
    @Environment(AccountModel.self) private var account
    @Environment(\.openLibraryRoute) private var openRoute

    @State private var showsSwitcher = false
    @State private var confirmingLogout = false

    var body: some View {
        VStack(spacing: 24) {
            ActiveServerCard(onSwitch: { showsSwitcher = true })
            savedServers
            SettingsSection(title: "ACCOUNT") {
                SettingsRow(title: "Sign Out", titleColor: Color(hex: 0xFF3B30), action: { confirmingLogout = true }) {
                    SettingsGlyph("person.crop.circle.badge.xmark", colors: gradient(0xFF3B30, 0xFF453A))
                }
                .accessibilityIdentifier("settingsLogout")
            }
        }
        .sheet(isPresented: $showsSwitcher) {
            ServerPickerSheet(onAddServer: { openRoute(.addServer) })
        }
        .signOutAlert(isPresented: $confirmingLogout)
    }

    /// Flutter `_buildSavedServersSection`: a header with "Manage", then every server, then Add.
    private var savedServers: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("SAVED SERVERS")
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(Palette.secondaryText)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                Button("Manage") { showsSwitcher = true }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.accent)
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("settingsManageServers")
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            VStack(spacing: 0) {
                let profiles = account.switcherProfiles
                ForEach(profiles) { profile in
                    SavedServerRow(profile: profile, isActive: profile.id == account.active?.id)
                    if profile.id != profiles.last?.id { SettingsRule(indent: 0) }
                }
                SettingsRule(indent: 0)
                Button {
                    openRoute(.addServer)
                } label: {
                    HStack(spacing: 16) {
                        Image(systemName: "plus")
                            .font(.system(size: 22))
                            .frame(width: 34)
                        Text("Add Server")
                            .font(.system(size: 14, weight: .semibold))
                        Spacer()
                        Image(systemName: "chevron.forward")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Palette.secondaryText)
                    }
                    .foregroundStyle(Palette.accent)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 52)
                    .contentShape(.rect)
                }
                .buttonStyle(SettingsRowButtonStyle())
                .disabled(!account.canAddServer)
                .opacity(account.canAddServer ? 1 : 0.4)
                .accessibilityIdentifier("settingsAddServer")
            }
            .background(Palette.surface)
            .clipShape(.rect(cornerRadius: 14))
            .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(Palette.hairline) }
            .padding(.horizontal, 16)
            if !account.canAddServer {
                Text(AccountModel.limitMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.secondaryText)
                    .padding(.horizontal, 32)
                    .padding(.top, 6)
                    .accessibilityIdentifier("settingsServerLimit")
            }
        }
    }
}

/// Flutter `_buildActiveServerCard`.
private struct ActiveServerCard: View {
    let onSwitch: () -> Void

    @Environment(AccountModel.self) private var account
    @Environment(\.colorScheme) private var colorScheme

    private enum Status {
        case connected, connecting, offline

        var title: String {
            switch self {
            case .connected: "CONNECTED"
            case .connecting: "CONNECTING"
            case .offline: "OFFLINE"
            }
        }

        var color: Color { self == .connected ? Palette.green : Palette.orange }
    }

    private var status: Status {
        switch account.state {
        case .authenticated: .connected
        case .authenticating: .connecting
        default: .offline
        }
    }

    var body: some View {
        let profile = account.active
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 14)
                    .fill(Palette.serverGradient)
                    .frame(width: 48, height: 48)
                    .overlay {
                        Image(systemName: "server.rack")
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(.white)
                    }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(profile?.shownServerName ?? "Navidrome / Subsonic")
                            .font(.system(size: 17, weight: .bold))
                            .lineLimit(1)
                        badge
                    }
                    Text(profile?.displayURL ?? "Not Connected")
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.secondaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Button(action: onSwitch) {
                    Label("Switch", systemImage: "arrow.left.arrow.right")
                        .font(.system(size: 14, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(Palette.accent)
                .accessibilityIdentifier("settingsSwitchServer")
            }
            .padding(16)

            if let profile {
                Rectangle().fill(Palette.divider).frame(height: 0.5)
                HStack(spacing: 6) {
                    detail("person.crop.circle", profile.username, size: 12, weight: .medium, strong: true)
                    if let lan = profile.homeNetworkURL, !lan.isEmpty {
                        Spacer(minLength: 8)
                        detail("house", "LAN: \(lan)", size: 11)
                    }
                    if let version = profile.serverVersion, !version.isEmpty {
                        Spacer(minLength: 8)
                        detail("number", "v\(version)", size: 12)
                            .layoutPriority(1)
                    }
                    if profile.homeNetworkURL?.isEmpty ?? true, profile.serverVersion?.isEmpty ?? true {
                        Spacer(minLength: 0)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
        }
        .background(Palette.surface, in: .rect(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(Palette.hairline) }
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.2 : 0.04), radius: 5, y: 3)
        .padding(.horizontal, 16)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("activeServerCard")
    }

    private var badge: some View {
        HStack(spacing: 4) {
            Circle().fill(status.color).frame(width: 6, height: 6)
            Text(status.title)
                .font(.system(size: 9, weight: .bold))
                .tracking(0.3)
                .foregroundStyle(status.color)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(status.color.opacity(0.15), in: .rect(cornerRadius: 6))
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("serverStatus")
    }

    private func detail(_ systemImage: String, _ text: String, size: CGFloat, weight: Font.Weight = .regular, strong: Bool = false) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 12))
                .foregroundStyle(.primary.opacity(0.45))
            Text(text)
                .font(.system(size: size, weight: weight))
                .foregroundStyle(.primary.opacity(strong ? 0.8 : 0.5))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

/// One saved server: tap another to switch to it (Flutter: stop, switch, refresh).
private struct SavedServerRow: View {
    let profile: ServerProfile
    let isActive: Bool

    @Environment(AccountModel.self) private var account

    var body: some View {
        Button {
            guard !isActive else { return }
            let account = account
            Task { await account.switchTo(profile) }
        } label: {
            HStack(spacing: 16) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(LinearGradient(colors: gradient(0x6366F1, 0x8B5CF6), startPoint: .leading, endPoint: .trailing))
                    .frame(width: 34, height: 34)
                    .overlay {
                        Image(systemName: "server.rack")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.white)
                    }
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.shownServerName)
                        .font(.system(size: 15, weight: isActive ? .bold : .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(profile.displayURL)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.secondaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if isActive {
                    Text("ACTIVE")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Palette.green)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Palette.green.opacity(0.15), in: .rect(cornerRadius: 8))
                } else {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 15))
                        .foregroundStyle(.primary.opacity(0.38))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .contentShape(.rect)
        }
        .buttonStyle(SettingsRowButtonStyle())
        .accessibilityIdentifier("savedServer-\(profile.shownServerName)")
    }
}
