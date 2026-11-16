import SwiftUI
import Observation

/// Flutter's floating `SnackBar`s ("Connected to …", "Error copied to clipboard"): a short message
/// at the bottom for 2 seconds. The root view shows it outside the tabs, and each tab over its own pages
/// (`showsToasts`), so it outlives the screen that raised it.
@Observable
final class ToastCenter {
    struct Toast: Identifiable, Equatable {
        let id = UUID()
        let text: String
        /// Flutter's green check before the text.
        let showsCheckmark: Bool
        /// Flutter's plain icon before the text.
        let systemImage: String?
    }

    private(set) var current: Toast?

    func show(_ text: String, checkmark: Bool = false, systemImage: String? = nil) {
        let toast = Toast(text: text, showsCheckmark: checkmark, systemImage: systemImage)
        current = toast
        Task {
            try? await Task.sleep(for: .seconds(2))
            if current?.id == toast.id { current = nil }
        }
    }
}

struct ToastView: View {
    let toast: ToastCenter.Toast

    var body: some View {
        HStack(spacing: 10) {
            if toast.showsCheckmark {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Palette.green)
            }
            if let systemImage = toast.systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 18))
            }
            Text(toast.text)
                .font(.system(size: 15, weight: .medium))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .appGlass(in: .rect(cornerRadius: 16))
        .padding(.horizontal, 16)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("toast")
    }
}

extension View {
    /// Shows the toasts over a tab's pages, just above whatever the tab has at its bottom (C65): the open
    /// mini-player, the folded bar, the tab bar alone with no song, or the home indicator on a page that
    /// hides the bar. It follows the fold, as the tab's bottom safe area does. (The root view's toasts are
    /// for the screens outside the tabs.)
    func showsToasts() -> some View {
        modifier(ShowsToasts())
    }
}

private struct ShowsToasts: ViewModifier {
    @Environment(ToastCenter.self) private var toasts

    /// Above the bottom safe area: today's gap over the open mini-player (C65).
    static let gap: CGFloat = 15

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let toast = toasts.current {
                    ToastView(toast: toast)
                        .padding(.bottom, Self.gap)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.snappy, value: toasts.current)
    }
}
