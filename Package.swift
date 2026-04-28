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
    ],
    targets: [
        .target(name: "AthenaCore"),
        .target(name: "AthenaIndicators", dependencies: ["AthenaCore"]),
        .target(name: "AthenaBrokers", dependencies: ["AthenaCore"]),
        .target(name: "AthenaData", dependencies: ["AthenaCore"]),
        .target(
            name: "AthenaBacktest",
            dependencies: ["AthenaCore", "AthenaIndicators", "AthenaBrokers", "AthenaData"]
        ),
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
        .testTarget(name: "AthenaCoreTests", dependencies: ["AthenaCore"]),
        .testTarget(name: "AthenaIndicatorsTests", dependencies: ["AthenaIndicators", "AthenaCore"]),
        .testTarget(name: "AthenaBrokersTests", dependencies: ["AthenaBrokers", "AthenaCore"]),
        .testTarget(name: "AthenaDataTests", dependencies: ["AthenaData", "AthenaCore"]),
        .testTarget(name: "AthenaBacktestTests", dependencies: ["AthenaBacktest", "AthenaCore", "AthenaIndicators", "AthenaBrokers", "AthenaData"]),
    ]
)
