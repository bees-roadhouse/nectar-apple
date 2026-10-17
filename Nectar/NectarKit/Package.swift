// swift-tools-version: 6.0

import PackageDescription

/// Shared layers of the native nectar apps: API client, sign-in, models, player core.
/// tvOS first, iOS next; macOS only so `swift test` runs on the build Mac.
let package = Package(
    name: "NectarKit",
    platforms: [
        .tvOS("26.0"),
        .iOS("26.0"),
        .macOS("26.0"),
    ],
    products: [
        .library(name: "NectarKit", targets: ["NectarKit"]),
    ],
    targets: [
        .target(name: "NectarKit"),
        .testTarget(name: "NectarKitTests", dependencies: ["NectarKit"]),
    ]
)
