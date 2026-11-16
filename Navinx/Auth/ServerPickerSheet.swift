import SwiftUI

/// Switch, add, rename and remove servers, sign out: Flutter `ServerSwitcherSheet`
/// (`lib/widgets/modals/server_switcher_sheet.dart`), a system sheet (glass) in place of
/// Flutter's `GlassSheetPanel`. The ⋯ menu is a system `Menu` (glass).
struct ServerPickerSheet: View {
    @Environment(AccountModel.self) private var account
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.dismiss) private var dismiss

    /// Opens Add Server (Flutter pops the sheet, then pushes the page).
    let onAddServer: () -> Void

    @State private var switchingID: ServerProfile.ID?
    @State private var renaming: ServerProfile?
    @State private var editing: ServerProfile?
    @State private var newName = ""
    @State private var removing: ServerProfile?
    @State private var confirmingLogout = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    let profiles = account.switcherProfiles
                    if profiles.isEmpty {
                        Text("No servers saved yet")
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 24)
                    }
                    ForEach(profiles) { profile in
                        ServerCard(
                            profile: profile,
                            isActive: profile.id == account.active?.id,
                            isSwitching: switchingID == profile.id,
                            onTap: { switchTo(profile) },
                            onRename: {
                                newName = profile.name ?? profile.shownServerName
                                renaming = profile
                            },
                            onEdit: { editing = profile },
                            onRemove: { removing = profile }
                        )
                        .padding(.bottom, 10)
                    }
                    if !account.canAddServer {
                        Text(AccountModel.limitMessage)
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.secondaryText)
                            .padding(.top, 4)
                    }
                    // Flutter's "Settings" row goes: the switcher opens from Settings now (D14, D63).
                    Divider().padding(.top, 2).padding(.bottom, 4)
                    row("Sign Out", systemImage: "person.crop.circle.badge.xmark", tint: .red, chevron: false) {
                        confirmingLogout = true
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .alert("Rename Server Profile", isPresented: isPresented($renaming)) {
            TextField("Enter new name", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                let name = newName.trimmingCharacters(in: .whitespaces)
                if let renaming, !name.isEmpty { account.rename(renaming, to: name) }
            }
        }
        .removeServerAlert($removing)
        // Connected with the new details: the switcher goes too, as after Add Server.
        .sheet(item: $editing) { profile in
            EditServerSheet(profile: profile) { dismiss() }
        }
        .signOutAlert(isPresented: $confirmingLogout)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Switch Server")
                    .font(.system(size: 20, weight: .bold))
                Text("Choose a server")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.secondaryText)
            }
            Spacer(minLength: 0)
            Button {
                dismiss()
                onAddServer()
            } label: {
                Label("Add Server", systemImage: "plus")
                    .font(.system(size: 14, weight: .semibold))
            }
            .buttonStyle(.bordered)
            .tint(Palette.accent)
            .disabled(!account.canAddServer)
            .accessibilityIdentifier("addServer")
        }
        .padding(.leading, 20)
        .padding(.trailing, 16)
        .padding(.top, 24)
        .padding(.bottom, 12)
    }

    private func row(
        _ title: String, systemImage: String, tint: Color, chevron: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: systemImage)
                    .font(.system(size: 18))
                    .frame(width: 22)
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                if chevron {
                    Image(systemName: "chevron.forward")
                        .font(.system(size: 14))
                        .foregroundStyle(Palette.divider)
                }
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 4)
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    /// Flutter `_switchToProfile`. The root then shows the connecting screen, which closes this
    /// sheet, and "Connected to …" once the server answers.
    private func switchTo(_ profile: ServerProfile) {
        guard profile.id != account.active?.id else {
            dismiss()
            return
        }
        switchingID = profile.id
        // `RootView` resets the player (Flutter `resetForServerSwitch`). C3: refresh the library after.
        let account = account
        let toasts = toasts
        Task {
            await account.switchTo(profile)
            if account.state == .authenticated, let active = account.active {
                toasts.show("Connected to \(active.shownServerName)", checkmark: true)
            }
        }
    }

    private func isPresented(_ item: Binding<ServerProfile?>) -> Binding<Bool> {
        Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } })
    }
}

private struct SignOutAlert: ViewModifier {
    @Environment(AccountModel.self) private var account
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        content.neutralAlert("Sign Out", isPresented: $isPresented) {
            Button("Cancel", role: .cancel) {}
            Button("Sign Out", role: .destructive) { account.logout() }
        } message: {
            Text(AccountModel.logoutQuestion)
        }
    }
}

/// "Remove Server", asked before a saved server goes: from the switcher and the login screen's chips.
/// It says when the server's downloads go too, and when it's the one signed in to (`AccountModel.delete`, D213).
private struct RemoveServerAlert: ViewModifier {
    @Environment(AccountModel.self) private var account
    @Binding var removing: ServerProfile?

    func body(content: Content) -> some View {
        let item = $removing
        let isPresented = Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } })
        // On a view of its own, so the neutral tint reaches only the alert (D213).
        content.background {
            Color.clear
                .alert("Remove Server", isPresented: isPresented, presenting: removing) { profile in
                    Button("Cancel", role: .cancel) {}
                    Button("Remove", role: .destructive) { account.delete(profile) }
                } message: { profile in
                    let signOut = account.deleteSignsOut(profile) ? " You'll be signed out of it." : ""
                    let downloads = account.deleteRemovesDownloads(profile) ? " This will also remove its downloads." : ""
                    Text("Are you sure you want to remove \"\(profile.shownServerName)\" from your saved servers?\(signOut)\(downloads)")
                }
                .tint(.primary)
        }
    }
}

extension View {
    /// "Sign Out", from the switcher and Settings → Servers, with Cancel in the normal colour (C66).
    func signOutAlert(isPresented: Binding<Bool>) -> some View {
        modifier(SignOutAlert(isPresented: isPresented))
    }

    func removeServerAlert(_ removing: Binding<ServerProfile?>) -> some View {
        modifier(RemoveServerAlert(removing: removing))
    }
}

/// One server in the switcher (Flutter `_buildServerCard`).
private struct ServerCard: View {
    let profile: ServerProfile
    let isActive: Bool
    let isSwitching: Bool
    let onTap: () -> Void
    let onRename: () -> Void
    let onEdit: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 12)
                .fill(Palette.serverGradient)
                .frame(width: 44, height: 44)
                .overlay {
                    Image(systemName: "server.rack")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(.white)
                }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(profile.shownServerName)
                        .font(.system(size: 15, weight: isActive ? .bold : .semibold))
                        .lineLimit(1)
                        .accessibilityIdentifier("serverName-\(profile.shownServerName)")
                    if isActive { ActiveBadge() }
                }
                Text("\(profile.username) • \(profile.displayURL)")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if isSwitching {
                ProgressView().frame(width: 24, height: 24)
            } else {
                Menu {
                    if !isActive {
                        Button("Connect to Server", systemImage: "arrow.left.arrow.right", action: onTap)
                    }
                    Button("Edit Server", systemImage: "gearshape", action: onEdit)
                    Button("Rename Profile", systemImage: "character.cursor.ibeam", action: onRename)
                    Button("Remove", systemImage: "minus.circle", role: .destructive, action: onRemove)
                } label: {
                    Image(systemName: "ellipsis")
                        .rotationEffect(.degrees(90))
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                        .contentShape(.rect)
                }
                .tint(.secondary)
                .accessibilityLabel("More for \(profile.shownServerName)")
            }
        }
        .padding(14)
        .background(isActive ? activeFill : inactiveFill, in: .rect(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(isActive ? Palette.accent.opacity(0.6) : Palette.hairline, lineWidth: isActive ? 1.5 : 1)
        }
        .shadow(color: isActive ? Palette.accent.opacity(0.12) : .clear, radius: 5, y: 3)
        .contentShape(.rect(cornerRadius: 16))
        .onTapGesture { if !isSwitching { onTap() } }
    }

    private var activeFill: Color { Color(light: 0xFFFFFF, dark: 0x282828) }
    private var inactiveFill: Color { Color(light: 0xF9FAFB, dark: 0x121212) }
}

/// The green "ACTIVE" tag.
private struct ActiveBadge: View {
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(Palette.green).frame(width: 6, height: 6)
            Text("ACTIVE")
                .font(.system(size: 10, weight: .bold))
                .tracking(0.4)
                .foregroundStyle(Palette.green)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Palette.green.opacity(0.15), in: .rect(cornerRadius: 6))
    }
}
