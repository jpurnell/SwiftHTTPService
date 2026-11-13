// swift-tools-version: 6.2
// legibility:description: A small, safe kit for serving a JSON API over HTTP/1.1 — routing, middleware, problem details, conditional requests, validated configuration, and a bounded transport.
//
// 6.2 rather than the toolchain that happens to be installed: consumers build in CI and deploy to hosts
// that may be a release behind, and a manifest newer than the compiler fails at resolution.

import PackageDescription

let package = Package(
    name: "SwiftHTTPService",
    // Nothing here is Apple-only, so Linux should build; it is not tested there yet (design D2).
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        // The core: no sockets, no NIO. Routing and middleware are pure and tested without a network.
        .library(
            name: "SwiftHTTPService",
            targets: ["SwiftHTTPService"]
        ),
        // The transport: HTTP/1.1 over TCP and TLS, with the limits and the lifecycle. Kept a separate
        // product so a consumer that brings its own transport links no NIO.
        .library(
            name: "SwiftHTTPServiceNIO",
            targets: ["SwiftHTTPServiceNIO"]
        ),
    ],
    dependencies: [
        // Apple's: the core takes swift-http-types; the transport target adds swift-nio and swift-nio-extras.
        // The core stays free of NIO.
        .package(url: "https://github.com/apple/swift-http-types.git", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.102.0"),
        .package(url: "https://github.com/apple/swift-nio-extras.git", from: "1.35.0"),
        // The transport's HTTP/2: frames, streams and flow control. Transport target only.
        .package(url: "https://github.com/apple/swift-nio-http2.git", from: "1.46.0"),
        // The owner's own, and only the transport target's: it loads and judges the server's TLS identity,
        // reloads a renewed certificate, and classifies a bind as exposed plaintext. Pinned exactly, as SwiftPM's ranges do not
        // select prereleases; this kit's API exposes its `ReloadMode` and `ReloadOutcome`, so move it only with a release of this kit.
        .package(url: "git@github.com:jpurnell/SwiftTLSKit.git", exact: "1.0.0-beta.1"),
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.4.3"),
    ],
    targets: [
        .target(
            name: "SwiftHTTPService",
            dependencies: [
                .product(name: "HTTPTypes", package: "swift-http-types"),
            ],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ]
        ),
        .target(
            name: "SwiftHTTPServiceNIO",
            dependencies: [
                "SwiftHTTPService",
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "NIOExtras", package: "swift-nio-extras"),
                .product(name: "NIOTLS", package: "swift-nio"),
                .product(name: "NIOHTTP2", package: "swift-nio-http2"),
                .product(name: "NIOHPACK", package: "swift-nio-http2"),
                .product(name: "SwiftTLSKit", package: "SwiftTLSKit"),
            ],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ]
        ),
        .testTarget(
            name: "SwiftHTTPServiceNIOTests",
            dependencies: [
                "SwiftHTTPServiceNIO",
                "SwiftHTTPService",
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOEmbedded", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOTLS", package: "swift-nio"),
                .product(name: "NIOHTTP2", package: "swift-nio-http2"),
                .product(name: "NIOHPACK", package: "swift-nio-http2"),
                .product(name: "NIOExtras", package: "swift-nio-extras"),
                .product(name: "SwiftTLSKit", package: "SwiftTLSKit"),
                // Test targets only: certificates generated when the tests run, so no key is checked in.
                .product(name: "SwiftTLSKitTestSupport", package: "SwiftTLSKit"),
                // Only to pin down why the bridge is not used (ExtrasBridgeAssumptionTests); never linked into the library.
                .product(name: "NIOHTTPTypesHTTP1", package: "swift-nio-extras"),
                .product(name: "NIOHTTPTypes", package: "swift-nio-extras"),
            ],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ]
        ),
        .testTarget(
            name: "SwiftHTTPServiceTests",
            dependencies: ["SwiftHTTPService"],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ]
        ),
    ]
)
