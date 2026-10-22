// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "BookooHydration",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "BookooHydrationCore", targets: ["BookooHydrationCore"]),
        .executable(name: "BookooHydration", targets: ["BookooHydration"]),
        .executable(name: "BookooHydrationCoreAssertions", targets: ["BookooHydrationCoreAssertions"])
    ],
    targets: [
        .target(
            name: "BookooHydrationCore",
            path: "Sources/BookooHydrationCore"
        ),
        .executableTarget(
            name: "BookooHydration",
            dependencies: ["BookooHydrationCore"],
            path: "Sources/BookooHydration"
        ),
        .executableTarget(
            name: "BookooHydrationCoreAssertions",
            dependencies: ["BookooHydrationCore"],
            path: "Tests/BookooHydrationCoreAssertions"
        )
    ]
)
