// swift-tools-version:5.9
import PackageDescription

/// Tests for the fork's own logic in the Swiftfin targets, which have no test target of their own. Each source here is a
/// symlink to the file the app ships, so the tests compile exactly that file.
let package = Package(
    name: "SwiftfinForkTests",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "SwiftfinFork"),
        .testTarget(name: "SwiftfinForkTests", dependencies: ["SwiftfinFork"]),
    ]
)
