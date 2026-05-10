// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "fluidaudio-sidecar",
    platforms: [
        .macOS(.v14),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.4"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "fluidaudio-sidecar",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "Hummingbird", package: "hummingbird"),
            ],
            path: "Sources"
        ),
    ]
)
