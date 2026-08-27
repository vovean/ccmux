// swift-tools-version:6.0
import PackageDescription

// CCMuxCore is the portable half: models, the OAuth client, usage parsing. It builds on
// Linux so `ccmuxd` (server/Package.swift) can share it verbatim rather than growing a
// second, drifting copy of the credential logic.
//
// The server is a separate package on purpose. Hummingbird and NIO are a large build,
// and `make publish` guards on a zero-warning clean build — third-party warnings would
// fail a release that has nothing to do with them.
let package = Package(
    name: "CCMux",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CCMuxCore", targets: ["CCMuxCore"]),
    ],
    dependencies: [
        // Linux only: CryptoKit covers macOS, and building swift-crypto there would slow
        // every `swift build` for nothing.
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.8.0"),
    ],
    targets: [
        .target(
            name: "CCMuxCore",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto",
                         condition: .when(platforms: [.linux])),
            ],
            path: "Sources/CCMuxCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "CCMuxKit",
            dependencies: ["CCMuxCore"],
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
            dependencies: ["CCMuxKit", "CCMuxCore"],
            path: "Tests/CCMuxKitTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
