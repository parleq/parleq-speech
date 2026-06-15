#!/usr/bin/env python3
"""Score dictionary over-firing (false positives) for the biasing regression.

Input: an asr-bench results JSON (array of rows, each with id/ref/hyp/biasing)
produced with --dictionary, plus the dictionary JSON used.

For each clip the bench emits two rows: biasing=false (raw ASR) and
biasing=true (vocab-boosted). On the overfire corpus the reference contains NO
dictionary term, so any canonical dictionary term that the rescorer INSERTS
(present in the boosted hyp but not the raw hyp) is an over-fire.

Usage:
    python3 bench/score_overfire.py <results.json> <dictionary.json> [--label NAME]
"""
import argparse
import json
import re
import sys


def load(path):
    with open(path) as f:
        return json.load(f)


def term_count(text, term):
    # Whole-word, case-insensitive. Works for multi-word terms too.
    pat = r"\b" + r"\s+".join(re.escape(w) for w in term.split()) + r"\b"
    return len(re.findall(pat, text, flags=re.IGNORECASE))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("results")
    ap.add_argument("dictionary")
    ap.add_argument("--label", default=None)
    args = ap.parse_args()

    rows = load(args.results)
    terms = [t["term"] for t in load(args.dictionary)["terms"]]
    label = args.label or args.results

    raw = {r["id"]: r for r in rows if not r.get("biasing")}
    boost = {r["id"]: r for r in rows if r.get("biasing")}

    clips_with_overfire = []
    total_overfires = 0
    per_term = {}

    for cid, b in sorted(boost.items()):
        r = raw.get(cid)
        if r is None:
            continue
        hits = []
        for term in terms:
            inserted = term_count(b["hyp"], term) - term_count(r["hyp"], term)
            if inserted > 0:
                hits.append((term, inserted))
                per_term[term] = per_term.get(term, 0) + inserted
                total_overfires += inserted
        if hits:
            clips_with_overfire.append((cid, r["hyp"], b["hyp"], hits))

    print(f"\n=== over-fire report: {label} ===")
    print(f"clips scored:           {len(boost)}")
    print(f"clips with over-fire:   {len(clips_with_overfire)}")
    print(f"total terms over-fired: {total_overfires}")
    if per_term:
        print("by term: " + ", ".join(
            f"{t}×{n}" for t, n in sorted(per_term.items(), key=lambda x: -x[1])))
    print()
    for cid, rhyp, bhyp, hits in clips_with_overfire:
        terms_str = ", ".join(f"{t}×{n}" for t, n in hits)
        print(f"  [{cid}]  +[{terms_str}]")
        print(f"      raw:     {rhyp}")
        print(f"      boosted: {bhyp}")
    # Machine-readable summary line for cross-version diffing.
    print(json.dumps({
        "label": label,
        "clips_scored": len(boost),
        "clips_with_overfire": len(clips_with_overfire),
        "total_overfires": total_overfires,
        "by_term": per_term,
    }))


if __name__ == "__main__":
    main()
