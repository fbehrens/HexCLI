// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HexCLI",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "hex-cli", targets: ["HexCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
        .package(url: "https://github.com/argmaxinc/WhisperKit", branch: "main"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", branch: "main"),
    ],
    targets: [
        .executableTarget(
            name: "HexCLI",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ]
        ),
    ]
)
