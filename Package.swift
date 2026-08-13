// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LingmouCollector",
    platforms: [.macOS(.v12)],
    products: [
        .library(name: "LingmouCollectorCore", targets: ["LingmouCollectorCore"]),
        .executable(name: "lingmou-collector", targets: ["LingmouCollectorCLI"]),
    ],
    targets: [
        .target(
            name: "LingmouCollectorCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "LingmouCollectorCLI",
            dependencies: ["LingmouCollectorCore"]
        ),
        .testTarget(
            name: "LingmouCollectorCoreTests",
            dependencies: ["LingmouCollectorCore"],
            path: "tests/LingmouCollectorCoreTests"
        ),
    ],
    swiftLanguageVersions: [.v5]
)
