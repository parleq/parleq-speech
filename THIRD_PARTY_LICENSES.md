# Third-Party Software & Licenses

Parleq is built on the open-source projects listed below. The Parleq
project itself is distributed under the Apache License, Version 2.0
(see [LICENSE](LICENSE)). All redistributable build-time and run-time
dependencies are under permissive licenses (Apache-2.0, MIT, 2-clause
BSD, and zlib-style). There are no GPL, AGPL, SSPL, or other copyleft
dependencies, and no commercial-use restrictions.

This document satisfies the attribution and notice-propagation
requirements of Apache License 2.0 §4 (and the MIT/BSD attribution
clauses) for Parleq's redistributors; the per-package upstream
notices are aggregated in [`NOTICE`](NOTICE). `LICENSE`, `NOTICE`,
and this file are also copied into `Parleq.app/Contents/Resources/`
at build time so the notarized .app physically carries the
attribution required for binary redistribution. An "Open Source
Licenses" item in the menu-bar dropdown opens the canonical web
copy for users who want a clickable view.

## At a glance

| Category | Count | License |
|---|---|---|
| Direct SwiftPM dependencies (parleq-app) | 7 | 4× Apache-2.0 (FluidAudio, Soto, swift-transformers, swift-huggingface); 3× MIT (Sparkle, mlx-swift, mlx-swift-lm) |
| Transitive SwiftPM dependencies | 29 | Predominantly Apache-2.0 and MIT (e.g. yyjson is MIT) |
| Components embedded inside SwiftPM dependencies | 5 | 1× MIT (llhttp, inside swift-nio); 1× zlib-style (ed25519-sparkle, inside Sparkle); 2× 2-clause BSD (bsdiff inside Sparkle, fastcluster inside FluidAudio); 1× Apache-2.0 (VBx, inside FluidAudio) |
| Vendored source in-tree | 1 | MIT — `VendoredGemma4Text.swift` (copied from mlx-swift-lm; see [Embedded components](#embedded-components) below) |
| Apple system frameworks | n/a | Bundled with macOS — no attribution required |
| Run-time downloaded model weights | 3 | See [Model weights](#model-weights) below |

Total unique top-level third-party packages bundled in the .app: **36**.

Note: as of v0.9.0 there is only one SwiftPM tree — the retired
`third_party/fluidaudio-sidecar/` package was folded into the main
`parleq-app` target, dropping Hummingbird as a dependency. Sparkle
was added in v0.10.0 for auto-updates. mlx-swift, mlx-swift-lm,
swift-transformers, and swift-huggingface were added for the on-device
cleanup option (see §"On-device LLM cleanup" below).

---

## SwiftPM dependencies

### Local ASR (in-process)

| Package | Version | License | Source | Used for |
|---|---|---|---|---|
| FluidAudio | 0.15.3 | Apache-2.0 | https://github.com/FluidInference/FluidAudio | Parakeet TDT v3 ASR + CTC keyword spotting on the Apple Neural Engine. Called directly from `LocalASR.swift` since v0.9.0; previously wrapped in a bundled HTTP sidecar that has now been retired. |

### LLM cleanup (AWS Bedrock path)

| Package | Version | License | Source | Used for |
|---|---|---|---|---|
| Soto | 7.14.0 | Apache-2.0 | https://github.com/soto-project/soto | AWS Bedrock Runtime client (ConverseStream against Anthropic Claude / OpenAI GPT-OSS) + STS client (AssumeRoleWithWebIdentity for corporate OIDC sign-in) |
| Soto Core | 7.13.0 | Apache-2.0 | https://github.com/soto-project/soto-core | Soto's SigV4 signer + eventstream parsing |

The Gemini provider talks to Google's HTTP API directly with no SDK,
so no Gemini-specific package is bundled. Vertex AI and Azure OpenAI
also use direct HTTPS (URLSession) with no SDK.

### Auto-update

| Package | Version | License | Source | Used for |
|---|---|---|---|---|
| Sparkle | 2.9.1 | MIT | https://github.com/sparkle-project/Sparkle | EdDSA-verified appcast checks + user-prompted download/install/relaunch flow. Added in v0.10.0. Bundled as `Parleq.app/Contents/Frameworks/Sparkle.framework` (plus the framework's nested XPC services and helper tool). |

### On-device LLM cleanup

| Package | Version | License | Source | Used for |
|---|---|---|---|---|
| mlx-swift | 0.31.4 | MIT | https://github.com/ml-explore/mlx-swift | Apple MLX machine-learning framework for Swift. Provides the Metal-accelerated compute graph, quantized-linear operators, and KV-cache primitives used by the on-device cleanup tier. The prebuilt Metal shader library (`mlx.metallib`) is fetched from the matching release asset at build time by `parleq-app/scripts/fetch-metallib.sh` (SHA-256-verified). |
| mlx-swift-lm | commit b95dc78 | MIT | https://github.com/ml-explore/mlx-swift-lm | LLM inference layer on top of MLX Swift. Provides `MLXLLM`, `MLXLMCommon`, and the KV-cache / generation-loop infrastructure. Copyright © 2024 ml-explore. The `VendoredGemma4Text.swift` in-tree file is copied from a fork of this library — see [Embedded components](#embedded-components) for details. |
| swift-transformers | 1.3.3 | Apache-2.0 | https://github.com/huggingface/swift-transformers | Swift tokeniser library from Hugging Face. Provides `AutoTokenizer` (Jinja2 chat-template evaluation + BPE/SentencePiece decoding) used by `LocalTokenizerBridge.swift`. |
| swift-huggingface | 0.9.0 | Apache-2.0 | https://github.com/huggingface/swift-huggingface | Hugging Face Hub client for Swift. Provides `HubClient` used to download and verify the on-device model checkpoint from `huggingface.co` at user request. |



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
| swift-syntax | 603.0.2 | Apache-2.0 with Runtime Library Exception | https://github.com/swiftlang/swift-syntax |
| swift-system | 1.6.4 | Apache-2.0 | https://github.com/apple/swift-system |

### Server / transport (transitive)

| Package | Version | License | Source |
|---|---|---|---|
| async-http-client | 1.33.1 | Apache-2.0 | https://github.com/swift-server/async-http-client |
| jmespath.swift | 1.0.3 | Apache-2.0 | https://github.com/jmespath/jmespath.swift |
| swift-service-lifecycle | 2.11.0 | Apache-2.0 | https://github.com/swift-server/swift-service-lifecycle |

### On-device LLM cleanup (transitive)

| Package | Version | License | Source |
|---|---|---|---|
| eventsource | 1.4.1 | MIT | https://github.com/mattt/EventSource |
| swift-jinja | 2.3.6 | Apache-2.0 | https://github.com/huggingface/swift-jinja |
| yyjson | 0.12.0 | MIT | https://github.com/ibireme/yyjson |

### Embedded components

- **CNIOLLHTTP** — MIT — Vendored inside `swift-nio` at
  `Sources/CNIOLLHTTP/`. Originally
  [llhttp](https://github.com/nodejs/llhttp) by Fedor Indutny. The
  full MIT license text is preserved at
  `swift-nio/Sources/CNIOLLHTTP/LICENSE` in the upstream checkout.
  MIT is more permissive than Apache-2.0 and adds no obligations
  beyond keeping the license file with the source.

- **ed25519-sparkle** — zlib-style — Vendored inside Sparkle at
  `Vendor/ed25519-sparkle/`. Copyright (c) 2015 Orson Peters; a
  derivative of Daniel J. Bernstein's ref10 ed25519 reference
  implementation. The license permits unrestricted use including
  commercial redistribution; the only obligations are not
  misrepresenting authorship and preserving the notice in source
  distributions. The notice ships inside Sparkle's source tree,
  which is itself attributed in `NOTICE`. Used by Sparkle to verify
  the Ed25519 enclosure signature on every downloaded update.

- **bsdiff** — 2-clause BSD — Vendored inside Sparkle at
  `Vendor/bsdiff/`. Copyright 2003–2005 Colin Percival. The 2-clause
  BSD license obliges binary redistributions to reproduce the
  copyright notice; doing so via the bundled `NOTICE` (which credits
  Sparkle and its vendored components) satisfies that. Used by
  Sparkle when applying delta-update patches to the existing .app
  bundle.

- **fastcluster** — 2-clause BSD — Vendored inside FluidAudio at
  `ThirdPartyLicenses/fastcluster-LICENSE.md`, compiled into the
  `FastClusterWrapper` C++ target that the `FluidAudio` library product
  depends on, so its object code ships inside `Parleq.app`. Copyright
  © 2011 Daniel Müllner; changes from version 1.1.24 on © Google Inc.
  The 2-clause BSD license obliges binary redistributions to reproduce
  the copyright notice; doing so here (and in the bundled `NOTICE`)
  satisfies that. Part of FluidAudio's speaker-diarization clustering.

- **VBx** — Apache-2.0 — Vendored inside FluidAudio at
  `ThirdPartyLicenses/vbx-LICENSE.md`, implemented in
  `Sources/.../Clustering/VBxClustering.swift` and compiled into the
  FluidAudio module. Variational-Bayes HMM x-vector clustering from
  Brno University of Technology (BUT Speech@FIT). Apache-2.0 requires
  preserving the license/notice on redistribution, satisfied via this
  entry and the bundled `NOTICE`. Part of FluidAudio's speaker-
  diarization clustering.

- **VendoredGemma4Text** — MIT — Source code copied from an
  mlx-swift-lm fork into
  `parleq-app/Sources/ParleqAppCore/VendoredGemma4Text.swift`. This
  file combines two files from the fork (`Gemma4.swift` and
  `Gemma4Text.swift`) with a KV-shared-layer gating fix applied on
  top of the upstream mlx-swift-lm codebase. Copyright © 2024 Apple
  Inc. Licensed under the MIT License (same as upstream mlx-swift-lm).
  The full MIT license text is reproduced at the top of the upstream
  `mlx-swift-lm` checkout under `LICENSE`. This vendored copy is a
  **temporary measure** pending the upstream fix merging into a tagged
  release; the file will be removed when the upstream mlx-swift-lm
  package is bumped to a release that includes the KV-shared fix (see
  `TODO(upstream-gemma4)` in the file header). MIT is more permissive
  than Apache-2.0 and adds no obligations beyond keeping the license
  notice with the source.

---

## Apple system frameworks

Parleq links against the following macOS system frameworks. These ship
with macOS and require no separate attribution:

- **AVFoundation** — microphone capture and audio conversion
- **AppKit / SwiftUI** — overlay panel, menu bar, Settings window
- **Combine** — reactive state in `PasteTargetTracker` and the
  overlay's reference / model badge surfaces
- **CoreGraphics** — `CGEventTap` for the global hotkey listener
  and the hold-pick click interception
- **CoreVideo** — `CVPixelBuffer` handling in the reference-window
  capture pipeline
- **AudioToolbox** / **CoreAudio** — input device routing (built-in
  mic preference when the system default is Bluetooth)
- **PDFKit** — PDF text extraction for file-picker references
- **ScreenCaptureKit** — window thumbnail and frame capture for
  reference context (with Screen Recording permission)
- **Security** — Keychain (`kSecClassGenericPassword`) for each
  provider's credentials
- **ServiceManagement** — login-item registration (when launch-on-
  login is enabled in Settings)
- **UniformTypeIdentifiers** — file-type detection for the
  reference file picker + drag-and-drop
- **Vision** — `VNRecognizeTextRequest` OCR on captured window frames

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

### On-device cleanup model (user-initiated download)

| Model | Used for | Source | Approx size |
|---|---|---|---|
| Gemma 4 E4B (QAT 4-bit, MLX) | On-device LLM cleanup — the `local` provider option | https://huggingface.co/mlx-community/gemma-4-E4B-it-qat-4bit | ~4 GB download; ~6 GB resident |

This model is **NOT shipped inside the .app** — it is downloaded at user
request (via Settings or the Setup Wizard) when the user selects the
on-device cleanup option, and is stored at
`~/Library/Application Support/Parleq/models/`. Blocking the
`huggingface.co` download leaves all cloud-provider and "no cleanup"
modes fully functional.

**License.** The upstream model is `google/gemma-4-e4b-it`, which the
Hugging Face model card lists as **Apache License 2.0**
(https://huggingface.co/google/gemma-4-e4b-it). The mlx-community
quantized conversion (`mlx-community/gemma-4-E4B-it-qat-4bit`) derives
from that base model and carries the same Apache 2.0 designation.
Verified from the HuggingFace model page; no custom Gemma Terms of Use
apply to this release — it is standard Apache 2.0. The weights are not
redistributed inside the .app; the user downloads them directly from
Hugging Face, so the model license binds the user's machine, not
Parleq's release artifact. Apache 2.0 permits personal and commercial
use with attribution; review the license at
https://ai.google.dev/gemma/docs/gemma_4_license before redistribution.

---

## External services contacted at runtime

Parleq makes outbound network calls to:

- **Google Gemini API** — direct HTTPS to `generativelanguage.googleapis.com`. Subject to Google's [Generative AI APIs Additional Terms of Service](https://ai.google.dev/terms). The user supplies their own API key.
- **AWS Bedrock Runtime** — via Soto. Subject to the user's AWS account agreement and the model-vendor EULAs (Anthropic for Claude, OpenAI for GPT-OSS). The user authenticates with their own SSO session, static IAM keys, or a scoped Bedrock API key.
- **Google Vertex AI** — direct HTTPS to `*-aiplatform.googleapis.com`. Subject to the user's GCP account terms and the Vertex AI service terms. The user authenticates via gcloud Application Default Credentials or a service-account JSON they supply.
- **Azure OpenAI** — direct HTTPS to the user's Azure resource hostname. Subject to the user's Azure agreement and Azure OpenAI service terms. The user authenticates with an API key or via Microsoft Entra ID (`az login`).
- **Sparkle appcast** — HTTPS to `parleq.app/appcast.xml` on launch + every 24 h to check for newer Parleq releases. EdDSA signature on each enclosure is verified locally before any download is installed. Disable in Settings → Updates.
- **Hugging Face** — anonymous reads only, for the FluidAudio model downloads above and (when the user selects the on-device cleanup option) the one-time Gemma 4 E4B checkpoint download (~4 GB, TLS, resume-capable). Subject to [Hugging Face's Terms of Service](https://huggingface.co/terms-of-service). Blocking `huggingface.co` leaves all cloud and "no cleanup" modes fully functional.
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
v0.11.0 release (2026-05-15) — refreshed to add Sparkle (added in
v0.10.0 for auto-updates, MIT-licensed, with two embedded vendored
components attributed above); to drop the obsolete Hummingbird
reference (the sidecar that depended on it was retired in v0.9.0); and
to add mlx-swift, mlx-swift-lm, swift-transformers, and
swift-huggingface for the on-device cleanup option, plus the vendored
`VendoredGemma4Text.swift` (MIT, from mlx-swift-lm) and the Gemma 4
E4B weights (Apache-2.0, user-downloaded, not distributed in the .app).

If you upgrade a dependency, re-run the audit and update this file.
