// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "EidolonCore",
    platforms: [
        .iOS(.v26),
        .macOS(.v14),
    ],
    products: [
        .library(name: "EidolonCore", targets: ["EidolonCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
        .package(url: "https://github.com/weichsel/ZIPFoundation", from: "0.9.19"),
    ],
    targets: [
        .target(
            name: "EidolonCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ]
        ),
        .executableTarget(
            name: "prompt-oracle",
            dependencies: ["EidolonCore"],
            path: "Sources/PromptOracle"
        ),
        .testTarget(
            name: "EidolonCoreTests",
            dependencies: [
                "EidolonCore",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ],
            resources: [.copy("Resources")]
        ),
    ]
)
