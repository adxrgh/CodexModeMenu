// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CodexModeMenu",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "CodexModeMenuCore", targets: ["CodexModeMenuCore"]),
        .executable(name: "CodexModeMenu", targets: ["CodexModeMenu"])
    ],
    targets: [
        .target(name: "CodexModeMenuCore"),
        .executableTarget(
            name: "CodexModeMenu",
            dependencies: ["CodexModeMenuCore"]
        ),
        .testTarget(
            name: "CodexModeMenuTests",
            dependencies: ["CodexModeMenuCore"]
        )
    ]
)
