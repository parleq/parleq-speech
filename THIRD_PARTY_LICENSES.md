# Third-Party Software & Licenses

Parleq is built on the open-source projects listed below. The Parleq
project itself is distributed under the Apache License, Version 2.0
(see [LICENSE](LICENSE)). All redistributable build-time and run-time
dependencies are under permissive licenses (Apache-2.0; one nested
component is MIT). There are no GPL, AGPL, SSPL, or other copyleft
dependencies, and no commercial-use restrictions.

This document satisfies the attribution and notice-propagation
requirements of Apache License 2.0 §4 for Parleq's redistributors;
the per-package upstream notices are aggregated in
[`NOTICE`](NOTICE).

## At a glance

| Category | Count | License |
|---|---|---|
| Direct SwiftPM dependencies (parleq-app) | 2 | Apache-2.0 |
| Transitive SwiftPM dependencies | 25 | Apache-2.0 |
| Embedded MIT-licensed component (inside swift-nio) | 1 | MIT |
| Apple system frameworks | n/a | Bundled with macOS — no attribution required |
| Run-time downloaded model weights | 2 | See [Model weights](#model-weights) below |

Total unique third-party packages bundled in the .app: **27**.

Note: as of v0.9.0 there is only one SwiftPM tree — the retired
`third_party/fluidaudio-sidecar/` package was folded into the main
`parleq-app` target, dropping Hummingbird as a dependency.

---

## SwiftPM dependencies

### Local ASR (in-process)

| Package | Version | License | Source | Used for |
|---|---|---|---|---|
| FluidAudio | 0.14.3 | Apache-2.0 | https://github.com/FluidInference/FluidAudio | Parakeet TDT v3 ASR + CTC keyword spotting on the Apple Neural Engine. Called directly from `LocalASR.swift` since v0.9.0; previously wrapped in a bundled HTTP sidecar that has now been retired. |

### LLM cleanup (AWS Bedrock path)

| Package | Version | License | Source | Used for |
|---|---|---|---|---|
| Soto | 7.14.0 | Apache-2.0 | https://github.com/soto-project/soto | AWS Bedrock Runtime client (ConverseStream against Anthropic Claude / OpenAI GPT-OSS) |
| Soto Core | 7.13.0 | Apache-2.0 | https://github.com/soto-project/soto-core | Soto's SigV4 signer + eventstream parsing |

The Gemini provider talks to Google's HTTP API directly with no SDK,
so no Gemini-specific package is bundled.

### Apple Swift ecosystem (transitive)

| Package | Version | License | Source |
|---|---|---|---|
| swift-algorithms | 1.2.1 | Apache-2.0 | https://github.com/apple/swift-algorithms |
| swift-asn1 | 1.7.0 | Apache-2.0 | https://github.com/apple/swift-asn1 |
| swift-async-algorithms | 1.1.3 | Apache-2.0 | https://github.com/apple/swift-async-algorithms |
| swift-atomics | 1.3.0 | Apache-2.0 | https://github.com/apple/swift-atomics |
| swift-certificates | 1.19.1 | Apache-2.0 | https://github.com/apple/swift-certificates |
| swift-collections | 1.4.1 | Apache-2.0 | https://github.com/apple/swift-collections |
| swift-configuration | 1.2.0 | Apache-2.0 | https://github.com/apple/swift-configuration |
| swift-crypto | 4.5.0 | Apache-2.0 | https://github.com/apple/swift-crypto |
| swift-distributed-tracing | 1.4.1 | Apache-2.0 | https://github.com/apple/swift-distributed-tracing |
| swift-http-structured-headers | 1.7.0 | Apache-2.0 | https://github.com/apple/swift-http-structured-headers |
| swift-http-types | 1.5.1 | Apache-2.0 | https://github.com/apple/swift-http-types |
| swift-log | 1.12.0 | Apache-2.0 | https://github.com/apple/swift-log |
| swift-metrics | 2.10.1 | Apache-2.0 | https://github.com/apple/swift-metrics |
| swift-nio | 2.99.0 | Apache-2.0 | https://github.com/apple/swift-nio |
| swift-nio-extras | 1.34.0 | Apache-2.0 | https://github.com/apple/swift-nio-extras |
| swift-nio-http2 | 1.43.0 | Apache-2.0 | https://github.com/apple/swift-nio-http2 |
| swift-nio-ssl | 2.37.0 | Apache-2.0 | https://github.com/apple/swift-nio-ssl |
| swift-nio-transport-services | 1.28.0 | Apache-2.0 | https://github.com/apple/swift-nio-transport-services |
| swift-numerics | 1.1.1 | Apache-2.0 | https://github.com/apple/swift-numerics |
| swift-service-context | 1.3.0 | Apache-2.0 | https://github.com/apple/swift-service-context |
| swift-system | 1.6.4 | Apache-2.0 | https://github.com/apple/swift-system |

### Server / transport (transitive)

| Package | Version | License | Source |
|---|---|---|---|
| async-http-client | 1.33.1 | Apache-2.0 | https://github.com/swift-server/async-http-client |
| jmespath.swift | 1.0.3 | Apache-2.0 | https://github.com/jmespath/jmespath.swift |
| swift-service-lifecycle | 2.11.0 | Apache-2.0 | https://github.com/swift-server/swift-service-lifecycle |

### Embedded components

- **CNIOLLHTTP** — MIT — Vendored inside `swift-nio` at
  `Sources/CNIOLLHTTP/`. Originally
  [llhttp](https://github.com/nodejs/llhttp) by Fedor Indutny. The
  full MIT license text is preserved at
  `swift-nio/Sources/CNIOLLHTTP/LICENSE` in the upstream checkout.
  MIT is more permissive than Apache-2.0 and adds no obligations
  beyond keeping the license file with the source.

---

## Apple system frameworks

Parleq links against the following macOS system frameworks. These ship
with macOS and require no separate attribution:

- **AVFoundation** — microphone capture and audio conversion
- **AppKit / SwiftUI** — overlay panel, menu bar, Settings window
- **CoreGraphics** — `CGEventTap` for the global hotkey listener
- **AudioToolbox** / **CoreAudio** — input device routing (built-in
  mic preference when the system default is Bluetooth)
- **Security** — Keychain (`kSecClassGenericPassword`) for the
  Gemini API key
- **ServiceManagement** — login-item registration (when launch-on-
  login is enabled in Settings)

---

## Model weights <a name="model-weights"></a>

FluidAudio downloads CoreML model archives at first launch. These
are NOT shipped inside the .app — they live at
`~/Library/Application Support/FluidAudio/Models/` after first run.

| Model | Used for | Source | Approx size |
|---|---|---|---|
| Parakeet TDT v3 (0.6B) — CoreML | Primary speech recognition (every dictation) | https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml | ~150 MB |
| Parakeet TDT-CTC 110M — CoreML | Optional CTC keyword-spotting + rescoring; only downloaded when the user populates the Custom Dictionary | https://huggingface.co/FluidInference/parakeet-tdt-ctc-110m-coreml | ~97 MB |

Both archives are CoreML conversions of NVIDIA NeMo Parakeet
checkpoints, published by FluidInference on Hugging Face.

**License caveat for redistribution:** these weights are governed by
the upstream NVIDIA model license that applies to the underlying
NeMo checkpoint. Parleq does not redistribute the weights inside the
.app bundle — the user's machine downloads them from Hugging Face on
first run, so the model license binds the user, not Parleq's
release artifact. If you intend to ship Parleq commercially, mirror
the weights, or redistribute them in any other way, **read the
license terms on the Hugging Face pages above and confirm the
intended use is permitted.** Personal use and the local-only
inference path Parleq exercises today are uncontroversial; broader
redistribution is not.

---

## External services contacted at runtime

Parleq makes outbound network calls to:

- **Google Gemini API** — direct HTTPS to `generativelanguage.googleapis.com`. Subject to Google's [Generative AI APIs Additional Terms of Service](https://ai.google.dev/terms). The user supplies their own API key.
- **AWS Bedrock Runtime** — via Soto. Subject to the user's AWS account agreement and the model-vendor EULAs (Anthropic for Claude, OpenAI for GPT-OSS). The user authenticates with their own SSO session.
- **Hugging Face** — anonymous reads only, for the FluidAudio model downloads above. Subject to [Hugging Face's Terms of Service](https://huggingface.co/terms-of-service).
- **GitHub raw content** (LiteLLM JSON pricing snapshot) — public read of `BerriAI/litellm`'s `model_prices_and_context_window.json`, cached locally for 24 h. Disable with `PARLEQ_DISABLE_LIVE_PRICING=1`.

No telemetry endpoint is contacted. No third-party analytics SDKs
are bundled.

---

## Compatibility for redistribution

All ship-time dependencies are permissively licensed and compatible
with redistribution as a notarized macOS application under
Apache-2.0. Specifically:

- **No copyleft.** No GPL/LGPL/AGPL/MPL/SSPL packages anywhere in
  the tree. Distribution as a closed-source binary is permitted by
  every license in use, though Parleq itself is open.
- **No source-code-disclosure trigger.** Apache-2.0 and MIT do not
  require derivative-work source publication.
- **Attribution discharged** by:
  1. The project's own `LICENSE` file (Apache-2.0 text + copyright
     line).
  2. The `NOTICE` file (aggregated upstream notices).
  3. This document, which catalogs every package, version, and
     source URL.
- **No trademark surprises.** None of the dependency names are
  trademarks that restrict downstream use beyond the standard
  Apache-2.0 §6 trademark clause.

When packaging a binary for distribution outside the source tree
(e.g. uploading the notarized `.app` to a GitHub Release), include
`LICENSE`, `NOTICE`, and `THIRD_PARTY_LICENSES.md` either alongside
the download or inside `Parleq.app/Contents/Resources/`.

---

## Audit trail

This list is regenerated by re-running `swift package show-dependencies`
in `parleq-app/` and cross-referencing each `Package.resolved` against
the LICENSE file in that package's `.build/checkouts/<name>/`
directory. The current audit captures the dependency state at the
v0.9.0 release (2026-05-13).

If you upgrade a dependency, re-run the audit and update this file.
