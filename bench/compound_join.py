#!/usr/bin/env python3
"""Compound-join handler experiment (issue #100 / intent-recovery, error class 1).

~41% of term recoveries are compound splits: the user says a compound term, the
ASR hears it correctly but writes it as separate words (worktree -> "work tree",
FluidAudio -> "fluid audio", ultrathink -> "ultra think"). The model is
high-confidence — this is NOT a mishear, it's a missing join. So it should be
handled by a pure-text deterministic rule (match the spoken multi-word form
against the raw transcript, join to the canonical term), peeling the easy class
off before any acoustic/uncertainty machinery. No acoustics => robust to the
synthetic-vs-real gap that tripped Phases 4b/5/6.

This measures the OPPORTUNITY + SAFETY of such a join, over raw ASR hyps:
  - recall  : for clips whose term is a compound, does the join recover it
              (raw split present) — vs already-correct vs unrecoverable (mishear)?
  - false-join: for clips NOT expecting that term, does the spoken form appear
              (a wrong join)?

Spoken forms are derived by: camelCase split, letter<->digit boundary split, and
explicit aliases (for all-lowercase compounds like worktree/ultrathink, which a
dumb greedy split would mis-handle, e.g. redis->'red is'; production derives
these from camelCase + user/learned aliases, NOT blind splitting).

Usage:
  bench/.venv/bin/python bench/compound_join.py \
    --add /tmp/coll5.json bench/fixtures/manifest-colliding.json \
    --add /tmp/bi5.json   bench/fixtures/manifest-biasing.json \
    --add /tmp/of5.json   bench/fixtures/manifest-overfire.json \
    --add /tmp/stress.json bench/fixtures/manifest-stress.json
"""
import argparse
import json
import re

# Explicit spoken forms for all-lowercase compounds a safe auto-splitter can't
# derive (greedy split would produce nonsense like redis->'red is'). Production:
# camelCase auto-split + user/learned aliases.
EXPLICIT = {
    "worktree": ["work tree"],
    "ultrathink": ["ultra think"],   # 'ultra thing' is a MISHEAR, not a clean split
}


def camel_split(term):
    # FluidAudio -> "fluid audio"; leaves single-case words alone
    s = re.sub(r"(?<=[a-z])(?=[A-Z])", " ", term)
    s = re.sub(r"(?<=[A-Za-z])(?=[0-9])|(?<=[0-9])(?=[A-Za-z])", " ", s)  # Route53-style
    parts = s.split()
    return " ".join(parts).lower() if len(parts) > 1 else None


def spoken_forms(term):
    """All multi-word spoken forms of a term (lowercased). Empty if not a compound."""
    forms = set()
    low = term.lower()
    if " " in term:                       # already multi-word (Route 53, Sonnet Opus)
        forms.add(low)
    cs = camel_split(term)
    if cs and cs != low:
        forms.add(cs)
    for f in EXPLICIT.get(low, []):
        forms.add(f)
    # drop any "form" identical to the canonical single token
    return {f for f in forms if " " in f}


def has(text, phrase):
    pat = r"\b" + r"\s+".join(re.escape(w) for w in phrase.split()) + r"\b"
    return re.search(pat, text, re.IGNORECASE) is not None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--add", nargs=2, action="append", metavar=("RESULTS", "MANIFEST"))
    args = ap.parse_args()

    # gather all (clip -> expected terms) and raw hyps across inputs
    clips = {}   # cid -> {"terms":[...], "raw":...}
    all_terms = set()
    for results, manifest in args.add:
        man = {c["id"]: (c.get("terms") or []) for c in json.load(open(manifest))["clips"]}
        raw = {r["id"]: r["hyp"] for r in json.load(open(results)) if not r.get("biasing")}
        for cid, terms in man.items():
            clips[cid] = {"terms": terms, "raw": raw.get(cid, "")}
            all_terms.update(terms)

    # which terms are compounds (have a spoken multi-word form)?
    compounds = {t: spoken_forms(t) for t in all_terms if spoken_forms(t)}
    print("compound terms + spoken forms:")
    for t, fs in sorted(compounds.items()):
        print(f"  {t:<12} <- {sorted(fs)}")

    # RECALL: clips whose expected term is a compound
    recovered = already = unrecoverable = 0
    miss_examples = []
    for cid, c in clips.items():
        for t in c["terms"]:
            if t not in compounds:
                continue
            raw = c["raw"]
            if has(raw, t):
                already += 1
            elif any(has(raw, f) for f in compounds[t]):
                recovered += 1
            else:
                unrecoverable += 1
                miss_examples.append((cid, t, raw[:60]))
    tot = recovered + already + unrecoverable
    print(f"\n=== RECALL on compound-term clips ({tot} occurrences) ===")
    if tot:
        print(f"  already correct (no join needed): {already} ({already/tot:.0%})")
        print(f"  RECOVERED by deterministic join:  {recovered} ({recovered/tot:.0%})")
        print(f"  unrecoverable (mishear/miss):     {unrecoverable} ({unrecoverable/tot:.0%})")
        print(f"  -> join lifts compound recall from {already}/{tot} ({already/tot:.0%}) "
              f"to {already+recovered}/{tot} ({(already+recovered)/tot:.0%})")
    for cid, t, raw in miss_examples[:6]:
        print(f"    miss: {cid:<22} {t:<10} raw={raw!r}")

    # FALSE-JOIN: clips that do NOT expect a given compound term, but its spoken
    # form appears anyway (a wrong join).
    false_joins = []
    for cid, c in clips.items():
        for t, fs in compounds.items():
            if t in c["terms"]:
                continue
            for f in fs:
                if has(c["raw"], f):
                    false_joins.append((cid, f, t))
    print(f"\n=== FALSE-JOIN check (spoken form present where term NOT intended) ===")
    print(f"  false joins: {len(false_joins)}")
    for cid, f, t in false_joins[:10]:
        print(f"    {cid:<22} '{f}' -> {t}")


if __name__ == "__main__":
    main()
