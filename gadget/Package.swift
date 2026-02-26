// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Lolabunny",
    platforms: [
        .macOS(.v12),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-testing.git", from: "0.9.0"),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .executableTarget(
            name: "Lolabunny"
        ),
        .testTarget(
            name: "LolabunnyTests",
            dependencies: [
                "Lolabunny",
                .product(name: "Testing", package: "swift-testing"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
