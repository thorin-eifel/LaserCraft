// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LaserGRBL-macOS",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LaserGRBLCore", targets: ["LaserGRBLCore"]),
        .executable(name: "LaserGRBLMac", targets: ["LaserGRBLMac"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .target(name: "LaserGRBLCore"),
        .executableTarget(name: "LaserGRBLMac", dependencies: ["LaserGRBLCore", .product(name: "Sparkle", package: "Sparkle")]),
        .testTarget(name: "LaserGRBLCoreTests", dependencies: ["LaserGRBLCore"]),
        .testTarget(name: "LaserGRBLMacTests", dependencies: ["LaserGRBLMac", "LaserGRBLCore"]),
    ]
)
