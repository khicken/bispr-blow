// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BisprBlow",
    platforms: [.macOS("26.0")],
    dependencies: [
        // In-process inference, so cleanup does not need LM Studio running. The MLX backend's
        // metallib is built by build.sh, because SwiftPM cannot compile Metal shaders.
        // Pinned by revision, not by version, and that is forced rather than chosen: its llama.cpp C
        // target uses `unsafeFlags`, which SwiftPM forbids in a dependency resolved by version
        // ("contains unsafe build flags"). Their README works around it with `branch: "main"`; a
        // revision is the same permission with none of the drift. The fork is tag 0.5.0
        // (edc39ef2) plus the KV-cache fixes: upstream's trim ran inside `assert` (skipped under
        // -O) and its text-prefix cache never matched a realistic follow-up prompt, so every call
        // re-prefilled a context that never shrank. No upstream PR yet, at the user's request.
        .package(url: "https://github.com/khicken/LocalLLMClient",
                 revision: "7741fbcdbd318ed6be9c32b2516f5062cd559b7c")
    ],
    targets: [
        .executableTarget(
            name: "BisprBlow",
            dependencies: [
                .product(name: "LocalLLMClient", package: "LocalLLMClient"),
                .product(name: "LocalLLMClientMLX", package: "LocalLLMClient"),
            ],
            path: "Sources/BisprBlow",
            resources: [.copy("Resources")],
            // `.Cxx` is required, not preferred: LocalLLMClientLlamaC's umbrella header hard-errors
            // ("needs to be compiled in C++ interoperability mode") unless the importing target
            // enables it too, so it propagates from the dependency to this whole target.
            swiftSettings: [.swiftLanguageMode(.v5), .interoperabilityMode(.Cxx)]
        )
    ]
)
