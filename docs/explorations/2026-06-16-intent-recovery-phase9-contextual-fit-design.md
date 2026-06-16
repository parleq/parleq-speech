# Intent-recovery Phase 9 — contextual-fit probe (DESIGN)

**Date:** 2026-06-16
**Status:** Design/plan for the next experiment in the intent-recovery program. This is the *plan* doc; the results land in a sibling `...phase9-contextual-fit.md`. Approved in brainstorming. Blurb handling is **dual-track** (§Blurb sources): the primary blurbs are the maintainer's *real* work-dictionary `context` fields (git-ignored, authentic, and independently blind — written for daily use before this probe existed); Appendix A is the committed, public-safe generic reproduction set, frozen before any test sentence was read.

## Why this experiment

The trunk spec ([`2026-06-16-intent-recovery-TRUNK-architecture.md`](2026-06-16-intent-recovery-TRUNK-architecture.md)) names the **contextual-fit probe** as the single highest-value thing left to test. It decides whether **error class 3** — the *confident near-homophone* (`Snyk`→"sneak", `k8s`→"Kate's") — has a **featherweight, 100%-local** resolver, or whether it genuinely needs the cloud cleanup LLM.

Plain-English framing: when the recognizer is *confidently* wrong (it heard a real word that sounds like your term), acoustics can't flag it (Phase 6: real Snyk mishears scored 0.95 — indistinguishable from a correct word). The only remaining local signals are **what you usually say** (the usage-prior, Phase 8) and **what the rest of the sentence is about** (contextual fit, this probe). This probe tests the second one: does the sentence around the ambiguous word look more like the term's *meaning* when the term was actually intended?

## The question, as a measurement

> Does **sentence ↔ term-blurb similarity** separate *term-intended* speech from *common-word-intended* speech — **specifically in the slice acoustic confidence cannot flag** (the confident, class-3 cases)?

Class 2 (Phase 6) already recovers *unsure* mishears via the confidence×dictionary gate. So the headline metric is the AUC on the **high-confidence subset**, not over all clips — that residual is where context has to earn its keep. Both (all-clips and high-conf) are reported.

## Data & labels

Real human recordings in `bench/fixtures-human/` (single speaker, git-ignored — maintainer's voice).

- **Positives (want HIGH fit):** `c*` clips — the user spoke the term.
- **Negatives (want LOW fit):** `o*` clips — the user spoke the genuine common word that sits near that term (the over-fire risks).

Current counts (per term, c/o): Snyk 3/2, CRAN 3/5, Redis 3/2, k8s 2/2, worktree 2/2, E2E 2/1, ultrathink 1/2, Sonnet 0/2. ≈16 positives / 18 negatives over ≈7 terms.

**Proprietary class-3 terms (git-ignored):** the maintainer's real work dictionary adds **3 additional terms** that are authentic confident-near-homophone cases (a term whose natural mis-ASR is a common word). These are a **customer-identifying cluster** — their names, blurbs, confusion words, recordings, and per-term result rows live only in git-ignored files and never reach a committed doc; the committed results report them as anonymized aggregates only (CLAUDE.md: no proprietary/customer dictionaries in the repo). The real work dict has no Redis/k8s, so those two keep the generic public blurbs.

**N is small — this is a signal-detection sanity check, not a powered study** (the program's standing honest-bound). See the recording plan below for the agreed expansion.

**Secondary arm — argmax control:** the `s*` stress clips (Nuxt/Vite/Numba/Dask/Zod/Hugo/Deno/Polars/Pinia/Rune; 10 term-intended, blurbs already blind from Phase 4c) are positives-only, so they feed the §"Metrics" argmax control rather than an AUC.

## The signal (Approach C — both scorers)

For each clip:

1. Run `asr-bench --dump-tokens` to get the ASR **hypothesis** transcript + per-token `confidence`.
2. Identify the ambiguous word (the one near a dictionary term, via the same grapheme-proximity helper used in `analyze_personal_prior.py`).
3. Build the **context** = the hypothesis sentence **minus the ambiguous target word** (so the score cannot cheat by reading "sneak" vs "Snyk").
4. Score `context` against the term's **blurb** (see §Blurb sources) two ways:
   - **Keyword overlap** (zero model): lemmatized content-word overlap, rarity-weighted (drop stop-words). The truly-free baseline.
   - **Embedder cosine**: `all-MiniLM-L6-v2` (sentence-transformers, ~80 MB) in `bench/.venv`, as a research proxy for the on-device Apple `NLContextualEmbedding` / `NLEmbedding` that would actually ship (no download, already in the OS).

**Why the hypothesis, not the reference:** at inference time Parleq only has what the model *heard*. Scoring the clean reference sentence would leak information the product never has. We use the hypothesis (misheard word and all, target removed) — the honest, deployment-faithful input.

## Blurb sources (dual-track) & proprietary-data handling

The probe runs over **two** blurb sets and reports both:

- **Primary — real work blurbs (git-ignored).** The maintainer's actual dictionary `context` fields, refreshed into `bench/dictionary-work.json` from `~/Downloads/config.json`. These are the honest headline: authentic phrasing a real user typed, and *independently blind* (written for daily use, predating this probe — a stronger circularity defense than any after-the-fact authoring). Examples (paraphrased): Snyk = "enterprise security scanning service", CRAN = "the primary R package repository", worktree = "a git worktree".
- **Secondary — generic public blurbs (committed).** Appendix A — short, definition-only, public-safe. Lets anyone reproduce the committed numbers without the private dict.

**Blurb sanitization (scoring-time, logged).** Real blurbs carry meta-commentary that must not enter the score: *self-reference* ("used a LOT by me", "I work on") adds no semantic signal, and — critically — *confusion notes* ("often confused with \"work tree\"") literally contain the **common word**, which would spuriously match the *negative* clips and corrupt the result. The analyzer normalizes each blurb to its semantic core (strip parentheticals, self-reference, and "confused with …" clauses) before scoring; the raw dict stays faithful, normalization happens in-analyzer and is logged.

**Proprietary handling.** `bench/dictionary-work.json`, `bench/fixtures-human/`, and `bench/fixtures/manifest-*human*.json` are already git-ignored. The proprietary terms' names, blurbs, and per-term result rows never reach a committed file — the committed results doc reports them only as anonymized aggregates ("3 proprietary class-3 terms, pooled AUC …"). Their concrete names/confusion-words/recording prompts live in a git-ignored notes file (see §Build order).

## Metrics

1. **Primary — separation.** ROC-AUC of the fit-score separating `c` (term) from `o` (common), pooled and within-term, for keyword vs embedder. Plus a threshold sweep (recovers-B / false-flags-A), reusing the printer in `analyze_personal_prior.py`.
2. **Conditioned — the class-3 slice.** Same AUC restricted to high-acoustic-confidence target words (≥ ~0.97). This is the headline: context's value *where acoustics fail*.
3. **Argmax / discrimination control.** For each clip, score the utterance against **every** term's blurb and check whether the **correct** term's blurb ranks #1. Guards the confound that term-intended speech is merely "more technical" and would match *any* tech blurb — we need it to match the *right* one. Uses `c*` + `s*`.

## Integrity guards (so a positive result is believable)

- **Two blurb sets, both blind.** Primary = the maintainer's real blurbs, which *predate this probe entirely* (the strongest possible circularity defense). Secondary = Appendix A, blind-authored from definitions and frozen by committing this doc, copied verbatim into `bench/blurbs-overfire.json`. Neither was tuned to a test sentence.
- **Target word excluded** from the scored context; real blurbs **sanitized** of confusion-notes that leak the common word (see §Blurb sources).
- **Keyword baseline reported beside the embedder** — the "is the model even necessary?" control (the same instinct that killed the CTC-margin gate in Phase 1; if free keyword overlap already separates, that beats needing any model).
- **Honest-bounds paragraph** (single speaker, small N, synthetic-overstates-everything) carried into the results doc, per program convention.

## Recording plan (agreed expansion)

Maintainer will record additional clips to firm up the conditioned AUC. To keep blurbs blind, sentence design happens **after** Appendix A is committed.

- **Target:** bring the strongest class-3 terms — **Snyk, CRAN, Redis, k8s** — to **5 term-intended + 5 common-intended** clips each, every clip a **distinct sentence** (context diversity is the variable under test, not take-to-take repetition). ≈+25 clips over today's set.
- **Proprietary class-3 terms (git-ignored fixtures):** record the **3 work-dict terms** at ~3 term-intended + ~3 common-intended each (concrete terms + their confusion words are in the git-ignored notes file). Authentic class-3 cases; fixtures stay git-ignored, numbers anonymized in the public results.
- Recorded via `bench/record_corpus.py` (guided prompt-and-record, 16 kHz mono); new files follow the `cNN-<term>-jon.wav` / `oNN-<term>-<commonword>-jon.wav` naming and are added to the (git-ignored) human manifests.
- Stretch (optional): one extra `c`/`o` pair for worktree, E2E, ultrathink to lift the thin terms.

## Build order (implementation)

1. `bench/blurbs-overfire.json` — copy Appendix A verbatim; commit **first**, separately (public-safe secondary set).
2. Refresh `bench/dictionary-work.json` (git-ignored) with the real `context` blurbs from `~/Downloads/config.json` (primary set). **Not committed.**
3. Write `bench/phase9-proprietary.local.md` (git-ignored — add the pattern to `.gitignore`) holding the 3 work-dict terms, their confusion words, and recording prompts. Then design + record the expansion sentences incl. those terms (§Recording plan); update the git-ignored manifests.
4. `bench/analyze_contextual_fit.py` — reuses `analyze_confidence.py` (word grouping/alignment) and the AUC/threshold-sweep helpers; loads either blurb set; sanitizes blurbs (§Blurb sources); emits the §Metrics tables for keyword + embedder.
5. Add `sentence-transformers` to `bench/.venv`.
6. Run on both blurb sets; write results into `2026-06-16-intent-recovery-phase9-contextual-fit.md` — proprietary terms anonymized/aggregated only.

## Decision this produces

A clear read on whether class 3 has a **featherweight local resolver** (embedder — or even free keyword overlap), or genuinely needs the cloud LLM / usage-prior. That closes the trunk's "highest-value to test next" open question and tells us whether the featherweight (100%-local) engine can claim all three error classes or only classes 1–2 + a local-prior slice of 3.

## Honest bounds (carried from the program)

- Single real speaker, modest N even after expansion; synthetic systematically overstated false-flag rates and missed failure modes — real audio is the gating reality.
- The Python `all-MiniLM-L6-v2` proxy is **not** the exact on-device model; it bounds feasibility, it doesn't certify the shipped primitive.
- The two blurb sets differ in length (secondary/public = short definition phrases; primary/real = richer, e.g. "the primary R package repository. Used a LOT in my conversations"). That's a feature, not a bug — comparing them shows how blurb richness affects keyword overlap especially. But it also means the two AUCs aren't apples-to-apples; report them as separate columns, not a single headline.
- The 3 proprietary terms appear in committed results only as anonymized aggregates — a reader can't audit those per-term, by design.
- This is research, not a build. Any resolver that comes out of it is maintainer-gated productionization with real surface area.

---

## Appendix A — FROZEN public-safe blurbs (secondary set; blind-authored 2026-06-16, before any test sentence was read)

The committed, public-reproducible blurb set (the *primary* set is the maintainer's real git-ignored work dict — see §Blurb sources). Authored from each term's real-world definition only; kept short to match the real dictionary `context` field style. Copied verbatim into `bench/blurbs-overfire.json` at build time.

| term | frozen blurb |
|---|---|
| CRAN | R-language package repository |
| Snyk | developer security vulnerability scanner |
| Redis | in-memory key-value data store |
| k8s | Kubernetes container orchestration |
| worktree | git branch working-directory feature |
| ultrathink | AI assistant deep-reasoning mode |
| E2E | end-to-end software testing |
| Sonnet Opus | Claude AI model tiers |

The stress-set blurbs (Nuxt/Vite/Numba/Dask/Zod/Hugo/Deno/Polars/Pinia/Rune) are reused from `bench/dictionary-stress.json` — already blind (authored in Phase 4c for a different purpose).
