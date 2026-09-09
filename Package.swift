// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Vibemusic",
    platforms: [.macOS(.v15)],
    targets: [
        .target(
            name: "VibemusicCore",
            resources: [.process("Resources/library.json")]
        ),
        .executableTarget(
            name: "Vibemusic",
            dependencies: ["VibemusicCore"]
        ),
        .testTarget(
            name: "VibemusicTests",
            dependencies: ["VibemusicCore"]
        ),
    ]
)
