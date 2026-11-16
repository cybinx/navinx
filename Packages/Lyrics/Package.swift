// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Lyrics",
    platforms: [.iOS("27.0")],
    products: [
        .library(name: "Lyrics", targets: ["Lyrics"]),
    ],
    dependencies: [
        .package(path: "../SubsonicKit"),
    ],
    targets: [
        .target(name: "Lyrics", dependencies: ["SubsonicKit"]),
        .testTarget(name: "LyricsTests", dependencies: ["Lyrics"]),
    ]
)
