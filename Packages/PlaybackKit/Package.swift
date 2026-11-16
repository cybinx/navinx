// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PlaybackKit",
    platforms: [.iOS("27.0")],
    products: [
        .library(name: "PlaybackKit", targets: ["PlaybackKit"]),
    ],
    dependencies: [
        .package(path: "../DeviceIdentity"),
        .package(path: "../SubsonicKit"),
    ],
    targets: [
        .target(name: "PlaybackKit", dependencies: ["SubsonicKit", "DeviceIdentity"]),
        .testTarget(name: "PlaybackKitTests", dependencies: ["PlaybackKit"]),
    ]
)
