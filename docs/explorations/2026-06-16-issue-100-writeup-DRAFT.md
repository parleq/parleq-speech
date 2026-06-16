# Issue #100 — consolidated research findings (Phases 1–4)

> Consolidated summary of the CTC-rescorer over-fire investigation (Phases 1–4,
> 2026-06-16). The same content is suitable to post as a comment on issue #100.

---

## Research outcome: a better rescorer is real — but it's a *precision* fix with a *dictionary-dependent* recall cost

Spent a multi-phase research pass turning the over-fire problem into measurements (instrumented `asr-bench` with a per-replacement score dump; harnesses in `bench/`). Summary of what's now established, and how it updates the Options above.

### 1. Mechanism — confirmed with numbers
The over-fire is the flat `+cbw` boost. On the 0.14.5 gate `shouldReplace = (vocabCtcScore + adaptiveCbw) > originalCtcScore`, for the short colliding terms `adaptiveCbw` is the flat base (≤ referenceTokenCount=3), and on most over-fires the dictionary term's **raw** CTC score is *worse* than the word it replaced — only the `+2.0` flips it (`CRAN` raw −13.53 vs `ran` −13.42). [Phase 1]

### 2. Option 4's obvious form (competitor-relative margin) is refuted
A margin gate (require the term to beat the original on raw CTC by δ) cannot work: true and false corrections have **overlapping** raw-margin distributions — the true positives are in fact *more* boost-carried than the false. No δ separates them. [Phase 1: `docs/explorations/2026-06-16-ctc-rescorer-phase1-diagnosis.md`]

### 3. The lever that works: a single-token frequency gate
Suppress a replacement iff the **original is a single common word** (`wordfreq` zipf ≥ ~2.5). Over-fires are always a common single word being overridden; legitimate recoveries are garble (zipf ~0) or multi-word compounds. **Over-fire precision is excellent and robust — eliminated on every corpus and across the whole frequency band:** 12→0, 19→0 (5-voice), 4→0 (real human audio), 40→0 (adversarial stress). [Phases 2/3/4]

### 4. The catch (the important part): recall cost is dictionary-dependent, not zero
Early curated corpora showed ~0 recall cost — but that was an artifact: those recoveries were compounds (`work tree`→worktree) or garble (`Parlek`→Parleq), which don't trip the gate. A stress dictionary of terms whose *natural* mis-ASR **is** a common word shows the real cost: colliding recall **82% → 56%** gated (13/17 recoveries destroyed — `Numba` via "number", `Dask` via "desk", `Deno` via "Dino"). [Phase 4c: `...phase4-threshold-stress.md`]

It is **irreducible at the rescorer level**, proven by one word: `"number"` is simultaneously an over-fire original ("your phone **number**" → keep) and a recovery original ("the loop with **Numba**" → heard "number" → should become Numba). Same surface, same frequency, opposite correct actions. Only sentence *context* (the cleanup LLM) or *per-term user policy* can resolve it.

So the gate is a **prior that favors the common word**: ~0 cost for distinctive/compound terms (Parleq, FluidAudio, worktree), large cost for common-word colliders (Numba, Dask, CRAN). It must be **per-term, not a blanket suppress**.

### 5. Real-audio reality check
34 real human recordings: the over-fire fix replicates (4→0, zero recall cost on that set), threshold holds. But synthetic `say` **overstates recall** — real spoken acronyms (E2E, k8s, Snyk) are missed by the ASR outright (real boosted recall 56% vs synthetic 81%). Trust synthetic for precision/over-fire; treat its recall as a ceiling. [Phase 4b]

### 6. The LLM cleanup leg is complementary, not a substitute
Running the real cleanup prompt (Vertex flash-lite) over raw transcripts: it lifts context recall (incl. recovering `Snyk`, which the rescorer structurally can't — see §7) **but also over-fires 8/90** itself (`crane→CRAN`, `radish→Redis`, ignoring its own "leave homophones alone" rule), and it too misses the hardest collisions. So: gate for the ASR-side decision, LLM for context recall, and the cleanup vocabulary hint needs the same "don't override a common word" discipline. [Phase 4a]

### 7. Snyk is a *separate* recall gap (candidate generation, not the replace gate)
ASR renders "Snyk" → "SNC"/"SNCC"; grapheme similarity (~0.5) is below the 0.65 candidate threshold, so it's never even a candidate — the acoustic check never runs. This is where **phonetic** candidate generation would help (the opposite of phonetics' role in over-fire). Track separately. [Phase 3/4]

### Revised recommendation (updates the Options table)
- **The over-fire problem is solved** by the single-token frequency gate — robustly, across real and synthetic audio. That part of Option 4 is validated.
- **Ship it per-term, not blanket:** gate on by default; detect common-word colliders (canonical/alias has high zipf) and either auto-exempt them or surface them as `biasing: "llmOnly"` candidates. Pair with the LLM context leg for recall.
- **Drop the competitor-margin idea** (§2, refuted).
- **Keep candidate-generation recall (Snyk class) as separate work** — phonetic candidate generation.
- **Build mechanics:** owning the replace decision still means vendoring the 0.14.5 rescorer (Option 2) or a thin reimplementation; the gate itself is a few lines. Production needs a shippable frequency source (bundle a compact common-word list; evaluate vs `wordfreq`'s data). Add the dictionary-stress harness as a standing regression guard alongside the over-fire gate (#97/#98).

Full detail + reproduce steps in `docs/explorations/2026-06-16-ctc-rescorer-phase{1,2,3,4-*}.md`. Research branch: `research/ctc-rescorer-phase1`.
