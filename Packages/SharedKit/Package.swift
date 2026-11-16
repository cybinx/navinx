// swift-tools-version: 6.2
import PackageDescription

// What the app and its widgets extension both compile (C40): the links, the snapshot the app shares
// with the widgets, and the intents a widget's or a control's button carries. It depends on no other
// package, so the extension stays small and never holds a login.
let package = Package(
    name: "SharedKit",
    platforms: [.iOS("27.0")],
    products: [
        .library(name: "SharedKit", targets: ["SharedKit"]),
    ],
    targets: [
        .target(name: "SharedKit"),
        .testTarget(name: "SharedKitTests", dependencies: ["SharedKit"]),
    ]
)
