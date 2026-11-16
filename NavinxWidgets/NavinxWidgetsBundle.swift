import AppIntents
import SharedKit
import SwiftUI
import WidgetKit

// Navinx's Home Screen widgets and Control Center controls (C40). The extension never signs in: it
// reads the snapshot the app shares in the App Group (`SharedKit`'s `WidgetStore`), and its buttons
// carry `SharedKit`'s intents, which run in the app.

@main
struct NavinxWidgetsBundle: WidgetBundle {
    var body: some Widget {
        NowPlayingWidget()
        RecentlyPlayedWidget()
        PlaylistWidget()
        ShuffleLibraryControl()
        PlayFavoritesControl()
        SearchControl()
    }
}

/// `SharedKit`'s intents and playlist entity, in the extension's own App Intents metadata.
struct NavinxWidgetsIntents: AppIntentsPackage {
    static var includedPackages: [any AppIntentsPackage.Type] { [SharedKitIntents.self] }
}
