import Foundation
import Observation
import PlaybackKit

/// Keeps the engine's data for the app: learns from the player and saves to a file, 800 ms after
/// the last change (Flutter `_scheduleSave`). As in Flutter there's one set of data on the phone,
/// not one per server, and signing out keeps it (only C11's "Clear" removes it).
@Observable
final class RecommendationModel {
    private(set) var data: RecommendationData

    @ObservationIgnored private let file: URL
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    /// Counts the clears: a save that began before one must not leave its data behind.
    @ObservationIgnored private var clears = 0

    private static let enabledKey = "recommendations_enabled"

    init(
        file: URL = URL.applicationSupportDirectory.appending(path: "Recommendations.json"),
        defaults: UserDefaults = .standard
    ) {
        self.file = file
        self.defaults = defaults
        // A file that can't be read just means starting to learn again.
        var data = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(RecommendationData.self, from: $0) }
            ?? RecommendationData()
        data.isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        data.applyDecay()
        self.data = data
    }

    func handle(_ event: ListenEvent) {
        data.record(event)
        scheduleSave()
    }

    /// Flutter `setEnabled` (C11's switch).
    func setEnabled(_ isEnabled: Bool) {
        data.isEnabled = isEnabled
        defaults.set(isEnabled, forKey: Self.enabledKey)
    }

    /// Flutter `clearData` (C11's button). The switch stays as it is.
    func clear() {
        saveTask?.cancel()
        clears += 1
        let isEnabled = data.isEnabled
        data = RecommendationData()
        data.isEnabled = isEnabled
        // Starts the decay clock now, as a new install's launch does; left at the epoch, the next
        // launch would decay everything learned after this clear to nothing.
        data.applyDecay()
        try? FileManager.default.removeItem(at: file)
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let data = data
        let file = file
        let startedAt = clears
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled, startedAt == clears else { return }
            await Self.write(data, to: file)
            // A write already running when "Clear" came can't be stopped, so its file goes too.
            if startedAt != clears { try? FileManager.default.removeItem(at: file) }
        }
    }

    @concurrent
    private nonisolated static func write(_ data: RecommendationData, to file: URL) async {
        guard let encoded = try? JSONEncoder().encode(data) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? encoded.write(to: file, options: .atomic)
    }
}
