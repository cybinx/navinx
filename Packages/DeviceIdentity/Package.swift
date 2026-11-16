// swift-tools-version: 6.2
import PackageDescription

// The device's own key and certificate for a server that approves each device (C45): the key, the
// certificate request, the four words, the enrolment calls, and the one provider every connection to
// the server asks for the certificate. It depends on no other package.
let package = Package(
    name: "DeviceIdentity",
    platforms: [.iOS("27.0")],
    products: [
        .library(name: "DeviceIdentity", targets: ["DeviceIdentity"]),
    ],
    targets: [
        .target(name: "DeviceIdentity", resources: [.copy("words.txt")]),
        .testTarget(name: "DeviceIdentityTests", dependencies: ["DeviceIdentity"], resources: [.copy("Fixtures")]),
    ]
)
