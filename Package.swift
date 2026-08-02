// swift-tools-version: 6.0

import PackageDescription

/// One product, one target. The framework-free geometry lives in
/// `Sources/LazyLayoutKit/Geometry/` and never imports SwiftUI — a boundary
/// enforced by `Scripts/check-geometry-is-framework-free.sh` in CI rather than
/// by a separate module, because a second *product* would imply a support
/// promise (Linux, standalone use) that this package deliberately does not make.
let package = Package(
    name: "LazyLayoutKit",
    platforms: [
        // `onScrollGeometryChange` / `ScrollGeometry`, the visible-rect feed the
        // container is built on, is iOS 18 / macOS 15. Nothing here needs iOS 27.
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(name: "LazyLayoutKit", targets: ["LazyLayoutKit"]),
        .executable(name: "LazyLayoutBenchmark", targets: ["LazyLayoutBenchmark"]),
    ],
    targets: [
        .target(
            name: "LazyLayoutKit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "LazyLayoutBenchmark",
            dependencies: ["LazyLayoutKit"],
            path: "Benchmarks/LazyLayoutBenchmark",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "LazyLayoutKitTests",
            dependencies: ["LazyLayoutKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
