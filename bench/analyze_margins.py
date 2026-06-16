#!/usr/bin/env python3
"""Phase-1 diagnostic for issue #100: is the custom-dictionary over-fire driven
by the flat +cbw boost, and would a competitor-relative margin gate separate
false positives from true positives?

Reads the --dump-replacements JSONL emitted by asr-bench (one row per APPLIED
replacement). Each row carries:
  originalScore     raw CTC score of the original word over the search window
  replacementScore  BOOSTED vocab CTC score (= rawVocab + adaptiveCbw)
  cbw               the flat base context-biasing weight used for the run
  reason            FluidAudio's decision string (often encodes adaptive/tokens)

The current gate that fired is: replacementScore > originalScore
  => boostedMargin = replacementScore - originalScore   (> 0 for every applied row)

The competitor-relative quantity a margin gate (A1) would use is the RAW vocab
score vs the original:
  rawMargin = replacementScore - cbw - originalScore
(exact for short terms where adaptiveCbw == flat cbw; an approximation for terms
longer than the adaptive reference token count, which inflates cbw — so rawMargin
is a slight UNDER-estimate of the true raw margin for long terms. The over-fire
terms are short, so it's exact where it matters.)

A row with rawMargin < 0 is "cbw-carried": the vocab term did NOT beat the
original on raw CTC; only the +cbw flipped the decision. If the over-fire false
positives are overwhelmingly cbw-carried, then requiring rawMargin > delta (a
competitor-relative gate) eliminates them.

Usage:
    python3 bench/analyze_margins.py --false /tmp/of-dump.jsonl --true /tmp/bi-dump.jsonl
"""
import argparse
import json
import statistics as stats


def load(path):
    rows = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            r = json.loads(line)
            cbw = r["cbw"]
            rep = r.get("replacementScore")
            orig = r["originalScore"]
            if rep is None:
                continue
            r["boostedMargin"] = rep - orig
            r["rawMargin"] = rep - cbw - orig
            rows.append(r)
    return rows


def describe(name, rows):
    print(f"\n=== {name}: {len(rows)} applied replacements ===")
    if not rows:
        return
    raw = [r["rawMargin"] for r in rows]
    boosted = [r["boostedMargin"] for r in rows]
    cbw_carried = [r for r in rows if r["rawMargin"] < 0]
    print(f"  cbw-carried (rawMargin < 0, i.e. only +cbw flipped it): "
          f"{len(cbw_carried)}/{len(rows)}  ({len(cbw_carried)/len(rows):.0%})")
    print(f"  rawMargin     min/median/max: "
          f"{min(raw):+.3f} / {stats.median(raw):+.3f} / {max(raw):+.3f}")
    print(f"  boostedMargin min/median/max: "
          f"{min(boosted):+.3f} / {stats.median(boosted):+.3f} / {max(boosted):+.3f}")
    print(f"  (cbw used: {rows[0]['cbw']})")
    print("  sample rows (word -> term | rawMargin | boostedMargin):")
    for r in sorted(rows, key=lambda x: x["rawMargin"])[:8]:
        print(f"    {r['id']:<28} {r['originalWord']!r} -> {r['replacementWord']!r}"
              f"  raw={r['rawMargin']:+.3f} boosted={r['boostedMargin']:+.3f}")


def sweep(false_rows, true_rows):
    """Sweep a competitor-relative threshold delta on rawMargin: a replacement
    fires only if rawMargin > delta. Show surviving false positives (want LOW)
    vs surviving true positives (want HIGH). delta=-cbw reproduces the current
    gate (everything currently-applied survives)."""
    print("\n=== competitor-relative gate sweep (fire iff rawMargin > delta) ===")
    print("  delta      false-positives surviving   true-positives surviving")
    cbw = false_rows[0]["cbw"] if false_rows else (true_rows[0]["cbw"] if true_rows else 2.0)
    deltas = [-cbw, -1.0, -0.5, -0.25, 0.0, 0.25, 0.5, 1.0]
    for d in deltas:
        fp = sum(1 for r in false_rows if r["rawMargin"] > d)
        tp = sum(1 for r in true_rows if r["rawMargin"] > d)
        tag = "  <- current gate (boosted > original)" if abs(d + cbw) < 1e-6 else ""
        print(f"  {d:+.2f}      {fp:>3}/{len(false_rows):<3}                     "
              f"{tp:>3}/{len(true_rows):<3}{tag}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--false", dest="false_path", required=True,
                    help="over-fire dump JSONL (all applied = false positives)")
    ap.add_argument("--true", dest="true_path", required=True,
                    help="recall dump JSONL (applied = mostly true positives)")
    args = ap.parse_args()

    false_rows = load(args.false_path)
    true_rows = load(args.true_path)
    describe("FALSE POSITIVES (over-fire corpus)", false_rows)
    describe("TRUE-ish POSITIVES (recall corpus; longer terms — length caveat)", true_rows)
    if false_rows or true_rows:
        sweep(false_rows, true_rows)
    print("\nNote: recall-corpus terms are longer/more distinctive than the short "
          "over-fire terms, so the TP rawMargins are an OPTIMISTIC proxy for short "
          "true terms. Phase 2 must add true short-term clips to close this gap.")


if __name__ == "__main__":
    main()
