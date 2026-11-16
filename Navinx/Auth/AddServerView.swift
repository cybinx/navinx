import SwiftUI

/// Adds a server and signs in to it: Flutter `AddServerScreen`
/// (`lib/screens/auth/add_server_screen.dart`). Differences, each the user's call or a decision:
/// no provider cards (Subsonic only, D4); no certificate options (D11), so the disclosure is
/// "Advanced Settings" with only Legacy Authentication; a failed connect keeps the current server
/// signed in (Flutter dropped to the login screen underneath).
struct AddServerView: View {
    @Environment(AccountModel.self) private var account
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.dismiss) private var dismiss

    private enum Field: Hashable { case name, server, lan, username, password }

    @State private var profileName = ""
    @State private var serverURL = ""
    @State private var homeNetworkURL = ""
    @State private var username = ""
    @State private var password = ""
    @State private var sendsPlainPassword = false
    @State private var showAdvanced = false
    @State private var isConnecting = false
    @State private var errorMessage: String?
    @State private var fieldErrors: [Field: String] = [:]
    @FocusState private var focus: Field?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let errorMessage {
                    errorBanner(errorMessage).padding(.bottom, 16)
                }
                form
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 32)
        }
        .scrollDismissesKeyboard(.immediately)
        .background(Palette.background)
        .navigationTitle("Add Server")
        .navigationBarTitleDisplayMode(.inline)
        .onSubmit(next)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Subsonic / Navidrome Details")
                .font(.system(size: 16, weight: .bold))
            FormField(
                label: "Profile Name (Optional)", systemImage: "tag", text: $profileName, field: .name,
                focus: $focus, style: .filled, hint: "e.g. Home"
            )
            .padding(.top, 16)
            FormField(
                label: "Server URL *", systemImage: "link", text: $serverURL, field: .server, focus: $focus,
                style: .filled, hint: "https://music.example.com", keyboard: .URL, contentType: .URL,
                error: fieldErrors[.server]
            )
            .padding(.top, 14)
            if SignInFailure.isPlainHTTPOffNetwork(serverURL) {
                InsecureHTTPWarning().padding(.top, 8)
            }
            FormField(
                label: "LAN Server URL (Optional)", systemImage: "wifi", text: $homeNetworkURL, field: .lan,
                focus: $focus, style: .filled, hint: "e.g. http://192.168.1.5:4533", keyboard: .URL
            )
            .padding(.top, 14)
            FormField(
                label: "Username *", systemImage: "person", text: $username, field: .username, focus: $focus,
                style: .filled, error: fieldErrors[.username]
            )
            .padding(.top, 14)
            FormField(
                label: "Password *", systemImage: "lock", text: $password, field: .password, focus: $focus,
                style: .filled, isSecure: true, eyeShowsHiddenState: true,
                submitLabel: .done, error: fieldErrors[.password]
            )
            .padding(.top, 14)

            Button {
                withAnimation(.snappy) { showAdvanced.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: showAdvanced ? "chevron.down" : "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 16)
                    Text("Advanced Settings")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                }
                .foregroundStyle(Palette.accent)
                .padding(.vertical, 6)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .padding(.top, 16)

            if showAdvanced {
                Toggle(isOn: $sendsPlainPassword) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Legacy Authentication").font(.system(size: 13))
                        Text("Required for older Subsonic API implementations")
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.secondaryText)
                    }
                }
                .tint(Palette.accent)
                .padding(12)
                .background(Palette.fieldFill, in: .rect(cornerRadius: 12))
                .padding(.top, 10)
                Text(SignInText.legacyFootnote)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
                    .padding(.top, 6)
            }

            Button(action: connect) {
                ZStack {
                    if isConnecting {
                        ProgressView().tint(.white)
                    } else {
                        Text("Connect & Save Server").font(.system(size: 15, weight: .bold))
                    }
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(Palette.accent.opacity(isConnecting ? 0.5 : 1), in: .rect(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .disabled(isConnecting)
            .padding(.top, 24)
            .accessibilityIdentifier("connectAndSave")
        }
        .padding(20)
        .background(Palette.surface, in: .rect(cornerRadius: 18))
        .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(Palette.hairline) }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 18))
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 2) {
                Text("Connection Error")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.red)
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(Color(light: 0xB71C1C, dark: 0xEF9A9A))
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color.red.opacity(0.12), in: .rect(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Color.red.opacity(0.3)) }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("connectionError")
    }

    private func next() {
        switch focus {
        case .name: focus = .server
        case .server: focus = .lan
        case .lan: focus = .username
        case .username: focus = .password
        case .password: if !isConnecting { connect() }
        case nil: break
        }
    }

    /// Flutter `_connectServer`. Its validators show the field's own label as the message.
    private func connect() {
        var errors: [Field: String] = [:]
        if serverURL.trimmingCharacters(in: .whitespaces).isEmpty { errors[.server] = "Server URL *" }
        if username.trimmingCharacters(in: .whitespaces).isEmpty { errors[.username] = "Username *" }
        if password.isEmpty { errors[.password] = "Password *" }
        fieldErrors = errors
        guard errors.isEmpty else { return }

        var url = serverURL.trimmingCharacters(in: .whitespaces)
        // Either case: "HTTPS://host" pasted mustn't become "https://HTTPS://host".
        if !url.lowercased().hasPrefix("http://") && !url.lowercased().hasPrefix("https://") {
            url = "https://\(url)"
        }
        let user = username.trimmingCharacters(in: .whitespaces)
        let name = profileName.trimmingCharacters(in: .whitespaces)
        let lan = homeNetworkURL.trimmingCharacters(in: .whitespaces)

        focus = nil
        isConnecting = true
        errorMessage = nil
        Task {
            let outcome = await account.signIn(
                serverURL: url,
                // Empty, not nil: this form has the field, so leaving it empty clears a saved LAN address.
                homeNetworkURL: lan,
                username: user,
                password: password,
                sendsPlainPassword: sendsPlainPassword,
                profileName: name.isEmpty ? nil : name
            )
            switch outcome {
            case .failed(let failure):
                isConnecting = false
                errorMessage = failure
            case .superseded:
                // Something newer took over (a switch, a sign-out): nothing was added, and nothing failed.
                isConnecting = false
            case .done:
                // The app also reloads for a new server (MainTabView's identity). C3: refresh the
                // library here.
                dismiss()
                // A server that approves each device shows its own screens first (C45).
                if account.approval == nil {
                    toasts.show("Connected to \(name.isEmpty ? user : name)", checkmark: true)
                }
            }
        }
    }
}
