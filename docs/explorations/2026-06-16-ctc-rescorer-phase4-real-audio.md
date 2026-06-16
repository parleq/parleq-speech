# CTC rescorer — Phase 4b: real-audio validation (the gate holds on human speech)

**Date:** 2026-06-16
**Status:** Research finding (issue #100). Phase 4b — the #1 external-validity check: does the single-token frequency gate (validated on synthetic `say` audio in Phases 1–3) hold on **real human speech**? **No app code changed.**
**Builds on:** Phases 1–3 + Phase 4a (LLM leg). **Tooling:** `bench/record_corpus.py` (guided prompt-and-record, 16 kHz mono via ffmpeg/avfoundation).
**Corpus:** 34 real recordings (1 speaker, "jon") — 18 over-fire + 16 colliding sentences, read aloud. **The WAVs are personal voice data and are git-ignored — not committed to the public repo.**

## TL;DR

- **The gate replicates on real human audio.** Genuine over-fires **4 → 0** (all killed by the single-token frequency gate); colliding recall **9/16 → 9/16 (zero recall cost)**. The zipf=2.5 threshold holds: `radish` (2.78) suppressed, the multi-word `work tree → worktree` kept.
- **Every over-fire on real audio is the same shape as synthetic:** a single common word wrongly overridden — `ran→CRAN` (×2), `crane→CRAN`, `radish→Redis`. The gate suppresses all four; the only true recovery (`work tree → worktree` ×2) is multi-word and survives.
- **But synthetic `say` overstated recall.** Real-audio boosted recall is **56%** vs synthetic **81%**: the abbreviation-style terms `say` nailed (E2E 6/6, k8s, Snyk recovered) are **missed entirely on real human speech** (E2E 0/2, k8s 0/2, Snyk 0/3). The rescorer's recovery contribution shrank to **+2** (the two `worktree`s). So the *precision/over-fire* conclusions transfer cleanly; the *recall* numbers were synthetic-optimistic, especially for acronyms.

## Numbers (real audio, dictionary-overfire, cbw 2.0, minSim 0.65)

Genuine over-fire = an inserted dictionary term that is **not** the clip's expected term (counted per-clip; the canonical `score_overfire.py` is clip-agnostic and miscounts legit recoveries on colliding clips, so it was scored per-arm here):

| | baseline | gated (zipf 2.5) |
|---|---|---|
| genuine over-fires (of 34 clips) | **4** | **0** |
| colliding recall (16 pairs) | 9/16 (56%) | **9/16 (56%)** |

The 4 over-fires and the gate's verdict:

| clip | misfire | original zipf | gate |
|---|---|---|---|
| o01-cran-ran | ran → CRAN | 4.87 | killed |
| o04-cran-crane | crane → CRAN | 3.92 | killed |
| o09-redis-radish | radish → Redis | 2.78 | killed |
| c05-redis ("Redis instance **ran** out…") | ran → CRAN | 4.87 | killed |

Per-term colliding recall (raw → boosted): CRAN 3/3, Redis 3/3, ultrathink 1/1 (ASR native); **worktree 0→2/2** (rescorer recovery); **E2E 0/2, k8s 0/2, Snyk 0/3** (missed by ASR and rescorer).

## Interpretation

- **The core claim transfers to real speech:** over-fire is a single-common-word phenomenon, and the single-token frequency gate eliminates it at zero recall cost. This is the result we most needed to de-risk before any build, and it held.
- **Recall is harder and more term-dependent on real audio.** `say` produces unrealistically clean, consistent renderings of acronyms (E2E/k8s/Snyk); a real speaker's versions are missed by the ASR outright, so the rescorer never gets the chance to help (and for Snyk, the candidate-gen grapheme gap compounds it — see Phase 3). Takeaway: **trust the synthetic corpus for over-fire/precision tuning, but treat its recall figures as a ceiling, not an estimate.**
- **`CRA→CRAN` did not recur on real audio** — the real speaker's "CRAN" transcribed correctly (3/3), so the irreducible single-word-collision recovery cost (the lone synthetic loss) didn't even materialize here. The irreducible case remains a real but rare risk, mitigated by `llmOnly`.

## Caveats

- **1 speaker, 34 clips.** A single voice ("jon"); more speakers/accents would harden the recall picture (the over-fire/gate result is categorical and less N-sensitive). Recordings are git-ignored (personal voice data).
- Same dictionary-overfire (8 terms) and default tuning as the synthetic arms, for apples-to-apples.
- Recall measured by term-presence (case-insensitive), consistent with the synthetic arms.

## Reproduce

```bash
# record (guided): bench/.venv/bin/python bench/record_corpus.py \
#   --corpora overfire,colliding --speaker jon --device :2 \
#   --manifest bench/fixtures/manifest-human.json   # WAVs land in bench/fixtures-human/ (git-ignored)
parleq-app/.build/debug/asr-bench --manifest bench/fixtures/manifest-human.json \
  --wav-dir bench/fixtures-human --paths batch --dictionary bench/dictionary-overfire.json \
  --cbw 2.0 --min-similarity 0.65 --out /tmp/human.json --dump-replacements /tmp/human-dump.jsonl
bench/.venv/bin/python bench/apply_gate.py --results /tmp/human.json --dump /tmp/human-dump.jsonl \
  --zipf 2.5 --out /tmp/human-gated.json
# score genuine over-fires per-arm (inserted term not in the clip's expected terms) + colliding recall
```
