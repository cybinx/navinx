import SwiftUI

/// Edit Server (D139): the login screen itself, filled in with every detail of a saved login, in a
/// sheet with a Cancel button. From the switcher's ⋯ menu and the unreachable screen. Connecting checks
/// the new details first (nothing changes if the server doesn't answer) and keeps the same profile,
/// so its downloads and caches stay. Not in the Flutter app, which can't edit a saved server.
struct EditServerSheet: View {
    let profile: ServerProfile
    /// Called once the edited login has connected (the sheet has closed itself).
    var onConnected: () -> Void = {}

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            LoginView(editing: profile) {
                dismiss()
                onConnected()
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                        .accessibilityIdentifier("editServerCancel")
                }
            }
        }
    }
}
