// swift-tools-version: 5.9
import PackageDescription

// BacklistCore is deliberately Foundation-only so it builds and tests on any
// platform, including Linux CI and a bare `swift test` on a Mac with no Xcode
// project open. Everything that needs SwiftUI, SwiftData, AVFoundation or
// CarPlay lives in the iOS app target, which depends on this package.
let package = Package(
    name: "BacklistCore",
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [
        .library(name: "BacklistCore", targets: ["BacklistCore"])
    ],
    targets: [
        .target(name: "BacklistCore"),
        .testTarget(name: "BacklistCoreTests", dependencies: ["BacklistCore"])
    ]
)
