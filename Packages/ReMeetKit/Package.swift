// swift-tools-version: 6.2
import PackageDescription

// Non-UI logic for ReMeet: on-disk meeting format, pipeline bookkeeping, text processing
// and theme math. No dependencies, so it builds and tests quickly with `swift test`.
let package = Package(
    name: "ReMeetKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "ReMeetKit", targets: ["ReMeetKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "ReMeetKit",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .testTarget(name: "ReMeetKitTests", dependencies: ["ReMeetKit"], resources: [.copy("Fixtures")]),
    ]
)
