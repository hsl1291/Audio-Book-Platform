// swift-tools-version: 6.0
import PackageDescription

// BacklistCore is deliberately Foundation-only so it builds and tests on any
// platform, including Linux CI and a bare `swift test` on a Mac with no Xcode
// project open. Everything that needs SwiftUI, SwiftData, AVFoundation or
// CarPlay lives in the iOS app target, which depends on this package.
//
// Tools version 6.0 is required by `.iOS(.v18)`, which does not exist in
// PackageDescription 5.9.
let package = Package(
    name: "BacklistCore",
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [
        .library(name: "BacklistCore", targets: ["BacklistCore"])
    ],
    targets: [
        // Swift 6 language mode (the default for tools version 6.0): data races
        // are compile errors, not warnings. This package was first brought to
        // green in Swift 5 mode and then switched, so concurrency diagnostics
        // were never mixed in with ordinary compile errors.
        .target(name: "BacklistCore"),
        .testTarget(name: "BacklistCoreTests", dependencies: ["BacklistCore"]),
    ]
)
