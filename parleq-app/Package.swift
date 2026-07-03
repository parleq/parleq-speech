// swift-tools-version: 6.1
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
    // Concord is a PRIVATE, proprietary dependency (keavi-app/concord). It is
    // gated behind this trait — OFF BY DEFAULT — so the PUBLIC open-source repo
    // builds from source without access to that repo: SwiftPM prunes a
    // trait-gated dependency from resolution when the trait is disabled (the
    // "Lightweight (on-device)" cleanup tier is simply absent in that build).
    // Release builds enable it with `swift build --traits Concord` (wired into
    // scripts/make-app.sh). Enabling the trait also defines the `Concord`
    // compilation condition used by `#if Concord` throughout the sources.
    traits: [
        .trait(name: "Concord",
               description: "Bundle the proprietary on-device Concord 'Lightweight' cleanup tier."),
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
        //
        // PINNED to the fork tag 0.15.4-encoder.2 (see "TAGGED FORK PIN" at the
        // bottom of this block) — the 0.15.4 line PLUS an opt-in encoder-feature
        // patch for voice enrollment AND the final-window tail-drop rescue
        // (#747). The over-fire history below is WHY we set
        // `spotterRescueEnabled=false` in LocalASR to hold 0.14.5-equivalent
        // over-fire behavior on the 0.15.4 line. DO NOT bump FluidAudio without
        // running the REGRESSION GATE below AND re-evaluating that flag.
        //
        // HISTORY — why 0.14.5 was the prior exact pin and why the flag exists:
        // Root cause: upstream commit 410044d1 ("Fix/word boost
        // improvements", PR #634), FIRST RELEASED IN 0.14.8. It reworked
        // the CTC vocab-rescoring pipeline — blank-aware DP rewrite (changes
        // the similarity scores), a -1-frame TDT emission-delay timestamp
        // correction, and defaultMarginSeconds 0.5 -> 0.10. Validated only
        // against earnings22 (company names) + FDA drug-name benchmarks —
        // distinctive multi-syllable terms where false positives on common
        // English are structurally rare. For Parleq's short / English-
        // rhyming dictionary terms it over-fires: ordinary words get
        // replaced by dictionary terms, even with LLM cleanup disabled.
        // Our explicit cbw=2.0 / minSimilarity=0.65 overrides can't
        // compensate — the DP rewrite changes the scores those thresholds
        // gate, and the margin/timestamp changes come from the core ASR
        // path (config: .default), not overridable per-call.
        //
        // The bug is 0.14.8-specific: PR #634 is the only biasing-path
        // commit in 0.14.5..0.14.8, and it landed in 0.14.8. Confirmed by
        // version bisect (0.24.1=0.14.5 vs 0.24.2=0.15.3) AND by the bench
        // over-fire arm: identical generic dictionary + 54-clip overfire
        // corpus produced 12 over-fires on 0.14.5 vs 52 on 0.14.8 (~4x,
        // spreading from 2 terms to 6). We previously pinned 0.14.5 — the version
        // 0.24.1 shipped and the empirically-verified-good config — now superseded
        // by the fork tag below with spotterRescueEnabled=false holding the baseline.
        //
        // NB 0.14.5 is the pre-regression baseline, not zero over-fire:
        // short collision-prone terms (CRAN~"ran", Redis~"ready") still
        // over-fire ~12/54 with LLM cleanup OFF; that residual is inherent
        // to ASR biasing on such terms (mitigate per-term with
        // biasing:"llmOnly"), NOT the PR #634 regression.
        //
        // The 0.25.1 hotfix tried to revert but used a "0.14.3..<0.15.0"
        // range, which SwiftPM resolved to the newest in-range 0.14.8 —
        // still buggy. An exact pin is required, not a range. Widen only
        // after the upstream fix is tagged AND the gate below passes.
        //
        // REGRESSION GATE before any future bump:
        //   python3 bench/gen_fixtures.py --corpora overfire \
        //     --manifest bench/fixtures/manifest-overfire.json
        //   swift build --product asr-bench
        //   ./.build/debug/asr-bench --manifest bench/fixtures/manifest-overfire.json \
        //     --wav-dir bench/fixtures --paths batch \
        //     --dictionary bench/dictionary-overfire.json --out bench/results/overfire-<ver>.json
        //   python3 bench/score_overfire.py bench/results/overfire-<ver>.json \
        //     bench/dictionary-overfire.json   # expect total_overfires ~12, alarm near ~52
        // TAGGED FORK PIN (voice-enrollment, 0.29.0; tail-drop rescue, this PR):
        // pinned exactly to the fork tag 0.15.4-encoder.2 (jonyoder/FluidAudio),
        // a fork of FluidInference/FluidAudio's 0.15.4 line that adds an opt-in
        // encoder-feature-exposure patch (ASRResult.encoderFeatures) needed by
        // the voiceprint acoustic-disambiguation gate. Because this rides the
        // 0.15.4 line rather than 0.14.5, we set spotterRescueEnabled=false in
        // LocalASR to keep 0.14.5-equivalent over-fire behavior (the spotter
        // rescue from PR #634 is the over-fire trigger; disabling it restores
        // the pre-regression baseline). Drop this fork and return to a pinned
        // upstream FluidAudio once a tagged upstream release exposes encoder
        // features. See parleq-fluidaudio-0.14.5-pin / the voice-enrollment plan.
        //
        // 0.15.4-encoder.2 (07d617f2 = encoder.1 + rescue only) adds an
        // always-on "tail-chunk rescue" on the decode path: on quiet, long-form
        // dictation the final ASR window could decode all-blank and silently
        // drop the last few words — the rescue recovers that final window.
        // Reported upstream as FluidInference/FluidAudio#747. The encoder graph
        // is UNCHANGED (rescue is decode-path only), so voiceprints stay valid
        // and spotterRescueEnabled stays false (that's the unrelated CTC vocab
        // knob, not this tail rescue).
        .package(url: "https://github.com/jonyoder/FluidAudio.git", exact: "0.15.4-encoder.2"),
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
        // Concord — the proprietary on-device second-pass correction
        // engine (deterministic numbers/compounds + confidence-gated
        // dictionary correction; "Lightweight (on-device)" cleanup tier).
        // Parleq depends on it through the public API only (SecondPassCleaner).
        // Private repo (keavi-app/concord); pinned tag like the other deps.
        // For local Concord co-dev, override without committing:
        //   swift package edit Concord --path ../concord
        .package(url: "https://github.com/keavi-app/concord.git", exact: "0.5.0"),
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
                // Gated on the `Concord` trait: present only in release builds
                // (`--traits Concord`); pruned from resolution otherwise so the
                // public repo builds without access to the private concord repo.
                .product(name: "Concord", package: "Concord",
                         condition: .when(traits: ["Concord"])),
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
