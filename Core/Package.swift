// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FeedingCore",
    defaultLocalization: "en",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "FeedingCore", targets: ["FeedingCore"])],
    targets: [
        .target(name: "FeedingCore", resources: [.process("Resources")]),
        .testTarget(name: "FeedingCoreTests", dependencies: ["FeedingCore"])
    ]
)
