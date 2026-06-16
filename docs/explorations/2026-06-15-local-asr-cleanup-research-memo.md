# Toward an excellent 100%-local dictation path — two research threads

**Date:** 2026-06-15
**Status:** Research memo. **Decide-later — no code, no commitment.** Companion to issue #100.
**Question that started it:** Could we (1) build a CTC biasing rescorer that's actually *better* than FluidAudio 0.14.5's — not just freeze-vendor it — and (2) find a featherweight local model to do *just the cleanup of plain dictation*, reserving Gemma/cloud for actual dictated commands, corrections, and reference-window manipulation?

## TL;DR

- **The two ideas rhyme into one vision:** a 100%-local plain-dictation path so fast and so good that the heavy model (Gemma E4B or cloud) is only needed when you're *telling Parleq to do something* — a command, a correction, a routing instruction. That ties directly into the voice-routing north star.
- **Both threads bottleneck on the *same* hard problem:** cheaply separating "this looks ordinary but isn't" from "this is ordinary." Thread 1: is `ran` really `CRAN`? Thread 2: does this innocuous sentence secretly need reasoning (a hidden `cores`→`CORS`, a `PR forty-three`→digits)? In both, the cheap signal (absolute CTC score / surface text) *can't* separate them — and the honest fixes are structurally similar: **bring in competitor-relative evidence, or escalate.**
- **Thread 1 (better rescorer): plausible, ~55–65% confidence, and shovel-ready.** The over-fire is a textbook-broken comparator (length-normalized *average* CTC score, *absolute* threshold, *flat* additive boost, free time-skips, no negative evidence). The cheap fix — competitor-relative margin + duration/frequency features, pure post-processing on signals FluidAudio already hands us — attacks the actual mechanism. Neural deep-biasing is **out** (sealed ANE Parakeet). This turns issue #100's "vendor 0.14.5" (Option 2) into "Option 4, done right."
- **Thread 2 (featherweight cleanup): the prize is real but the thesis is too strong.** A rules + tiny-tagger engine (~250–400 MB, sub-100 ms, single forward pass) *can* handle the high-volume cleanup — punctuation, casing, filler — and **runs on the 8 GB Macs Gemma locks out today**. But ~half the cleanup rules are *judgment* (self-correction collapse, ASR-misrec fixes, context-gated number formatting), and the make-or-break isn't the tagger — it's the **escalation classifier**, whose hardest cases have no surface trigger and so are *themselves* the reasoning we tried to avoid.
- **They're coupled:** in the local-only world Thread 2 builds, there's no capable LLM to do dictionary biasing — so **Thread 1's rescorer becomes the *only* biasing the featherweight path has.** Thread 1 is load-bearing for Thread 2's world.
- **Recommendation:** Thread 1 first (narrow, measurable, advances an open issue) — but **expand the bench corpus before trusting any win.** Thread 2 second, gated on a cheap feasibility probe (measure escalation recall on real dictation *before* building anything), and framed as a "plain-prose fast lane for 8 GB Macs," never a Gemma replacement.

---

## Thread 1 — A better CTC rescorer

### What 0.14.5 actually does

The rescorer (a port of NeMo CTC-WS, arXiv:2406.07096) is a two-stage shallow-fusion pipeline:

1. **Candidate generation in string space.** For each dictionary term, every TDT word (and 2-/3-word compounds) is scored by Levenshtein grapheme similarity `1 − dist/maxLen`, gated by `minSimilarity` and a hierarchy of blunt string heuristics (stopword skip-set, length-ratio 0.75, short-word similarity 0.80 for ≤4 chars). **All grapheme-only, all before any acoustics.**
2. **Acoustic verification in CTC space.** Survivors run constrained DP (`ctcWordSpotConstrained`) over the CTC log-prob matrix inside a ±0.5 s window, for *both* the vocab term's tokens and the original word's tokens. The replace decision is literally:

   `shouldReplace = (vocabCtcScore + adaptiveCbw) > originalCtcScore`
   (`VocabularyRescorer+TokenEvaluation.swift:85–88`)

### Why short-term over-fire is structural, not a tuning miss

The diagnostic from the ROC sweep — on the regressed versions the **false** matches score *higher* similarity than the **true** ones — is fully explained by four properties of even the *good* 0.14.5 comparator:

- **Per-token length-normalized average + absolute comparison.** `ctcWordSpotConstrained` returns `bestScore / nonWildcardCount` — the average per-token log-prob. The gate compares two such averages over **different-length token sequences** (`CRAN`≈2–3 tokens vs `ran`≈1–2). Averaging then thresholding across unequal lengths is a known-broken comparator (distill.pub/2017/ctc; length-bias arXiv:1606.03402): short sequences accumulate fewer negative terms and float to a higher average.
- **Free time-skips let a short term cherry-pick frames.** The DP's `skipScore` branch lets the alignment skip frames at zero cost; within ±0.5 s (~6–12 frames) a 2-token term selects its two best-matching frames *anywhere*. Fewer tokens ⇒ more freedom to find a flattering alignment ⇒ inflated short-term scores. **This may be the deeper culprit than the gate itself.**
- **The flat additive `cbw` destroys any ratio meaning.** Adding a constant in log space multiplies the term's odds by ≈`e^cbw` *regardless of how strong the competitor is* (`adaptiveCbw` only ever *grows* the boost for longer terms, never shrinks it for short ones). So even when `ran` explains the audio as well as `CRAN`, +3.0 carries `CRAN` over the line.
- **No negative evidence at all.** The only competitor is the single original word's CTC score — not a proper background/filler loop. No anti-context set, no frequency penalty.

**Intervention point:** the `evaluateCTCMatch` decision plus the score returned by `ctcWordSpotConstrained`. Everything upstream (candidate generation, DP table, timings) is reusable; all leverage lives in the replacement criterion and the score normalization.

### How "better" gets measured

`bench/score_overfire.py` counts canonical terms the rescorer *inserts* that weren't in the raw hyp, over a corpus of dictation with near-collisions (`ran`~CRAN, `sync`~Snyk, `ready`~Redis, …). `score_recall.py` measures true-positive recall. The metric is **purely string-level on final text** — so any new rescorer (even a text-only second pass) is measurable on the *exact same harness*, and must beat **12 over-fires while holding ~98.3% recall**. **Caveat:** the 12-count is on a tiny synthetic 3-voice corpus; the 12→N delta may be within noise. **Expanding the corpus is prerequisite #1** before trusting any improvement.

### Design directions, ranked by payoff ÷ effort

**Tier A — cheap, pure post-processing on signals already in hand. No new model.**
- **A1 (highest leverage): competitor-relative margin / likelihood-ratio gate.** Replace `(vocab + flat cbw) > original` with "term must beat the free-decode original over the same window by margin δ," boost made competitor-relative. This adds the competitor-strength axis the single averaged score lacks — the only formulation that can rank false-below-true when absolute scores rank them backwards. (KWS LLR scoring; "Difficult Negative" training arXiv:1810.12170.) ~tens of LoC at the decision site.
- **A2: length-/frequency-aware boost + duration sanity.** Scale the boost *down* for short/few-token terms and for terms whose surface collides with a high-frequency English word (static unigram table). Add a predicted-vs-observed acoustic-duration check (a short term force-aligned onto a long span has anomalous per-token duration — a strong over-fire discriminator, free from the DP frames). (Aho-Corasick dual-cost LM gating arXiv:2409.13514; context-aware CEM IEEE 10023411.)
- **A3: anti-context / hard-negative gate.** Generate edit-distance-1 English neighbors per short term as explicit competitors the term must out-score (GraphemeAug arXiv:2505.14814: +54–61% AUC on confusables, no recall loss). Mostly tooling — extends the existing #97/#98 over-fire gate into the dev loop.

**Tier B — moderate; a learned gate, still post-processing.**
- **B1: discriminative gate (logistic/GBDT) over a feature vector** {averaged CTC posterior, competitor margin, predicted-vs-observed duration, term length/#tokens, surface unigram frequency} trained on mined `ran→CRAN` hard negatives. Context-aware CEM moved word-error AUC 0.837→0.892 — a real *reordering*, which monotonic recalibration can't achieve.
- **Explicitly OUT: temperature/Platt/isotonic calibration** — AUC-invariant and monotonic, so *provably cannot* reorder false-above-true. (Rule this out so no one proposes "just recalibrate the CTC score.")

**Tier C — text-only complement (not the fix).**
- **C1: bias-aware correction folded into the LLM cleanup pass** Parleq already runs (detect→correct→verify staging, RLLM-CF arXiv:2505.24347). Near-zero marginal cost, but a text-only pass *relocates* over-fire into the text prior and can hallucinate bias terms — only detect/verify staging contains it. A complement for cloud users, **not** available to the local-only path.

**Tier D — OUT against a sealed ANE Parakeet.** Neural deep biasing (TCPGen, contextual adapters, NAM/Deferred-NAM) all need encoder/joint-state access or in-graph training. The ANE Parakeet exposes neither; acoustic retraining is off the table.

**Phonetic matching (G2P / double-metaphone / Soundex) is NOT a fix here.** The collisions (`CRAN`/`ran`, `Snyk`/`sync`) are already phonetically near; phonetic keys pull term and false competitor *closer*, shrinking the margin. It's a recall tool, not a false-positive tool.

### Confidence & risks

**Highest-leverage bet: A1 + A2** (competitor-relative margin with duration/frequency features), likely also constraining the free-skip DP. **Confidence it beats 12/98.3%: ~55–65%.** For: it attacks the actual mechanism and the literature prescribes exactly this. Against: (a) the original word is an imperfect "filler," so the ratio may not fully separate near-identical alignments — A1 probably needs A2's features (drifting toward B1); (b) the free-skip DP may be the deeper culprit; (c) the 12-baseline must survive corpus expansion to be real.

Risks to own: **TDT timing-semantics fragility** (the whole rescorer keys on frame/margin semantics that already shifted and broke biasing upstream — owning it means tracking those across every model bump); **~1.5k LoC** of DP/BK-tree/tokenizer to maintain; a **frozen-model ceiling** (no post-processor recovers acoustic detail the TDT discarded — the worst homophones may stay best served by per-term `biasing: "llmOnly"`).

---

## Thread 2 — A featherweight local cleanup engine

### "Cleanup" is mostly a *judgment* spec, not a normalization spec

Classifying every rule in `baseCleanup` (`SystemPrompts.swift:48–78`):

| Class | Rules | Engine |
|---|---|---|
| **(a) deterministic** | sentence-start caps; spelled-letter *assembly*; the *transduction* half of spoken-number→digits | regex / WFST, ~0 RAM |
| **(b) light model** | proper-noun caps (truecasing); punctuation; filler removal ("um/uh/like-as-filler") | single-pass tagger |
| **(c) reasoning** | self-correction collapse ("scratch that"/"I mean X"); ASR-misrec fixes ("cores"→CORS); sentence-boundary fixes; drug-name correction; **context-gating** of number formatting ("PR forty-three"→digits but "forty years ago"→words); quote-cue vs literal "quote"; vocab-hint topic judgment | Gemma / cloud |

The split is ~even, and the **highest-frequency, most-visible** rules (punctuation, casing, filler) are (a)/(b). The class-(c) rules are where the local Gemma tier *already trails cloud* (the A/B "Prometheus for Promtail" / "Sherpa-ONKS" misses). So a featherweight engine doesn't have to match Gemma on (c) to be useful — it has to nail (a)/(b) **and recognize when it's out of its depth and escalate.**

### Candidate components (sizes / latency / quality)

- **Punctuation + capitalization:** NeMo DistilBERT punct-cap (~234 MB, single token-classification pass, ~tens of ms on M-series; English F1 ≈ 79.8 — much of the miss is comma ambiguity humans also disagree on). Silero text-enhancement ships `xsmall`/quantized flavors. These are the (b) core and they run **cold, with no multi-GB resident model.**
- **Disfluency removal:** Switchboard BERT taggers (~F 86%), same single-pass cost — but trained for fillers/repeats, **not** semantic self-correction. They get "um/uh" (class b); they do **not** do retraction-collapse (class c).
- **ITN (numbers/dates/currency):** NeMo WFST — pure grammar, ~0 ML RAM, sub-ms — the single best fit in the thread. But it transduces *unconditionally*; Parleq needs it *context-gated*, and NeMo's own answer to context is a neural LM rescorer (reintroducing a model). "Deterministic to apply, reasoning to decide when."
- **One tiny seq2seq for the whole job (ByT5/T5-small):** byte-level is the natural choice for noisy ASR, and T5-family models *do* learn ASR error correction (FLANEC) — **but** ByT5-small is 300M params, autoregressive, and byte sequences are ~4× longer ⇒ up to ~10× slower than subword: the latency win evaporates, possibly *slower* than a 4B MLX decode on short input. Worse, it's a black box that **can paraphrase/hallucinate**, violating the spec's hard "no paraphrase/no added info" with no prompt lever to restrain it, and needs a labeled corpus we don't have.

### Three architectures

- **(A) Pure rules + phonetic dictionary** (~0 RAM, <5 ms). Can't do comma placement, novel proper-noun casing, filler disambiguation, or any of (c). Produces under-punctuated/under-cased text on messy ASR. **Insufficient alone**; good as the ITN + known-fix layer under (B).
- **(B) Rules + a tiny punct/truecasing/disfluency tagger — RECOMMENDED featherweight.** One ~234 MB BERT-tagger pass over (A)'s WFST-ITN and lookup fixes. **~250–400 MB peak, sub-100 ms, no multi-GB floor ⇒ runs on 8 GB Macs.** Covers all of (a) and most of (b). Must escalate all of (c) to Gemma/cloud. The only design that hits the size/latency prize while being honest about its ceiling.
- **(C) One small fine-tuned seq2seq** — highest cost, weakest faithfulness, dubious latency win (see above). **Not recommended.**

### Honest read on the thesis

**Partially supported, one decisive caveat.** (B) genuinely does the bulk-by-volume of everyday cleanup at an 8 GB-friendly footprint and sub-100 ms — a real product win, because **8 GB Macs get nothing local today.** What it *cannot* do is the class-(c) judgment, which is non-trivially frequent for the exact technical users who dictate ("cores/CORS", "PR forty-three fifty-two", spelled names, constant self-correction). So "*so good you'd only need Gemma for commands*" is **too strong** — you'd need Gemma for class-(c) *cleanup* too. Accurate reframing: **a plain-prose fast lane that falls back to Gemma/cloud.** Its value is entirely user-dependent — a prose emailer benefits hugely; a developer dictating identifiers escalates on most utterances.

### The make-or-break: the escalation split

The architecture lives or dies on a cheap local classifier deciding "plain dictation (→ tagger) or needs Gemma (command/correction/tech-term/spell-out/context-ITN)?"

- The classifier is **cheap** (tens of ms) — that's *not* the risk.
- The risk is **false-negative escalation.** Explicit cues ("scratch that", spelled letters, command verbs) are keyword-detectable. But the *implicit* needs — a buried "cores" that should be "CORS", a "PR forty-three" that should be digits, a novel proper noun — **have no surface trigger.** Detecting "this innocuous sentence hides an ASR-misrec the user will be annoyed we missed" *is itself the class-(c) reasoning we were trying to avoid.* A near-paradox.
- A **conservative** split (escalate on any digit-word / capitalized-candidate / near-alias / retraction cue) is safe but escalates so often it **claws back the latency/RAM win.** An **aggressive** split is fast but silently ships the misses.
- Secondary: a two-engine system has **two output styles** (tagger vs Gemma punctuation/casing habits); users notice utterance-to-utterance inconsistency more than a single engine's quirks.

**The make-or-break deliverable to prototype first is the escalation classifier's recall on no-surface-trigger class-(c) cases** — not the tagger (a solved ~234 MB component). If that recall is poor, the honest move is the *opposite* of the thesis: keep one model and make *it* lighter (hard — the E2B path already failed at 16/25), rather than split into two engines whose seam is the hardest problem of all.

---

## Synthesis & recommendation

### The shared spine

Both threads are the same problem wearing two costumes: **cheaply deciding when an ordinary-looking signal secretly needs more.** Thread 1's over-fire (`ran` scores higher than `CRAN` should allow) and Thread 2's escalation gap (a plain sentence hiding a `CORS`) are both "false looks like true," and both honest fixes are the same shape — **competitor-relative evidence** (Thread 1's margin gate) or **escalate to a capable model** (Thread 2's classifier). Neither is solvable by tightening a single absolute threshold.

### The coupling that matters

In the **local-only world Thread 2 builds, there is no capable LLM to do dictionary biasing** — the featherweight tagger can't do class-(c) ASR-misrec/vocab-hint corrections, and there's no cloud call. So **Thread 1's CTC rescorer becomes the *only* biasing that path has.** Improving the rescorer isn't just about cloud-off users today; it's foundational infrastructure for the featherweight vision. That argues for sequencing Thread 1 first on its own merits *and* as an enabler.

### Recommended sequence

1. **Thread 1, cheap arm — a spike (advances issue #100).** First expand the bench corpus (more voices/terms) to de-noise the 12-count. Then implement **A1 (competitor-relative margin) + A2 (duration/frequency features)** as pure post-processing on FluidAudio's existing outputs, owning only the replace decision. Measure on the over-fire + recall harness. Success = beat 12/98.3%. This reframes issue #100 from "vendor 0.14.5" to "own a *better* replace decision," and it's load-bearing for Thread 2. Neural paths stay out.
2. **Thread 2, feasibility probe *before* building.** Don't build the tagger pipeline yet. First build a **labeled set of real dictation** tagged plain-vs-needs-Gemma, and measure how well a cheap classifier (and honest heuristics) catches the *no-surface-trigger* class-(c) cases. This single number decides the whole thread: good recall ⇒ build architecture (B) as a "plain-prose fast lane for 8 GB Macs"; poor recall ⇒ shelve the split and instead invest in a lighter *single* model.
3. **Revisit the framing, not just the tech.** If Thread 1's better rescorer lands and Thread 2's probe is encouraging, the combined story is the routing vision's first concrete foothold: *format-what-I-said* runs instant and local; *do-what-I-said* wakes the heavy model. Worth a dedicated design pass at that point.

### What this memo does *not* recommend

- No neural deep-biasing against the sealed ANE Parakeet (Thread 1, Tier D).
- No single fine-tuned seq2seq cleanup model (Thread 2, arch C) — loses the latency win, risks hallucination.
- No building the featherweight pipeline before the escalation-recall probe.
- No upgrading FluidAudio off 0.14.5 for base-ASR reasons (separate, already decided) — this memo is about the *biasing decision*, which we can now own regardless of version.

## Prior art: post-ASR Generative Error Correction (GER)

"Correcting STT output" is a formalized research subfield, and it informs the threads above more than it hands us a drop-in:

- **Benchmarks/challenges:** HyPoradise (arXiv:2309.15701) — 334k+ *N-best → ground-truth* pairs, established "generate a correction" over "rescore the N-best." GenSEC Challenge (IEEE SLT 2024, arXiv:2409.09785) with a LLaMA-2-7B baseline.
- **Dedicated small correctors:** N-best T5 (arXiv:2303.00456, ~13% WERR on Whisper+LibriSpeech), FlanEC / Flan-T5 (arXiv:2501.12979), Whispering LLaMA (cross-modal: audio embeddings + N-best, arXiv:2310.06434).
- **Fast / non-autoregressive:** FastCorrect (NeurIPS 2021, arXiv:2105.03842) — edit-alignment NAR correction, 6–9× faster than autoregressive at 8–14% WERR. Acoustic+confidence-conditioned correction (arXiv:2407.12817).

**Three caveats for Parleq:** (1) the field targets the *misrecognition* half (WER), not punctuation/casing/filler/intent — it overlaps Thread 2's class-(c), doesn't replace cleanup; (2) it mostly *assumes N-best lists*, which the on-device TDT batch path doesn't obviously expose; (3) it hallucinates — the exact faithfulness risk the cleanup prompt fights.

## Opportunity map

The academic field is converged on a setup that mismatches Parleq on nearly every axis, and each mismatch is an opening. Parleq also holds technical assets that make several of these unusually cheap to pursue:

- **The CTC posterior matrix is already extracted** on the biasing path — a cheap "re-listen" signal (what Whispering LLaMA pays for with audio embeddings, what acoustic+confidence correction shows helps) **available without N-best**.
- **A correction data loop already exists** (`CorrectionJournal` + `LearnedStore`).
- **An evaluation harness already exists** (`bench/`).
- **An on-device MLX runtime** is a real deployment path.

Opportunities, ranked by leverage:

1. **A better contextual-biasing rescorer (Thread 1).** Most certain, shovel-ready, advances #100 — and since FluidAudio is open source, **upstreamable** as a contribution. Start here.
2. **A posterior-conditioned tiny faithful corrector.** A non-autoregressive / edit-tagging corrector (FastCorrect lineage — edit ops structurally limit hallucination, matching the faithfulness constraint) conditioned on the **CTC posterior already in hand**, personalized by the dictionary + learned terms. Every ingredient has prior art; the on-device + posterior-conditioned + personalized *combination* is open. The differentiated bet.
3. **A dictation-cleanup benchmark + dataset.** The field measures WER; there is no good public benchmark for *dictation → polished paste-ready* quality. We have the harness and real usage patterns. Lower glamour, but it **de-risks #2 and #4 by making them measurable**, and a released benchmark is itself a contribution.
4. **A tiered cleanup with an intent/escalation classifier.** The "plain-dictation fast lane vs. needs-the-heavy-model" split (Thread 2's make-or-break). Genuinely underexplored as a productized low-latency *local* classifier; highest risk (the no-surface-trigger problem), but it is what makes the featherweight path real.

**Not worth chasing:** reproducing big-LLM N-best GER (we lack N-best; crowded; heavy); a from-scratch lighter base ASR/LLM (already decided — cloud is the accepted 8 GB answer).

**Suggested sequence:** #1 now (certain, upstreamable) → #3 alongside (cheap, de-risks the rest) → #2 as the real bet, with #4 gated on what #3's labeling reveals about the escalation split.

## Links

- Issue #100 (decouple biasing from FluidAudio's rescorer) — this memo extends its Option 4.
- `docs/explorations/2026-06-15-fluidaudio-0.15-biasing-regression.md` — the ROC sweep / regression diagnosis.
- `docs/explorations/on-device-llm-cleanup.md` — the existing local Gemma tier.
- Over-fire / recall harness: `bench/score_overfire.py`, `bench/score_recall.py`, `bench/dictionary-overfire.json`.
- Known-good rescorer source: `parleq-app/.build/checkouts/FluidAudio/.../CustomVocabulary/` (v0.14.5).
