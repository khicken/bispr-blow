// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "fluid-runner",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.18.2"),
    ],
    targets: [
        .executableTarget(
            name: "fluid-runner",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
