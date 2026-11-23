// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BisprBlow",
    platforms: [.macOS("26.0")],
    dependencies: [
        // In-process inference, so cleanup does not need LM Studio running. The MLX backend's
        // metallib is built by build.sh, because SwiftPM cannot compile Metal shaders.
        // Pinned by revision: tag 0.5.0 (edc39ef2) plus the KV-cache fixes, and the fork has no later
        // tag. The fixes: upstream's trim ran inside `assert` (skipped under
        // -O) and its text-prefix cache never matched a realistic follow-up prompt, so every call
        // re-prefilled a context that never shrank. No upstream PR yet, at the user's request.
        .package(url: "https://github.com/khicken/LocalLLMClient",
                 revision: "7741fbcdbd318ed6be9c32b2516f5062cd559b7c"),
        // Speech recognition (Parakeet on the Neural Engine). Pinned to the version benched in
        // bench/asr; a new FluidAudio means re-running bench/asr/run_all.sh before trusting it.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.18.2"),
        // Auto-updates. build.sh copies Sparkle.framework into Contents/Frameworks and signs it.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
    ],
    targets: [
        .executableTarget(
            name: "BisprBlow",
            dependencies: [
                .product(name: "LocalLLMClient", package: "LocalLLMClient"),
                .product(name: "LocalLLMClientMLX", package: "LocalLLMClient"),
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/BisprBlow",
            resources: [.copy("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)],
            // The bundle keeps Sparkle.framework in Contents/Frameworks. SwiftPM's own
            // @loader_path rpath still covers the bare CLI binary in .build/release.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        )
    ]
)
