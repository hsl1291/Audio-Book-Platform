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
        .target(
            name: "BacklistCore",
            // Staged deliberately. Tools version 6.0 would otherwise switch the
            // package into Swift 6 language mode, turning every concurrency
            // diagnostic into an error at the same moment we are still
            // establishing that the code compiles at all. Mixing "does this
            // build" with "is this concurrency-correct" makes both harder to
            // diagnose. Move to .v6 as its own change once CI is green.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "BacklistCoreTests",
            dependencies: ["BacklistCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
