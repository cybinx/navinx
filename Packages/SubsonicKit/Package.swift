// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SubsonicKit",
    platforms: [.iOS("27.0")],
    products: [
        .library(name: "SubsonicKit", targets: ["SubsonicKit"]),
    ],
    dependencies: [
        .package(path: "../DeviceIdentity"),
    ],
    targets: [
        .target(name: "SubsonicKit", dependencies: ["DeviceIdentity"]),
        .testTarget(
            name: "SubsonicKitTests",
            dependencies: ["SubsonicKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
