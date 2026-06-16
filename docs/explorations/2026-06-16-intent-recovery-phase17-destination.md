# Intent-recovery Phase 17 — destination-conditioned cleanup

**Date:** 2026-06-16
**Status:** Feasibility result. Tests whether conditioning the cleanup on the **destination** (where the text will be pasted — code editor / chat / email / doc) produces appropriately different output. Uses Parleq's real baseCleanup prompt + a destination addendum via Vertex `gemini-2.5-flash`, on 8 destination-divergent public utterances. Single run — directional.

## The idea

The same dictated words want different cleanup depending on where they land: a code editor wants `=>`, camelCase, CLI flags, digits; a chat message wants markdown (`**bold**`, bullet lists, `code`); an email wants a polite greeting and full sentences; a doc wants clean prose. Destination is a conditioning prior on intent. Does adding it to the prompt actually steer the output?

## Method

For each utterance, run cleanup four times — once per destination, each with `baseCleanup + "The cleaned text will be pasted into: <destination>. Format appropriately."` Measure **divergence** (do the four outputs differ?) and **appropriateness** (do destination-specific regex markers appear: code wants `=>`/camelCase/`--flag`; chat wants `**bold**`/bullets; email wants a greeting?).

## Results

- **Divergence: 6/8** utterances produced destination-varying output.
- **Appropriateness: 11/12** expected destination markers present (**92%**).

Representative behavior:

| utterance | what destination conditioning produced |
|---|---|
| "make the word urgent bold and list milk eggs and bread" | **chat** → `**urgent**` + a real `- milk / - eggs / - bread` bullet list; doc/email → quotes + inline list |
| "call get user by id …" | **code** → `getUserById` (no backticks/prose); others → `` `getUserById` `` framed |
| "install … npm install dash dash save dev" | all → `--save-dev`; **code** drops the backtick framing the others add |
| "hey just checking … thanks" | **email** → "**Hi**, just checking…"; others → "Hey, …" |
| "email … jane dot doe at example dot com" | all four identical → `jane.doe@example.com` (correctly destination-**invariant**) |
| "set the timeout to five hundred milliseconds" | all four identical → `500 milliseconds` (correctly invariant) |

## The finding

**Destination conditioning is feasible and the model adapts appropriately (92% markers, 6/8 diverge) — but the value is concentrated in *formatting/tone*, not in symbol/number normalization.**

- **Real destination-driven changes:** markdown for chat (bullet lists, bold), code syntax/identifier casing and dropping prose framing for code, greeting/tone for email. These are genuine and correctly steered.
- **Correctly invariant:** email addresses, version strings, "500 ms" — the base cleanup already normalizes these the same way for everyone, so they *shouldn't* diverge, and they don't. The 2/8 non-diverging cases are right, not failures.
- **Conservative rewriting:** the model won't aggressively re-code description-like dictation ("arrow function … x plus one" stayed prose, didn't become `x => x+1`) — a reasonable safety, but it means "code destination" is more about casing/flags/framing than deep code synthesis.

## Implication

Destination conditioning is a **cheap, additive prompt lever** that works today — no new model, no new network boundary (it rides the existing cleanup call). It maps naturally onto Parleq's **existing per-app preset mechanism** (`preset_app_defaults`): a destination/app could carry a formatting profile (chat→markdown, editor→code-style, mail→formal) folded into the same single cleanup call the presets already use. The highest-value targets are the formatting-divergent destinations (chat markdown, code framing, email tone); number/symbol normalization needs no destination signal.

## Honest bounds

- 8 hand-crafted utterances, single run, single model, no human quality rating — this shows *feasibility and direction*, not production quality. Some "divergence" is superficial (backticks, punctuation).
- The expected-marker regexes encode my judgment of "appropriate"; a real eval needs human raters per destination.
- Destinations were described in the prompt; deriving them from the actual paste target (front app / preset) is the productization step.

## Reproduce

```bash
bench/.venv/bin/python bench/destination_probe.py --out /tmp/dest.jsonl
```
