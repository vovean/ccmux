// swift-tools-version:6.0
import PackageDescription

// CCMuxCore holds the models, the OAuth client and usage parsing — the half with no
// AppKit in it. ccmuxd is a separate Go program that re-declares the wire types; the
// fixtures in server/testdata/wire are what stop the two drifting apart.
let package = Package(
    name: "CCMux",
    platforms: [.macOS(.v14)],
    products: [
        // Exposed so the wire types stay a named, shared contract even though ccmuxd is
        // now Go and re-declares them: server/testdata/wire pins the two together.
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
