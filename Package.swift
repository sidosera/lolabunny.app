// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "Lolabunny",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "lolabunny-macos-app", targets: ["LolabunnyMacOSApp"]),
        .executable(name: "lolabunny-server", targets: ["LolabunnyServer"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ChrisGVE/LuaSwift.git", from: "1.12.4"),
        .package(url: "https://github.com/Frizlab/swift-xdg.git", from: "2.0.1"),
    ],
    targets: [
        .target(
            name: "LolabunnyMacOSAppCore",
            dependencies: [
                .product(name: "XDG", package: "swift-xdg"),
            ],
            path: "Sources/LolabunnyMacOSAppCore",
            resources: [
                .process("Resources"),
            ]
        ),
        .executableTarget(
            name: "LolabunnyMacOSApp",
            dependencies: [
                "LolabunnyMacOSAppCore",
                "LolabunnyServerCore",
            ],
            path: "Sources/LolabunnyMacOSApp"
        ),
        .target(
            name: "LolabunnyServerCore",
            dependencies: [
                .product(name: "LuaSwift", package: "LuaSwift"),
            ],
            path: "Sources/LolabunnyServerCore",
            resources: [
                .process("Resources"),
            ]
        ),
        .executableTarget(
            name: "LolabunnyServer",
            dependencies: ["LolabunnyServerCore"],
            path: "Sources/LolabunnyServer"
        ),
        .testTarget(
            name: "LolabunnyMacOSAppCoreTests",
            dependencies: [
                "LolabunnyMacOSAppCore",
                "LolabunnyServerCore",
            ],
            path: "Tests/LolabunnyMacOSAppCoreTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
