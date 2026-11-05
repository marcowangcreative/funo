// swift-tools-version:5.9
import PackageDescription

// The AppKit app (and Sparkle) only exist on macOS. Linux builds the
// pure-Swift core and its tests — color-label selection, face-result
// caching, thumbnail delivery — without pretending AppKit will compile.
// `platforms` is omitted off macOS: an explicit empty list is rejected,
// and omitting it leaves the core library buildable on the host.
#if os(macOS)
let package = Package(
    name: "QuickCull",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        .target(
            name: "QuickCullCore",
            path: "Sources/QuickCullCore"
        ),
        .testTarget(
            name: "QuickCullCoreTests",
            dependencies: ["QuickCullCore"],
            path: "Tests/QuickCullCoreTests"
        ),
        .executableTarget(
            name: "QuickCull",
            dependencies: [
                "QuickCullCore",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/QuickCull",
            resources: [
                .copy("Resources/banner.png")
            ]
        )
    ]
)
#else
let package = Package(
    name: "QuickCull",
    targets: [
        .target(
            name: "QuickCullCore",
            path: "Sources/QuickCullCore"
        ),
        .testTarget(
            name: "QuickCullCoreTests",
            dependencies: ["QuickCullCore"],
            path: "Tests/QuickCullCoreTests"
        )
    ]
)
#endif
