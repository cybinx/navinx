import Testing
import UIKit
@testable import Navinx

/// The app icon choice (C52, D186; Red out since C54): the options' order and names, and reading iOS's
/// `alternateIconName` back.
@Suite struct AppIconTests {
    @Test func whiteFirstAndTheDefault() {
        #expect(AppIconChoice.allCases.map(\.title) == ["White", "Black", "Indigo", "Violet", "Teal", "Amber", "Graphite"])
        #expect(AppIconChoice.standard == .white)
        #expect(AppIconChoice.white.alternateIconName == nil)
        #expect(AppIconChoice.indigo.alternateIconName == "AppIcon-Indigo")
    }

    @Test func namesMatchTheAssetCatalog() {
        let alternates = AppIconChoice.allCases.compactMap(\.alternateIconName)
        #expect(alternates == ["AppIcon-Black", "AppIcon-Indigo", "AppIcon-Violet", "AppIcon-Teal", "AppIcon-Amber", "AppIcon-Graphite"])
        for choice in AppIconChoice.allCases {
            #expect(UIImage(named: choice.previewImageName) != nil, "\(choice.previewImageName) is missing")
        }
        #expect(Set(AppIconChoice.allCases.map(\.accessibilityIdentifier)).count == AppIconChoice.allCases.count)
    }

    @Test func theLogoIsATemplate() throws {
        let logo = try #require(UIImage(named: "Logo"))
        #expect(logo.renderingMode == .alwaysTemplate)
        #expect(logo.size.height > logo.size.width * 2)
    }

    /// Both lists: `CFBundleIcons` (the iPhone's, from the asset catalog) and `CFBundleIcons~ipad`
    /// (an iPad running the app, written by hand in `Config/Navinx-Info.plist`, C56).
    @Test(arguments: ["CFBundleIcons", "CFBundleIcons~ipad"])
    func theBuiltAppListsEveryAlternate(_ key: String) throws {
        // The file itself: the bundle's own dictionary may fold the `~ipad` keys in for the device.
        let url = Bundle.main.bundleURL.appending(path: "Info.plist")
        let info = try #require(NSDictionary(contentsOf: url) as? [String: Any])
        let icons = try #require(info[key] as? [String: Any])
        let alternates = try #require(icons["CFBundleAlternateIcons"] as? [String: Any])
        #expect(Set(alternates.keys) == Set(AppIconChoice.allCases.compactMap(\.alternateIconName)))
    }

    @Test(arguments: [
        (String?.none, AppIconChoice.white),
        ("AppIcon-Indigo", .indigo),
        ("AppIcon-Black", .black),
        ("AppIcon-Violet", .violet),
        ("AppIcon-Red", .white),
        ("AppIcon-Graphite", .graphite),
        ("AppIcon-Unknown", .white),
        ("AppIcon", .white),
    ])
    func readsTheSystemsChoiceBack(_ name: String?, _ choice: AppIconChoice) {
        #expect(AppIconChoice.matching(alternateIconName: name) == choice)
    }

    /// A tap is judged by what iOS shows at that moment (C54 part 4): with an old Red still showing
    /// (the retirement refused), White (the primary) goes through although the picker marks White.
    @Test func aTapIsJudgedByWhatIOSShows() {
        #expect(AppIconChoice.white.needsChange(fromAlternateIconName: "AppIcon-Red"))
        #expect(AppIconChoice.violet.needsChange(fromAlternateIconName: "AppIcon-Red"))
        #expect(!AppIconChoice.white.needsChange(fromAlternateIconName: nil))
        #expect(AppIconChoice.white.needsChange(fromAlternateIconName: "AppIcon-Teal"))
        // Indigo, the primary icon in 1.0, is an alternate now: a 1.0 phone showing it (nil) gets White.
        #expect(AppIconChoice.indigo.needsChange(fromAlternateIconName: nil))
        #expect(AppIconChoice.violet.needsChange(fromAlternateIconName: nil))
        for choice in AppIconChoice.allCases {
            #expect(!choice.needsChange(fromAlternateIconName: choice.alternateIconName))
        }
        // The picker shows White for Red, which is why its own idea can't be the test.
        #expect(AppIconChoice.matching(alternateIconName: "AppIcon-Red") == .white)
    }

    /// Red left the choices (C54): a phone still showing it goes back to the primary icon.
    @Test func anOldRedIconIsRetired() {
        #expect(AppIconChoice.isRetired(alternateIconName: "AppIcon-Red"))
        #expect(!AppIconChoice.isRetired(alternateIconName: nil))
        for name in AppIconChoice.allCases.compactMap(\.alternateIconName) {
            #expect(!AppIconChoice.isRetired(alternateIconName: name))
        }
    }
}
