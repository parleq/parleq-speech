# ASR model landscape scan — July 2026

**Date:** 2026-07-08
**Author:** Maintainer + AI assistant (research delegated to Sonnet subagents)
**Status:** Recon only — no code changes, no pin bumps. Feasibility reads to decide what (if anything) warrants a deeper spike.
**Related:** [`2026-06-15-streaming-asr-results.md`](2026-06-15-streaming-asr-results.md), [`2026-06-15-fluidaudio-0.15-biasing-regression.md`](2026-06-15-fluidaudio-0.15-biasing-regression.md), issue #100 (biasing decoupling)

## Why this scan

It had been ~3–4 weeks since we last surveyed the on-device ASR landscape (the June streaming spike). The trigger was a maintainer question: *had we ever tried [Voxtral-Mini-4B-Realtime](https://huggingface.co/mistralai/Voxtral-Mini-4B-Realtime-2602)?* We hadn't — no Mistral ASR model appears anywhere in our research. That prompted a broader re-scan of what's new and whether any of it changes Parleq's on-device ASR story.

## The decision criteria (unchanged from June)

Parleq ships FluidAudio **Parakeet TDT v3** on the Apple Neural Engine. What disqualifies an alternative is **not** raw WER or latency — Parakeet batch is already imperceptible on Apple Silicon. The two things that matter:

1. **On-device vocabulary biasing.** Parleq's custom-dictionary feature (short domain terms — acronyms, product/brand names) rides on FluidAudio's batch CTC word-boosting. Any replacement must offer a usable on-device biasing/hotword mechanism, or it's a downgrade.
2. **Footprint.** RAM is Parleq's #1 adoption blocker. A model that is materially heavier than Parakeet works against that.

Everything below is judged against those two, first.

## Summary table

| Model | On-device on Apple Silicon? | Usable on-device biasing? | Footprint vs Parakeet | Verdict |
|---|---|---|---|---|
| **FluidAudio Parakeet TDT v3** (shipping) | Yes (ANE, CoreML) | Yes (CTC boost) | baseline | **In production** |
| **Voxtral-Mini-4B-Realtime** (Mistral) | Community MLX only, ~4B params | None documented | Much heavier (≥16GB GPU BF16) | **Pass** |
| **Nemotron-3.5-ASR-Streaming-0.6B** (NVIDIA) | Yes, via sherpa-onnx | **No** — biasing is CUDA-NeMo-only; Mac path is greedy-only | ~2.0GB peak RSS (heavier) | **No-go** |
| **Canary-Qwen-2.5B / Canary-1B-v2** (NVIDIA) | Not practically | Unclear | Heavy (LLM-decoder) | Pass (server-class) |
| **Apple SpeechAnalyzer** (macOS 26) | Yes (system framework, out-of-process XPC) | Yes but weak (`contextualStrings`; **46.2% recovery vs FluidAudio 82.9%** on real corpus) | ~86MB daemon (out-of-process) | **Dead-end** — ~½ FluidAudio's recovery, knob-less, macOS-26-only |
| **Moonshine** (Useful Sensors) | Yes (compact) | Not evaluated | Lighter | Parked (RAM-thread lead) |

## Findings

### 1. FluidAudio / Parakeet-TDT-0.6B-v3 — nothing to chase (premise corrected)

The scan started from a stale assumption (that we were pinned to FluidAudio 0.14.5 and might want to adopt the new Parakeet-TDT-0.6B-v3 from [arXiv 2509.14128](https://arxiv.org/abs/2509.14128)). Reading the actual source corrected both halves:

- **We already ship Parakeet-TDT-0.6B-v3.** `LocalASR.swift:517` passes `version: .v3` — the 25-language checkpoint (`FluidInference/parakeet-tdt-0.6b-v3-coreml`), i.e. the exact arXiv-2509.14128 model. There is no newer Parakeet rev to adopt.
- **We're not on the 0.14.5 pin anymore.** `Package.swift` pins the fork `github.com/jonyoder/FluidAudio` at `exact: "0.15.4-encoder.2"` (0.15.4 base + an encoder-feature-exposure patch for voiceprint disambiguation + a tail-drop decode rescue). The move to the 0.15.x line happened during the voice-enrollment work. The PR #634 over-fire regression is handled at runtime via `spotterRescueEnabled=false` in `LocalASR.swift`, not by pinning old code.
- **One low-effort follow-up:** upstream FluidAudio **0.15.5** (2026-07-07) shipped custom-vocabulary controls — per-term CTC thresholds + an opt-in spotter-rescue disable (#647/#702/#724). These may supersede our manual `spotterRescueEnabled=false` workaround and let us shrink or retire the fork patch. Not confirmed (individual PR bodies 404'd). Gate any rebase through the over-fire bench (`bench/score_overfire.py`).

**Bottom line:** the "newer Parakeet model" question is moot — v3 is already on the ANE. The only open thread is a maintenance one (fork vs. upstream 0.15.5), not an accuracy one.

Sources: [FluidInference/FluidAudio](https://github.com/FluidInference/FluidAudio) · [v0.15.5 release](https://github.com/FluidInference/FluidAudio/releases/tag/v0.15.5) · [parakeet-tdt-0.6b-v3-coreml](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml)

### 2. Voxtral-Mini-4B-Realtime (Mistral) — pass

From the [HF model card](https://huggingface.co/mistralai/Voxtral-Mini-4B-Realtime-2602) (Apache-2.0):

- ~3.4B LM + ~970M audio encoder (causal + sliding-window attention → streaming, <500ms delay, configurable 240ms–2.4s).
- 8.72% avg WER on FLEURS @480ms across 13 languages — **worse** than our Parakeet path.
- **No vocabulary biasing / hotwords documented.**
- ≥16GB GPU in BF16 — cleanup-model weight class, far too heavy for an on-device default.
- Runtime: vLLM primary; MLX/Rust/C are community-grade; no first-class ANE/CoreML.

An open-weight *server* realtime model that happens to be Apache-2.0, not a Parleq on-device fit. Lands exactly where the June spike predicted.

### 3. Nemotron-3.5-ASR-Streaming-0.6B (NVIDIA) — no-go (spiked hands-on)

This was the interesting lead: 600M, streaming, 40 languages, native punctuation/casing, and reportedly **native word boosting / contextual biasing** — which, if usable on-device, would overturn the June "no on-device streaming biasing" blocker. We ran a hands-on spike (downloaded weights, ran inference on this Mac).

- **Runtime is fine.** A community ONNX export is merged into sherpa-onnx; `pip install sherpa-onnx` works cleanly on Apple Silicon, ~474MB int8 model, RTF ~0.09 (≈11× realtime), ~0.6s load. NVIDIA's own NeMo runtime is CUDA/Linux-only but isn't needed.
- **Biasing is a mirage on the Mac path — the decisive finding.** Word boosting lives only in the CUDA NeMo runtime ([HF discussion #11](https://huggingface.co/nvidia/nemotron-3.5-asr-streaming-0.6b/discussions/11)). sherpa-onnx hotwords require `modified_beam_search`, and the Nemotron decoder **hard-rejects anything but greedy** — passing a hotwords file *aborts the process* (confirmed empirically), matching the open, possibly-architecturally-blocked upstream issue [k2-fsa/sherpa-onnx#3572](https://github.com/k2-fsa/sherpa-onnx/issues/3572).
- **Live proof of the gap:** greedy-only transcription mangled exactly the rare terms biasing exists for — "Zephyrion"→"Zaphyrian", "Glimmerwave"→"glimmer wa", "Kestrelline three point five" dropped entirely.
- **Heavier:** ~2.0GB peak RSS during inference vs. FluidAudio Parakeet — cuts against the RAM blocker.
- License OpenMDW-1.1 (permissive) — not a factor.

**Bottom line:** the June "streaming has no usable on-device biasing API" verdict **stands**. The native biasing is real but stranded behind CUDA. Recheck only if sherpa-onnx #3572 closes.

### 4. Also noted (context, not action)

- **Canary-Qwen-2.5B** tops the Open ASR Leaderboard (5.63% WER) and **Canary-1B-v2** beats Whisper-large-v3 on English at ~10× speed ([arXiv 2509.14128](https://arxiv.org/abs/2509.14128)) — but both are SALM/LLM-decoder designs, same heavy, biasing-unclear bucket as Voxtral. Server-class.
- **Moonshine** (Useful Sensors) — the compact/low-resource streaming option; relevant to the lighter-model / RAM-blocker thread, not evaluated here.
- **Apple SpeechAnalyzer** (macOS 26) — the one native path that historically exposes custom-vocabulary hooks. Spiked separately (below).

### 5. Apple SpeechAnalyzer — worth a look, but a second biasing lane, not a replacement (spiked hands-on)

Ran a hands-on spike on macOS 26.5.2 against the *same* invented-term clips as the Nemotron spike, reading the actual `Speech.swiftinterface` SDK ground truth (not blog claims).

**Biasing works — but only through one module, via a two-tier mechanism:**

- **`SpeechTranscriber`** (Apple's "clean/simple/fast" module) exposes **zero** biasing surface. The obvious-name pick is a trap.
- **`DictationTranscriber`** is the only module with biasing, two ways:
  1. **Lightweight — `AnalysisContext.contextualStrings`**: a plain `[String]` list set via `analyzer.setContext(_:)`, no compile step, updatable mid-session.
  2. **Heavyweight — `SFCustomLanguageModelData`** → `SFSpeechLanguageModel.prepareCustomLanguageModel(...)` (compiles a real custom-LM asset, ~0.65s) → attach via `DictationTranscriber.ContentHint.customizedLanguage(...)` with an optional `weight` knob (macOS 26+).
  Both are on-device only — the new API family has no server/endpoint surface at all.

**Smell test (5 shared invented-term clips):** `contextualStrings` corrected **3 of 5** — "Zarian"→**Zephyrion**, "glimmer wave"→**Glimmerwave**, "vex Noid"→**Vexanoid**; missed Okonkwo and Kestrelline. A real biasing effect (same audio, only the context list changed), not noise. The compiled custom-LM path scored **identical 3/5** at moderate weight — no better on the misses — and at `weight=1.0` actively *degraded* the rest of the sentence. So for Parleq's exact use case (short domain terms), the **free path is the whole story**; the expensive path buys nothing here.

**Quality / latency / footprint:**
- Real-dictation quality (3 flywheel clips, local-only): fluent, well-punctuated, same register as Parakeet — with the same class of unfamiliar-proper-noun miss (Qwen→"Quinn"), exactly why biasing matters.
- Latency: sub-second batch decode (0.16–0.66s for 3–40s clips) — but this was a **file-based, non-streaming** test (`finishAfterFile: true`), so it measures batch speed, *not* first-partial/streaming latency. A real streaming-latency comparison is still owed before trusting it against FluidAudio's production numbers.
- Footprint: model runs **out-of-process** in a system XPC daemon (`localspeechrecognition.xpc`, ~86MB RSS), not in-process on the ANE like FluidAudio. Architecturally different from the current design.

**Friction & constraints:**
- **macOS-26-only — hard ceiling.** Parleq targets macOS 14+, so this could only ever be a **tiered/optional path for macOS 26+ users**, layered alongside FluidAudio — a second ASR engine and second biasing code path to maintain, for a capability that doesn't clearly beat what ships.
- Model asset via `AssetInventory` (clean async API, system-cached, not bundled). A genuinely fresh machine incurs a real download outside the app's control.
- Our file-based CLI needed **zero** entitlements and triggered no TCC prompt — but a shipped GUI app doing **live-mic** transcription may still need speech-recognition authorization; unverified, flagged.
- **Zero bundle bytes, zero licensing** — a genuine advantage over vendoring a model. But behavior/weights/asset-availability are outside our control and can shift per OS update.

**Initial read (from the 5-clip smell test):** looked like a promising free/fallback biasing lane. That read did **not** survive the real-corpus test below.

#### Follow-up: real-corpus biasing comparison vs. FluidAudio (2026-07-08)

To settle whether the ~3/5 smell-test hit rate meant anything, we ran an apples-to-apples comparison on the **full flywheel corpus** (2,235 real dictation clips). The flywheel manifest records, per clip, FluidAudio's actual biased output (`asr_transcript`), the active dictionary (`vocabulary`), and the user-final (`final`) — so SpeechAnalyzer could be scored against FluidAudio on the *same clips with the same dictionaries*, no rerun needed. Every clip was transcribed through `DictationTranscriber` twice (plain / +`contextualStrings`), and all three columns scored with the `bench/` term-presence scorers (recovery = true positives, over-fire = false positives), on the **1,992 clips** with both a non-empty `vocabulary` and a `final` (327 recovery-relevant pairs; 23,109 over-fire opportunities).

**Frame A — absolute term presence:**

| System | Recovery | Over-fire |
|---|---|---|
| FluidAudio (shipped) | **271 / 327 = 82.9%** | 76 / 23,109 = 0.33% |
| SpeechAnalyzer (plain) | 44 / 327 = 13.5% | 1 |
| SpeechAnalyzer (+contextualStrings) | **151 / 327 = 46.2%** | 9 |

**Frame B — biasing-isolated lift (boosted vs. that engine's own baseline):** FluidAudio CTC boosting **+220** recoveries (96 over-fire); SA contextualStrings **+107** (8 over-fire, ~0 collateral loss).

**Read:** both frames say the same thing — **FluidAudio recovers ~2× what SpeechAnalyzer+contextualStrings does** (82.9% vs 46.2%; +220 vs +107). contextualStrings biasing is *real and helpful* (plain 13.5% → 46.2%, +32.7pts, near-zero collateral) but far weaker than FluidAudio's tunable CTC pass. SA does win raw over-fire (9 vs 76), but partly because it fires less — and FluidAudio's over-fire is itself tunable down ~78% at its committed next-release operating point (minSim 0.65→0.75), narrowing that gap in FluidAudio's favor. Crucially, `contextualStrings` has **no weight/similarity knob** (unlike FluidAudio's `minSimilarity`), so you can't trade its recovery up — what you see is what you get. Example wins where SA+bias helped (`Clawed`→Claude, `Kiwi mark`→Keavi, `Parallel`→Parleq); it still lost many mishears FluidAudio's CTC caught.

Confounders (honest): different base ASR (Frame B controls for it and confirms the 2× gap); FluidAudio's Frame-A over-fire is a whole-hypothesis proxy that conflates biasing with base mishears/LLM rewording; single-speaker corpus (maintainer's voice); finals-not-gold (mitigated by term-presence scoring, not WER). Batch latency observed ~0.1–0.2s/clip per mode (file-based, not streaming). Full data + `verdict_summary.json` in scratchpad (`speechanalyzer-spike/`; SA transcripts contain personal text → kept local, never committed).

**VERDICT: documented dead-end.** SpeechAnalyzer+contextualStrings does **not** substantially beat FluidAudio — it recovers roughly **half** the dictionary terms, and although its over-fire is lower, the bar required beating *recovery* at comparable-or-lower over-fire, which it fails. `contextualStrings` is a soft, knob-less hint that pulls far weaker than FluidAudio's tunable CTC word-boosting. **Not worth a macOS-26-only fallback tier.** (The streaming-latency test is moot — Parleq's dictation is batch, and the batch numbers are already fine.)

Sources: [SpeechAnalyzer](https://developer.apple.com/documentation/speech/speechanalyzer) · [SpeechTranscriber](https://developer.apple.com/documentation/speech/speechtranscriber) · [SFCustomLanguageModelData](https://developer.apple.com/documentation/speech/sfcustomlanguagemodeldata) · [WWDC25 session 277](https://developer.apple.com/videos/play/wwdc2025/277/) · local SDK `Speech.swiftinterface` / `SFSpeechLanguageModel.h` (ground truth)

## Overall bottom line

Nothing scanned changes Parleq's shipping ASR path (FluidAudio Parakeet TDT v3) today:

- The "adopt a newer Parakeet model" question is **already answered** — we ship v3.
- Voxtral and Nemotron both **fail the biasing-on-device gate** (Voxtral has none; Nemotron's is CUDA-only). The June 2026 conclusion that no open streaming model offers usable on-device biasing remains intact, now re-confirmed hands-on rather than from documentation.
- **Apple SpeechAnalyzer** clears the biasing gate on-device but — tested on the full flywheel corpus — recovers only **~half** the dictionary terms FluidAudio does (46.2% vs 82.9%), with no tuning knob, and is macOS-26-only. **Closed as a dead-end**, not merely parked.

**Net: no action on the shipping path. Every alternative scanned lost to the incumbent (FluidAudio Parakeet-v3 CTC biasing) on the axis that matters. The only live follow-up is a maintenance one — whether FluidAudio 0.15.5's new vocab controls (#647/#702/#724) can supersede our manual `spotterRescueEnabled=false` and let us shrink the fork patch (gate through `bench/score_overfire.py`).**

## Sources

- Voxtral: <https://huggingface.co/mistralai/Voxtral-Mini-4B-Realtime-2602>
- Nemotron-3.5 streaming: <https://huggingface.co/nvidia/nemotron-3.5-asr-streaming-0.6b> · [discussion #11](https://huggingface.co/nvidia/nemotron-3.5-asr-streaming-0.6b/discussions/11) · [sherpa-onnx #3572](https://github.com/k2-fsa/sherpa-onnx/issues/3572)
- Parakeet-TDT-0.6B-v3 / Canary-1B-v2 paper: <https://arxiv.org/abs/2509.14128>
- FluidAudio: <https://github.com/FluidInference/FluidAudio> · [v0.15.5](https://github.com/FluidInference/FluidAudio/releases/tag/v0.15.5)
