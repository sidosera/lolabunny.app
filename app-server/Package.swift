// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "LolabunnyServer",
    platforms: [
        .macOS(.v12),
    ],
    products: [
        .executable(name: "lolabunny", targets: ["lolabunny"]),
    ],
    targets: [
        .executableTarget(name: "lolabunny")
    ],
    swiftLanguageModes: [.v6]
)
