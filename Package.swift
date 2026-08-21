// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "CCMux",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "CCMuxKit",
            path: "Sources/CCMuxKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "ccmux",
            dependencies: ["CCMuxKit"],
            path: "Sources/ccmux",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "CCMuxKitTests",
            dependencies: ["CCMuxKit"],
            path: "Tests/CCMuxKitTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
