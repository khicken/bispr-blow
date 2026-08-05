// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BluejayWispr",
    platforms: [.macOS("26.0")],
    dependencies: [
        // In-process inference, so cleanup does not need LM Studio running.
        //
        // Not mlx-swift directly: mlx-swift's own README states SwiftPM on the command line cannot
        // build its Metal shaders, and a missing `default.metallib` makes MLX **abort the process**
        // rather than throw. Getting it working needs Xcode's multi-GB Metal Toolchain component plus
        // a metallib step in build.sh, re-run on every MLX bump.
        //
        // This wraps llama.cpp's precompiled xcframework (shaders built in llama.cpp's CI), so plain
        // `swift build` works with no toolchain and no build.sh change — and it reaches Linux, which
        // MLX cannot. It also carries MLX and FoundationModels backends behind one API, so revisiting
        // that choice later is configuration rather than re-integration.
        // Pinned by revision, not by version, and that is forced rather than chosen: its llama.cpp C
        // target uses `unsafeFlags`, which SwiftPM forbids in a dependency resolved by version
        // ("contains unsafe build flags"). Their README works around it with `branch: "main"`; a
        // revision is the same permission with none of the drift. The fork is tag 0.5.0
        // (edc39ef2) plus the KV-cache fixes: upstream's trim ran inside `assert` (skipped under
        // -O) and its text-prefix cache never matched a realistic follow-up prompt, so every call
        // re-prefilled a context that never shrank. No upstream PR yet, at the user's request.
        .package(url: "https://github.com/khicken/LocalLLMClient",
                 revision: "f7b7c8de2849cb6493306d0a79e58c5fd3058f7f")
    ],
    targets: [
        .executableTarget(
            name: "BluejayWispr",
            dependencies: [
                .product(name: "LocalLLMClient", package: "LocalLLMClient"),
                .product(name: "LocalLLMClientLlama", package: "LocalLLMClient"),
            ],
            path: "Sources/BluejayWispr",
            resources: [.copy("Resources")],
            // `.Cxx` is required, not preferred: LocalLLMClientLlamaC's umbrella header hard-errors
            // ("needs to be compiled in C++ interoperability mode") unless the importing target
            // enables it too, so it propagates from the dependency to this whole target.
            swiftSettings: [.swiftLanguageMode(.v5), .interoperabilityMode(.Cxx)]
        )
    ]
)
