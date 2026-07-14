// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "Lolabunny",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "widget", targets: ["LolabunnyWidget"]),
        .library(name: "LolabunnyWidgetCore", targets: ["LolabunnyWidgetCore"]),
        .executable(name: "monolith-app", targets: ["LolabunnyMonolithApp"]),
        .library(name: "LolabunnyWidgetServerCore", targets: ["LolabunnyWidgetServerCore"]),
        .executable(name: "widget-server", targets: ["LolabunnyWidgetServer"]),
    ],
    dependencies: [
        .package(url: "https://github.com/tsolomko/SWCompression.git", from: "4.8.6"),
        .package(url: "https://github.com/Frizlab/swift-xdg.git", from: "2.0.1"),
    ],
    targets: [
        .executableTarget(
            name: "LolabunnyWidget",
            dependencies: ["LolabunnyWidgetCore"],
            path: "Sources/LolabunnyWidget"
        ),
        .target(
            name: "LolabunnyWidgetCore",
            dependencies: [
                "SWCompression",
                .product(name: "XDG", package: "swift-xdg"),
            ],
            path: "Sources/LolabunnyWidgetCore",
            resources: [
                .process("Resources"),
            ]
        ),
        .executableTarget(
            name: "LolabunnyMonolithApp",
            dependencies: ["LolabunnyDistributionSupport"],
            path: "Sources/LolabunnyMonolithApp"
        ),
        .target(
            name: "LolabunnyDistributionSupport",
            dependencies: ["LolabunnyWidgetServerCore"],
            path: "Sources/LolabunnyDistributionSupport"
        ),
        .target(
            name: "LolabunnyWidgetServerCore",
            path: "Sources/LolabunnyWidgetServerCore"
        ),
        .executableTarget(
            name: "LolabunnyWidgetServer",
            dependencies: ["LolabunnyWidgetServerCore"],
            path: "Sources/LolabunnyWidgetServer"
        ),
        .testTarget(
            name: "LolabunnyWidgetCoreTests",
            dependencies: [
                "LolabunnyWidgetCore",
                "LolabunnyDistributionSupport",
            ],
            path: "Tests/LolabunnyWidgetCoreTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
