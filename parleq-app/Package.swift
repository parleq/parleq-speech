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
    ],
    targets: [
        .target(
            name: "ParleqAppCore",
            dependencies: [
                .product(name: "SotoBedrockRuntime", package: "soto"),
                .product(name: "SotoSTS", package: "soto"),
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/ParleqAppCore"
        ),
        .executableTarget(
            name: "parleq-app",
            dependencies: ["ParleqAppCore"],
            path: "Sources/parleq-app"
        ),
        .testTarget(
            name: "ParleqAppCoreTests",
            dependencies: ["ParleqAppCore"],
            path: "Tests/ParleqAppCoreTests"
        ),
    ]
)
