import SwiftUI

extension View {
    /// An alert whose Cancel is drawn in the normal colour, not the app's accent: an alert's
    /// non-destructive buttons take the tint of where it's attached (the root's accent), so it hangs on
    /// an empty view of its own, tinted `.primary`. A destructive button keeps the system's red
    /// (`RemoveServerAlert`, C64, D213; C66 for the others).
    func neutralAlert<Actions: View, Message: View>(
        _ title: LocalizedStringKey,
        isPresented: Binding<Bool>,
        @ViewBuilder actions: () -> Actions,
        @ViewBuilder message: () -> Message
    ) -> some View {
        background {
            Color.clear
                .alert(title, isPresented: isPresented, actions: actions, message: message)
                .tint(.primary)
        }
    }
}
