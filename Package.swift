// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BluejayWispr",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "BluejayWispr",
            path: "Sources/BluejayWispr",
            resources: [.copy("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
