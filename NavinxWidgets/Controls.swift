import AppIntents
import SharedKit
import SwiftUI
import WidgetKit

// Control Center's controls (also for the Action button and the Lock Screen's corners). The system's
// own Now Playing control already has play, pause and skip.

struct ShuffleLibraryControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: WidgetKind.shuffleLibrary) {
            ControlWidgetButton(action: ShuffleLibraryIntent()) {
                Label("Shuffle Library", systemImage: "shuffle")
            }
        }
        .displayName("Shuffle Library")
        .description("Shuffles every song in your library in Navinx.")
    }
}

struct PlayFavoritesControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: WidgetKind.playFavorites) {
            ControlWidgetButton(action: PlayFavoritesIntent()) {
                Label("Play Favorites", systemImage: "heart.fill")
            }
        }
        .displayName("Play Favorites")
        .description("Plays your favorite songs in Navinx.")
    }
}

struct SearchControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: WidgetKind.search) {
            ControlWidgetButton(action: OpenSearchIntent()) {
                Label("Search Navinx", systemImage: "magnifyingglass")
            }
        }
        .displayName("Search Navinx")
        .description("Opens Search in Navinx.")
    }
}
