// swift-tools-version:6.0
import PackageDescription

// A separate package from the app on purpose. Hummingbird and NIO are a large build, and
// `make publish` guards the app's release on a zero-warning clean build — third-party
// warnings would fail a release that has nothing to do with them.
//
// CCMuxCore comes in by path, so the credential logic here is the same code the Mac runs
// rather than a copy that drifts.
let package = Package(
    name: "ccmuxd",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: ".."),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.6.0"),
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.23.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.27.0"),
    ],
    targets: [
        // The daemon's logic lives in a library so it is testable; the executable is only
        // an entry point.
        .target(
            name: "CCMuxDaemonKit",
            dependencies: [
                .product(name: "CCMuxCore", package: "CCMux"),
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
            ],
            path: "Sources/CCMuxDaemonKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "ccmuxd",
            dependencies: [
                "CCMuxDaemonKit",
                .product(name: "HummingbirdTLS", package: "hummingbird"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
            ],
            path: "Sources/ccmuxd",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ccmuxdTests",
            dependencies: [
                "CCMuxDaemonKit",
                .product(name: "CCMuxCore", package: "CCMux"),
                // The real client, so one test can drive the actual pinning, basic-auth
                // and JSON paths against a real server instead of approximating them.
                .product(name: "CCMuxKit", package: "CCMux"),
                .product(name: "HummingbirdTLS", package: "hummingbird"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
            ],
            path: "Tests/ccmuxdTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
