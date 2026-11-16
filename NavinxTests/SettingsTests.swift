import Foundation
import PlaybackKit
import SubsonicKit
import Testing
import UIKit
@testable import Navinx

/// Settings (C11): the texts Flutter formats, the appearance's keys and defaults, and the
/// recommendations' stats.
@Suite struct SettingsFormatTests {
    /// Flutter `formatBytes`: binary units, one decimal under 10.
    private static let kilo: Int64 = 1024
    private static let cases: [(Int64, String)] = [
        (0, "0 B"),
        (-5, "0 B"),
        (512, "512 B"),
        (kilo, "1.0 KB"),
        (1536, "1.5 KB"),
        (10 * kilo, "10 KB"),
        (5 * kilo * kilo + 300 * kilo, "5.3 MB"),
        (250 * kilo * kilo, "250 MB"),
        (3 * kilo * kilo * kilo, "3.0 GB"),
    ]

    @Test(arguments: cases)
    func bytes(_ bytes: Int64, _ text: String) {
        #expect(SettingsFormat.bytes(bytes) == text)
    }

    @Test func songCounts() {
        #expect(SettingsFormat.songs(0) == "No songs")
        #expect(SettingsFormat.songs(1) == "1 song")
        #expect(SettingsFormat.songs(12) == "12 songs")
        #expect(SettingsFormat.songsDownloaded(1) == "1 song downloaded")
        #expect(SettingsFormat.songsDownloaded(3) == "3 songs downloaded")
    }

    @Test func decibelsHaveOneDecimalAndNoMinusZero() {
        #expect(SettingsFormat.decibels(0) == "0.0")
        #expect(SettingsFormat.decibels(-0.0) == "0.0")
        #expect(SettingsFormat.decibels(-6) == "-6.0")
        #expect(SettingsFormat.decibels(12) == "12.0")
    }
}

@MainActor
@Suite struct AppearanceModelTests {
    private func defaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "AppearanceTests-\(UUID().uuidString)"))
    }

    /// Purple since C54 (D193), not Flutter's red; a red chosen before stays red.
    @Test func systemAndPurpleByDefault() throws {
        let model = AppearanceModel(defaults: try defaults())
        #expect(model.theme == .system)
        #expect(model.accent == .purple)
        #expect(AppearanceModel.Accent.standard == .purple)
    }

    @Test func aChosenRedIsKept() throws {
        let defaults = try defaults()
        defaults.set("red", forKey: "app_accent_color")
        #expect(AppearanceModel(defaults: defaults).accent == .red)
    }

    @Test func choicesAreKeptUnderFlutterKeys() throws {
        let defaults = try defaults()
        let model = AppearanceModel(defaults: defaults)
        model.theme = .dark
        model.accent = .blue
        #expect(defaults.string(forKey: "app_theme_mode") == "dark")
        #expect(defaults.string(forKey: "app_accent_color") == "blue")
        let again = AppearanceModel(defaults: defaults)
        #expect(again.theme == .dark && again.accent == .blue)
    }

    @Test func anUnknownValueFallsBackToTheDefault() throws {
        let defaults = try defaults()
        defaults.set("dynamic", forKey: "app_accent_color")
        defaults.set("sepia", forKey: "app_theme_mode")
        let model = AppearanceModel(defaults: defaults)
        #expect(model.accent == .purple && model.theme == .system)
    }

    /// Flutter's seven colours (`theme_service.dart`), without Material You.
    @Test func flutterColours() {
        #expect(AppearanceModel.Accent.allCases.map(\.hex) == [0xFA243C, 0xFC5C65, 0xFF9500, 0xFFCC00, 0x1DB954, 0x007AFF, 0x8B5CF6])
        #expect(AppearanceModel.Theme.allCases.map(\.title) == ["System", "Light", "Dark"])
        #expect(AppearanceModel.Theme.system.interfaceStyle == .unspecified)
    }
}

@Suite struct ListeningStatsTests {
    /// Flutter `getListeningStats`: every play, and the songs played.
    @Test func playsAndSongs() {
        var data = RecommendationData()
        #expect(data.listeningStats.totalPlays == 0 && data.listeningStats.songs == 0)
        let a = Song(id: "a", title: "A", duration: 200)
        let b = Song(id: "b", title: "B", duration: 200)
        for song in [a, a, b] {
            data.record(.started(song))
            data.record(.finished(song, played: 200, duration: 200, end: .ended), hour: 9)
        }
        #expect(data.listeningStats.totalPlays == 3)
        #expect(data.listeningStats.songs == 2)
    }
}

@Suite struct SettingsDefaultsTests {
    /// The defaults Settings shows match what the player reads when nothing is saved.
    @Test func playbackDefaults() throws {
        let defaults = try #require(UserDefaults(suiteName: "SettingsDefaults-\(UUID().uuidString)"))
        let replayGain = ReplayGainSettings(defaults: defaults)
        #expect(replayGain.mode == .off && replayGain.preamp == 0 && replayGain.preventsClipping && replayGain.fallbackGain == -6)
        let transcoding = TranscodingSettings(defaults: defaults)
        #expect(!transcoding.isEnabled && transcoding.wifiBitRate == 0 && transcoding.mobileBitRate == 192 && transcoding.format == "mp3")
        #expect(TranscodingSettings.bitRates == [0, 64, 128, 192, 256, 320])
    }
}

@Suite struct SteppedSliderTests {
    @Test(arguments: [(0.4, 0.0), (0.6, 1.0), (11.7, 12.0), (-3.0, 0.0), (5.5, 6.0)])
    func snapsToTheNearestStopInsideTheRange(raw: Double, stop: Double) {
        #expect(SteppedSlider.snap(raw, in: 0...12, step: 1) == stop)
    }

    @Test func stopsStartAtTheLowerBound() {
        #expect(SteppedSlider.snap(130, in: 100...1000, step: 50) == 150)
        #expect(SteppedSlider.snap(-5.2, in: -12...12, step: 1) == -5)
        #expect(SteppedSlider.snap(0.9, in: 1...20, step: 1) == 1)
    }
}

/// Settings' own symbols (D210): every one is a real SF Symbol on this iOS, and the pages keep their
/// earlier accessibility identifiers under the new titles.
@Suite struct SettingsSymbolTests {
    /// The glyphs drawn inside the pages and the server sheets, as written there.
    private static let pageSymbols = [
        // Playback
        "infinity", "text.badge.plus", "arrow.triangle.merge", "arrow.forward.to.line",
        "laptopcomputer.and.iphone", "playpause", "slider.vertical.3", "gauge.with.dots.needle.33percent",
        "wifi.router", "antenna.radiowaves.left.and.right", "doc.badge.gearshape",
        // Storage
        "photo.stack", "xmark.bin", "xmark.bin.fill", "arrow.down.heart.fill", "arrow.down.circle.fill",
        "externaldrive.badge.minus",
        // Servers, the switcher and Add Server
        "server.rack", "arrow.left.arrow.right", "plus", "person.crop.circle", "house", "number",
        "person.crop.circle.badge.xmark", "gearshape", "character.cursor.ibeam", "minus.circle",
        // Appearance
        "sun.lefthalf.filled", "swatchpalette.fill", "star.leadinghalf.filled", "text.below.photo.fill",
        "pin.fill", "text.justify.left", "text.justify", "wand.and.stars",
        // About
        "tag", "iphone.gen3", "lock.shield", "arrow.up.forward", "lifepreserver", "hands.clap.fill", "calendar",
    ]

    @Test(arguments: SettingsView.Page.allCases.map(\.systemImage)
        + AppearanceModel.Theme.allCases.map(\.systemImage)
        + pageSymbols)
    func symbolResolves(_ name: String) {
        #expect(UIImage(systemName: name) != nil, "\(name) isn't an SF Symbol")
    }

    @Test func pagesKeepTheirIdentifiers() {
        #expect(SettingsView.Page.allCases.map(\.identifier) == [
            "settingsTab-Playback", "settingsTab-Storage", "settingsTab-Server", "settingsTab-Display",
            "settingsTab-About",
        ])
        #expect(SettingsView.Page.allCases.map(\.title) == ["Playback", "Storage", "Servers", "Appearance", "About"])
    }
}
