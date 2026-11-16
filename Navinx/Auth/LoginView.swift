import SwiftUI

/// The sign-in screen when nobody is signed in: Flutter `LoginScreen`
/// (`lib/screens/auth/login_screen.dart`). Differences, each the user's call or a decision:
/// no "Music Source" picker (Subsonic only, D4); no certificate options or their hints (D11), so
/// "Advanced Options" holds only the profile name; the title is "Navinx" (Flutter shows "Musly").
///
/// The same screen edits a saved login (D139, the user: "the exact same screen … with all the same
/// info"): Edit Server opens it filled in with `editing`, and a login whose password was refused or is
/// missing comes back to it filled in the same way. Connecting keeps it that profile, whatever was changed.
struct LoginView: View {
    @Environment(AccountModel.self) private var account
    @Environment(ToastCenter.self) private var toasts

    /// The saved login being edited (Edit Server), or nil for the sign-in screen.
    var editing: ServerProfile?
    /// Called once an edited login has connected.
    var onEdited: () -> Void = {}

    private enum Field: Hashable { case server, username, password, profileName }

    @State private var serverURL = ""
    @State private var username = ""
    @State private var password = ""
    @State private var profileName = ""
    @State private var sendsPlainPassword = false
    @State private var showsMoreOptions = false
    @State private var fieldErrors: [Field: String] = [:]
    @State private var failureMessage: String?
    @State private var isConnecting = false
    @FocusState private var focus: Field?

    /// Editing, the state can stay signed in while the new details are checked, so the screen keeps its own.
    private var isLoading: Bool { editing == nil ? account.state == .authenticating : isConnecting }

    /// Flutter `_buildErrorCard`: its own error, else the provider's after a failed login.
    private var shownError: String? {
        if editing != nil { return failureMessage }
        return failureMessage ?? (account.state == .error ? account.error : nil)
    }

    /// The saved login this screen is filled in with: the one being edited, else one whose password was
    /// refused or is missing.
    private var target: ServerProfile? { editing ?? account.prefill }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                logo
                Text("Navinx")
                    .font(.system(size: 34, weight: .bold))
                    .tracking(-0.5)
                    .padding(.top, 32)
                Text("Connect to your Subsonic server")
                    .font(.system(size: 15))
                    .foregroundStyle(Color(hex: 0x8E8E93))
                    .padding(.top, 8)

                // Not while editing: a chip would switch servers from under the edit.
                if editing == nil {
                    SavedProfilesChips()
                        .padding(.top, 24)
                }

                form
                    .padding(.top, 16)
            }
            .frame(maxWidth: 480)
            .padding(32)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.immediately)
        .background(Palette.background)
        .onSubmit(next)
        // Every detail of the saved login, its password too when this device has it (D139).
        .onChange(of: target, initial: true) {
            guard let profile = target else { return }
            serverURL = profile.serverURL
            username = profile.username
            password = account.savedPassword(for: profile) ?? ""
            profileName = profile.name ?? ""
            sendsPlainPassword = profile.sendsPlainPassword
            if !profileName.isEmpty { showsMoreOptions = true }
        }
    }

    /// The plain clef (D187, the user's): black in light, white in dark, in the old 100-pt tile's place.
    private var logo: some View {
        Image("Logo")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .foregroundStyle(.primary)
            .frame(width: 100, height: 100)
            .accessibilityHidden(true)
    }

    private var form: some View {
        VStack(spacing: 0) {
            FormField(
                label: "Server URL", systemImage: "globe", text: $serverURL, field: .server, focus: $focus,
                hint: "https://your-server.com", keyboard: .URL, contentType: .URL, error: fieldErrors[.server]
            )
            if SignInFailure.isPlainHTTPOffNetwork(serverURL) {
                InsecureHTTPWarning().padding(.top, 8)
            }
            FormField(
                label: "Username", systemImage: "person", text: $username, field: .username, focus: $focus,
                error: fieldErrors[.username]
            )
            .padding(.top, 16)
            FormField(
                label: "Password", systemImage: "lock", text: $password, field: .password, focus: $focus,
                isSecure: true, submitLabel: .done, error: fieldErrors[.password]
            )
            .padding(.top, 16)

            switchRow(
                "Legacy Authentication", subtitle: "Use for older Subsonic servers", isOn: $sendsPlainPassword
            )
            .padding(.top, 16)
            // Not in Flutter (C54, the second App Store check): what the switch gives away.
            Text(SignInText.legacyFootnote)
                .font(.system(size: 12))
                .foregroundStyle(Palette.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
                .accessibilityIdentifier("legacyAuthFootnote")

            Button {
                withAnimation(.snappy) { showsMoreOptions.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: showsMoreOptions ? "chevron.down" : "chevron.right")
                        .font(.system(size: 16, weight: .medium))
                        .frame(width: 18)
                    Text("Advanced Options")
                        .font(.system(size: 15, weight: .semibold))
                    Spacer()
                }
                .foregroundStyle(.primary)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .padding(.top, 24)

            if showsMoreOptions {
                FormField(
                    label: "Profile Name (Optional)", systemImage: "tag", text: $profileName,
                    field: .profileName, focus: $focus, hint: "e.g. Home, Work, VPN", submitLabel: .done
                )
                .padding(.top, 16)
            }

            if let shownError {
                SignInFailureCard(message: shownError) {
                    UIPasteboard.general.string = shownError
                    toasts.show("Error copied to clipboard")
                }
                .padding(.top, 24)
            }

            Button(action: login) {
                ZStack {
                    if isLoading {
                        ProgressView().tint(.white)
                    } else {
                        Text("Connect").font(.system(size: 17, weight: .semibold))
                    }
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(Palette.accent.opacity(isLoading ? 0.5 : 1), in: .rect(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .disabled(isLoading)
            .padding(.top, shownError == nil ? 24 : 16)
            .accessibilityIdentifier("connect")

            // Not in Flutter (C54, the second App Store check): help and the policy before signing in.
            if editing == nil { pageLinks.padding(.top, 20) }
        }
        .onChange(of: [serverURL, username, password, profileName]) { failureMessage = nil }
    }

    /// The sign-in screen's Help and Privacy Policy, the pages About's rows open (D181), in the browser.
    private var pageLinks: some View {
        HStack(spacing: 24) {
            pageLink("Help", PublicPages.support, identifier: "signInHelp")
            pageLink("Privacy Policy", PublicPages.privacyPolicy, identifier: "signInPrivacy")
        }
        .frame(maxWidth: .infinity)
    }

    private func pageLink(_ title: String, _ url: URL, identifier: String) -> some View {
        Link(title, destination: url)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Palette.secondaryText)
            .accessibilityIdentifier(identifier)
    }

    /// Flutter puts a `CupertinoSwitch` before the text.
    private func switchRow(_ title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .tint(Palette.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 15))
                Text(subtitle).font(.system(size: 13)).foregroundStyle(Palette.secondaryText)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private func next() {
        switch focus {
        case .server: focus = .username
        case .username: focus = .password
        case .password, .profileName: if !isLoading { login() }
        case nil: break
        }
    }

    /// Flutter `_login` with the form's validators.
    private func login() {
        let url = serverURL.trimmingCharacters(in: .whitespaces)
        let user = username.trimmingCharacters(in: .whitespaces)
        var errors: [Field: String] = [:]
        if url.isEmpty {
            errors[.server] = "Please enter server URL"
        } else if !url.lowercased().hasPrefix("http://") && !url.lowercased().hasPrefix("https://") {
            errors[.server] = "URL must start with http:// or https://"
        }
        if user.isEmpty { errors[.username] = "Please enter username" }
        if password.isEmpty { errors[.password] = "Please enter password" }
        fieldErrors = errors
        guard errors.isEmpty else { return }

        failureMessage = nil
        focus = nil
        let name = profileName.trimmingCharacters(in: .whitespaces)
        let editing = editing
        // A refused login is replaced only at its own address and username; another server or account is a
        // login of its own (item 15).
        let replacing = AccountModel.replaced(editing: editing, prefill: account.prefill, serverURL: url, username: user)
        if editing != nil { isConnecting = true }
        Task {
            let outcome = await account.signIn(
                serverURL: url,
                username: user,
                password: password,
                sendsPlainPassword: sendsPlainPassword,
                profileName: name.isEmpty ? nil : name,
                replacing: replacing
            )
            isConnecting = false
            if case .failed(let message) = outcome {
                failureMessage = message
            } else if outcome == .superseded {
                // Something newer took over: the edit wasn't saved, so it isn't reported as connected (item 16).
            } else if editing != nil, account.approval != nil {
                // The server approves each device: its screens take over (C45).
                onEdited()
            } else if editing != nil, let active = account.active {
                onEdited()
                toasts.show("Connected to \(active.shownServerName)", checkmark: true)
            }
        }
    }
}

/// Flutter's error card: icon, message, copy button and a hint, coloured by the kind of error.
private struct SignInFailureCard: View {
    let message: String
    let copy: () -> Void

    var body: some View {
        let kind = SignInFailure.kind(of: message)
        let color = kind.isRed ? Palette.accentRed : Palette.orange
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: kind.systemImage)
                    .font(.system(size: 18))
                    .foregroundStyle(color)
                    .frame(width: 20)
                Text(message)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(color)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: copy) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 14))
                        .foregroundStyle(color.opacity(0.7))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Copy error")
            }
            if let hint = kind.hint {
                Text(hint)
                    .font(.system(size: 13))
                    .foregroundStyle(color.opacity(0.85))
                    .padding(.leading, 30)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(color.opacity(0.08), in: .rect(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(color.opacity(0.35)) }
        .accessibilityIdentifier("signInFailure")
    }
}

/// Flutter `_SavedProfilesSwitcher`: the saved logins as chips (tap to connect, × to delete).
/// Shown after a logout, which keeps them (the user's call, C2). × asks first, as the switcher does
/// (Flutter deleted at once), and the chips wait while a sign-in is checking.
private struct SavedProfilesChips: View {
    @Environment(AccountModel.self) private var account
    @State private var removing: ServerProfile?

    var body: some View {
        if !account.savedProfiles.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text("Saved Profiles")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                FlowLayout(spacing: 8, runSpacing: 8) {
                    ForEach(account.savedProfiles) { profile in
                        chip(profile)
                    }
                }
                .padding(.top, 8)
                Text("Tap a profile to connect • tap × to delete")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .disabled(account.state == .authenticating)
            .removeServerAlert($removing)
        }
    }

    private func chip(_ profile: ServerProfile) -> some View {
        HStack(spacing: 8) {
            Button {
                Task { await account.switchTo(profile) }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "person.crop.circle").font(.system(size: 18))
                    Text(profile.chipLabel).font(.system(size: 14, weight: .medium)).lineLimit(1)
                }
            }
            .buttonStyle(.plain)
            .accessibilityHint("\(profile.username) – \(profile.serverURL)")
            Button {
                removing = profile
            } label: {
                Image(systemName: "xmark.circle").font(.system(size: 16))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete \(profile.chipLabel)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.5)) }
    }
}

/// Texts the sign-in screen and Add Server share (C54).
enum SignInText {
    /// Under Legacy Authentication: it puts the password itself in every request.
    static let legacyFootnote = "Sends your password with every request. Turn on only if your server needs it."
}
