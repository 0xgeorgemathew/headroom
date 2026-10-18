// swift-tools-version: 6.2
import PackageDescription

let strict: [SwiftSetting] = [.swiftLanguageMode(.v6)]

let package = Package(
    name: "Headroom",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "HeadroomApp", targets: ["HeadroomApp"]),
        .executable(name: "headroom", targets: ["headroom"]),
        .executable(name: "HeadroomBench", targets: ["HeadroomBench"]),
    ],
    targets: [
        // Pure value types: models, pacing, pricing, snapshot schema, formatters.
        // Foundation only. The CLI links this and nothing that touches credentials or the network.
        .target(name: "HeadroomKit", resources: [.copy("Resources/pricing.json")], swiftSettings: strict),
        // Log ingestion, provider clients, credentials, store. Never linked by the CLI.
        .target(name: "HeadroomCore", dependencies: ["HeadroomKit"], swiftSettings: strict),
        .target(name: "HeadroomCLI", dependencies: ["HeadroomKit"], swiftSettings: strict),
        .executableTarget(name: "headroom", dependencies: ["HeadroomCLI"], swiftSettings: strict),
        .executableTarget(name: "HeadroomApp", dependencies: ["HeadroomCore", "HeadroomKit"], swiftSettings: strict),
        .executableTarget(name: "HeadroomBench", dependencies: ["HeadroomCore", "HeadroomKit"], swiftSettings: strict),
        .testTarget(name: "HeadroomKitTests", dependencies: ["HeadroomKit"], swiftSettings: strict),
        .testTarget(name: "HeadroomCoreTests", dependencies: ["HeadroomCore", "HeadroomKit"], swiftSettings: strict),
        .testTarget(name: "HeadroomCLITests", dependencies: ["HeadroomCLI", "HeadroomKit"], swiftSettings: strict),
    ]
)
