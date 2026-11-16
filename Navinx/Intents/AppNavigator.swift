import Foundation
import Observation
import SharedKit

// `AppDestination` and `NavinxLink` (the links) are `SharedKit`'s since C40: the widgets make links too.

/// The page waiting to be shown; `MainTabView` takes it once the app's tabs are up.
@Observable
final class AppNavigator {
    /// The one the app uses, for the scene delegate (the icon's quick actions) too.
    static let shared = AppNavigator()

    private(set) var pending: AppDestination?
    /// Search's text from a request, taken by `SearchView`.
    var searchText: String?

    func open(_ destination: AppDestination) {
        pending = destination
    }

    /// Signed out, or another server: a page asked for before isn't this one's to open.
    func clear() {
        pending = nil
        searchText = nil
    }

    /// Hands the pending page over, once.
    func take() -> AppDestination? {
        defer { pending = nil }
        return pending
    }
}
