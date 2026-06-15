// swift-tools-version: 6.0
import PackageDescription

// Parleq.app — macOS dictation tool with preview-and-refine overlay.
//
// macOS-only by design: the on-device ASR runs on the Apple Neural
// Engine (FluidAudio Parakeet TDT v3), and the global hotkey, paste,
// and accessibility integrations all use AppKit / CGEventTap.
let package = Package(
    name: "parleq-app",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "parleq-app", targets: ["parleq-app"]),
        // asr-bench — dev-only ASR benchmark CLI. Separate product so it
        // is never part of the app bundle (make-app.sh builds only the
        // parleq-app product). Depends on FluidAudio alone, not
        // ParleqAppCore, so a build doesn't pull in MLX/Soto.
        .executable(name: "asr-bench", targets: ["asr-bench"]),
    ],
    dependencies: [
        // Soto — community Swift AWS SDK. Used for Bedrock Runtime
        // ConverseStream (the SSO + static-credentials Bedrock auth
        // paths). The full soto repo is large; we depend on the
        // BedrockRuntime product specifically. Soto handles SigV4,
        // eventstream parsing for streaming responses, and credential
        // resolution. The Bedrock-API-key path uses a hand-rolled
        // bearer-auth client (BedrockBearerProvider.swift) and bypasses
        // Soto entirely.
        //
        // Pinned to the 7.14.x line to limit supply-chain drift on
        // fresh clones. `Package.resolved` (committed) locks exact
        // versions for reviewability; bumping requires an explicit
        // `swift package update`. See CLAUDE.md for the periodic-
        // upgrade policy.
        .package(url: "https://github.com/soto-project/soto.git", "7.14.0"..<"7.15.0"),
        // FluidAudio — on-device speech recognition (Parakeet TDT v3
        // on the Apple Neural Engine) plus CTC vocabulary boosting.
        // Previously isolated in a bundled HTTP sidecar; folded into
        // the main app in v0.9.0 to drop the local listening socket,
        // simplify supervision, and shed the Hummingbird dependency.
        // Same 0.14.x pin the retired sidecar used so first-run model
        // downloads land on a known-good FluidAudio revision.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", "0.14.3"..<"0.15.0"),
        // Sparkle — auto-update framework. Checks an EdDSA-signed
        // appcast.xml on parleq.app for newer releases and runs the
        // user-prompted download/install/relaunch flow. Used by
        // thousands of Mac apps; covered in SECURITY_REVIEW.md
        // §"Auto-update" for the new network egress + signature-
        // verification posture. The corresponding public Ed25519
        // key is in Info.plist's `SUPublicEDKey`; the private key
        // lives in the maintainer's macOS Keychain (and a password-
        // manager backup) and never enters the repository.
        .package(url: "https://github.com/sparkle-project/Sparkle.git", "2.9.0"..<"2.10.0"),
        // MLX Swift — Apple-maintained on-device ML framework. Used as
        // the runtime for the on-device LLM cleanup tier (Task 2+).
        // Pinned exact to 0.31.4 — the version the proof-of-concept was
        // validated against. Pinning the transitive resolution also keeps
        // the bundled mlx.metallib (the Metal shader library MLX dlopens
        // at runtime) matched to the exact MLX version we built/tested.
        // We now import MLX/MLXNN/MLXFast directly: VendoredGemma4Text.swift
        // (a KV-shared-aware copy of upstream's Gemma4 text model — see
        // TODO(upstream-gemma4)) builds the model graph against these APIs.
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.31.4"),
        // mlx-swift-lm — LLM inference layer built on MLX Swift. Pinned
        // to a specific commit (b95dc78) rather than a tagged release
        // because upstream main contains the Gemma4 QAT loader fixes
        // (needed for 4-bit quantised weights) that have not yet landed
        // in a tagged release. Move to the next tagged release once it
        // ships and contains these fixes.
        .package(url: "https://github.com/ml-explore/mlx-swift-lm",
                 revision: "b95dc780b4efbb35c491261bb27a06d3cf2b2e24"),
        // swift-transformers — tokeniser support (AutoTokenizer, etc.)
        // required by mlx-swift-lm at call-site. Pinned exact to 1.3.3.
        .package(url: "https://github.com/huggingface/swift-transformers", exact: "1.3.3"),
        // swift-huggingface — Hub client (HubClient) used by
        // MLXHuggingFace macros that expand at call-site; must be a
        // direct dependency of any target that imports those modules.
        // Pinned exact to 0.9.0.
        .package(url: "https://github.com/huggingface/swift-huggingface", exact: "0.9.0"),
    ],
    targets: [
        .target(
            name: "ParleqAppCore",
            dependencies: [
                .product(name: "SotoBedrockRuntime", package: "soto"),
                .product(name: "SotoSTS", package: "soto"),
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                // MLX / MLXNN / MLXFast — required directly by the vendored
                // KV-shared-aware Gemma4 text model (TODO(upstream-gemma4),
                // VendoredGemma4Text.swift). Remove these three when the
                // vendored file is deleted on upstream merge.
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXFast", package: "mlx-swift"),
                .product(name: "Tokenizers", package: "swift-transformers"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
            ],
            path: "Sources/ParleqAppCore"
        ),
        .executableTarget(
            name: "parleq-app",
            dependencies: ["ParleqAppCore"],
            path: "Sources/parleq-app"
        ),
        // asr-bench — dev-only ASR benchmark. FluidAudio-only on purpose
        // (see the product comment above). Build with
        // `swift build --product asr-bench` to avoid compiling the rest
        // of the app graph.
        .executableTarget(
            name: "asr-bench",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/asr-bench"
        ),
        .testTarget(
            name: "ParleqAppCoreTests",
            dependencies: ["ParleqAppCore"],
            path: "Tests/ParleqAppCoreTests"
        ),
    ]
)
