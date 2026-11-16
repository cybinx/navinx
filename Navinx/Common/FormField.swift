import SwiftUI

/// A Flutter `TextFormField`, with or without an icon: the label sits in the field while it's empty and
/// unfocused, and floats above the text otherwise (where the hint shows while it's empty).
/// `.outlined` is the login screen's bordered field; `.filled` the add-server screen's.
struct FormField<Field: Hashable>: View {
    enum Style { case outlined, filled }

    let label: String
    /// None for the Add tab's setup fields (C12).
    let systemImage: String?
    @Binding var text: String
    let field: Field
    var focus: FocusState<Field?>.Binding
    var style: Style = .outlined
    var hint: String?
    var isSecure = false
    /// Flutter's login shows the open eye while hidden; its add-server screen the crossed one.
    var eyeShowsHiddenState = false
    var keyboard: UIKeyboardType = .default
    var contentType: UITextContentType?
    var submitLabel: SubmitLabel = .next
    /// A validation message, shown in red under the field.
    var error: String?
    /// The Add tab's token field has no eye (C12).
    var showsRevealButton = true
    /// The UI tests' handle; the label by default.
    var identifier: String?

    @State private var revealed = false

    private var isFocused: Bool { focus.wrappedValue == field }
    private var floats: Bool { isFocused || !text.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 14) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 20))
                        .foregroundStyle(isFocused ? Palette.accent : .secondary)
                        .frame(width: 26)
                }
                VStack(alignment: .leading, spacing: 2) {
                    if floats {
                        Text(label)
                            .font(.system(size: 12))
                            .foregroundStyle(error != nil ? Color.red : isFocused ? Palette.accent : Palette.secondaryText)
                    }
                    input
                        .font(.system(size: 17))
                        .focused(focus, equals: field)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(keyboard)
                        .textContentType(contentType)
                        .submitLabel(submitLabel)
                        .accessibilityIdentifier(identifier ?? label)
                }
                if isSecure && showsRevealButton {
                    Button {
                        revealed.toggle()
                    } label: {
                        Image(systemName: (revealed != eyeShowsHiddenState) ? "eye.slash" : "eye")
                            .font(.system(size: 18))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(revealed ? "Hide password" : "Show password")
                }
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 56)
            .background { background }
            .contentShape(.rect)
            .onTapGesture { focus.wrappedValue = field }

            if let error {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .padding(.leading, 14)
            }
        }
    }

    @ViewBuilder private var input: some View {
        let prompt = Text(floats ? (hint ?? "") : label).foregroundStyle(Palette.secondaryText)
        if isSecure && !revealed {
            SecureField(label, text: $text, prompt: prompt)
        } else {
            TextField(label, text: $text, prompt: prompt)
        }
    }

    @ViewBuilder private var background: some View {
        let shape = RoundedRectangle(cornerRadius: 12)
        switch style {
        case .outlined:
            shape.strokeBorder(
                error != nil ? Color.red : isFocused ? Palette.accent : Color.primary.opacity(0.8),
                lineWidth: isFocused ? 2 : 1
            )
        case .filled:
            shape.fill(Palette.fieldFill)
                .overlay { if isFocused { shape.strokeBorder(Palette.accent, lineWidth: 2) } }
        }
    }
}

/// Flutter's amber "Insecure HTTP" note under a remote `http://` address.
struct InsecureHTTPWarning: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.shield.fill")
                .font(.system(size: 16))
                .foregroundStyle(Color(hex: 0xFFC107))
            Text("Insecure HTTP: Passwords and streaming traffic are not encrypted over public networks. HTTPS is recommended.")
                .font(.system(size: 12))
                .foregroundStyle(Color(light: 0xFF6F00, dark: 0xFFE082))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(hex: 0xFFC107, opacity: 0.12), in: .rect(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Color(hex: 0xFFC107, opacity: 0.3)) }
    }
}
