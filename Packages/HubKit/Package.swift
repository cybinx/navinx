// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "HubKit",
    platforms: [.iOS("27.0")],
    products: [
        .library(name: "HubKit", targets: ["HubKit"]),
    ],
    dependencies: [
        .package(path: "../DeviceIdentity"),
    ],
    targets: [
        .target(name: "HubKit", dependencies: ["DeviceIdentity"]),
        .testTarget(name: "HubKitTests", dependencies: ["HubKit"], resources: [.copy("Fixtures")]),
    ]
)
