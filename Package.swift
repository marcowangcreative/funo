// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "QuickCull",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        // OTA updates — industry-standard for Developer ID Mac apps.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        .executableTarget(
            name: "QuickCull",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/QuickCull",
            resources: [
                .copy("Resources/banner.png")
            ]
        )
    ]
)
