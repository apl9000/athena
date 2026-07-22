// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Athena",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(name: "AthenaCore", targets: ["AthenaCore"]),
        .library(name: "AthenaIndicators", targets: ["AthenaIndicators"]),
        .library(name: "AthenaBrokers", targets: ["AthenaBrokers"]),
        .library(name: "AthenaData", targets: ["AthenaData"]),
        .library(name: "AthenaBacktest", targets: ["AthenaBacktest"]),
        .library(name: "AthenaSweep", targets: ["AthenaSweep"]),
        .library(name: "AthenaMLX", targets: ["AthenaMLX"]),
    ],
    targets: [
        // MARK: - Core modules
        .target(name: "AthenaCore"),
        .target(name: "AthenaIndicators", dependencies: ["AthenaCore"]),
        .target(name: "AthenaBrokers", dependencies: ["AthenaCore"]),
        .target(name: "AthenaData", dependencies: ["AthenaCore"]),
        .target(
            name: "AthenaBacktest",
            dependencies: ["AthenaCore", "AthenaIndicators", "AthenaBrokers", "AthenaData"]
        ),

        // MARK: - Sweep module (v0.4)
        .target(
            name: "AthenaSweep",
            dependencies: ["AthenaCore", "AthenaBacktest"]
        ),

        // MARK: - MLX runner module (v0.5)
        //
        // Slice 1: seam only — delegates to EventDrivenRunner internally.
        // Later slices add mlx-swift as a conditional macOS/iOS dependency
        // and replace the delegation with real tensor dispatch behind
        // `#if canImport(MLX)` guards.
        .target(
            name: "AthenaMLX",
            dependencies: ["AthenaCore", "AthenaBacktest", "AthenaSweep"]
        ),

        // MARK: - Examples
        .executableTarget(
            name: "MACrossoverExample",
            dependencies: [
                "AthenaCore",
                "AthenaIndicators",
                "AthenaBrokers",
                "AthenaData",
                "AthenaBacktest",
            ],
            path: "Examples/MACrossover"
        ),
        .executableTarget(
            name: "BuyAndHoldExample",
            dependencies: [
                "AthenaCore", "AthenaIndicators", "AthenaBrokers",
                "AthenaData", "AthenaBacktest",
            ],
            path: "Examples/BuyAndHold"
        ),
        .executableTarget(
            name: "RSIMeanReversionExample",
            dependencies: [
                "AthenaCore", "AthenaIndicators", "AthenaBrokers",
                "AthenaData", "AthenaBacktest",
            ],
            path: "Examples/RSIMeanReversion"
        ),
        .executableTarget(
            name: "BollingerBreakoutExample",
            dependencies: [
                "AthenaCore", "AthenaIndicators", "AthenaBrokers",
                "AthenaData", "AthenaBacktest",
            ],
            path: "Examples/BollingerBreakout"
        ),
        .executableTarget(
            name: "MACDSignalExample",
            dependencies: [
                "AthenaCore", "AthenaIndicators", "AthenaBrokers",
                "AthenaData", "AthenaBacktest",
            ],
            path: "Examples/MACDSignal"
        ),
        .executableTarget(
            name: "ProtectiveStopExample",
            dependencies: [
                "AthenaCore", "AthenaIndicators", "AthenaBrokers",
                "AthenaData", "AthenaBacktest",
            ],
            path: "Examples/ProtectiveStop"
        ),
        .executableTarget(
            name: "TaxAwareExample",
            dependencies: [
                "AthenaCore", "AthenaIndicators", "AthenaBrokers",
                "AthenaData", "AthenaBacktest",
            ],
            path: "Examples/TaxAware"
        ),
        .executableTarget(
            name: "ParameterSweepExample",
            dependencies: [
                "AthenaCore",
                "AthenaIndicators",
                "AthenaBrokers",
                "AthenaData",
                "AthenaBacktest",
                "AthenaSweep",
            ],
            path: "Examples/ParameterSweep"
        ),

        // MARK: - Tests
        .testTarget(name: "AthenaCoreTests", dependencies: ["AthenaCore"]),
        .testTarget(
            name: "AthenaIndicatorsTests",
            dependencies: ["AthenaIndicators", "AthenaCore"]
        ),
        .testTarget(
            name: "AthenaBrokersTests",
            dependencies: ["AthenaBrokers", "AthenaCore"]
        ),
        .testTarget(
            name: "AthenaDataTests",
            dependencies: ["AthenaData", "AthenaCore"]
        ),
        .testTarget(
            name: "AthenaBacktestTests",
            dependencies: [
                "AthenaBacktest", "AthenaCore", "AthenaIndicators",
                "AthenaBrokers", "AthenaData",
            ]
        ),
        .testTarget(
            name: "AthenaSweepTests",
            dependencies: [
                "AthenaSweep", "AthenaCore", "AthenaIndicators",
                "AthenaBrokers", "AthenaData", "AthenaBacktest",
            ]
        ),
        .testTarget(
            name: "AthenaMLXTests",
            dependencies: [
                "AthenaMLX", "AthenaSweep", "AthenaCore",
                "AthenaBacktest",
            ]
        ),
    ]
)
