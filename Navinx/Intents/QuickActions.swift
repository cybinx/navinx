import UIKit
import SharedKit

/// The four actions on a long press of the app's icon (C39, D146), listed in `Config/Navinx-Info.plist`
/// under `UIApplicationShortcutItems` with these types.
enum QuickAction: String, CaseIterable {
    case search = "navinx.search"
    case favorites = "navinx.favorites"
    case shuffleLibrary = "navinx.shuffle-library"
    case downloads = "navinx.downloads"

    /// True when the item was the app's.
    @discardableResult
    static func handle(_ item: UIApplicationShortcutItem) -> Bool {
        guard let action = QuickAction(rawValue: item.type), let services = IntentServices.shared else { return false }
        Task { await action.run(services) }
        return true
    }

    private func run(_ services: IntentServices) async {
        do {
            switch self {
            case .search: try await services.open(.search(nil))
            case .favorites: try await services.open(.favorites)
            case .downloads: try await services.open(.downloads)
            case .shuffleLibrary: try await services.play(.library)
            }
        } catch {
            // Signed out the login screen is already showing; anything else is said as a toast.
            if error != .signIn { services.toasts.show(error.message) }
        }
    }
}

/// Hands the icon's quick actions over, at a cold launch and while running (SwiftUI has no way in).
/// SwiftUI still makes and owns the window.
final class SceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        if let item = connectionOptions.shortcutItem { QuickAction.handle(item) }
    }

    func windowScene(
        _ windowScene: UIWindowScene,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(QuickAction.handle(shortcutItem))
    }
}

extension AppDelegate {
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}
