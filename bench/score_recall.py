#!/usr/bin/env python3
"""Score true-positive biasing recall for the dictionary-rescorer.

Complements score_overfire.py. On the biasing corpus each clip is SUPPOSED to
contain its dictionary term(s) (the manifest carries them in `terms`). Recall =
fraction of expected (clip, term) pairs whose term appears in the hypothesis.
We report it for the raw ASR (biasing=false) and the vocab-boosted hyp
(biasing=true); the rescorer's *value* is (boosted recall − raw recall), i.e.
terms it correctly adds. Read alongside score_overfire.py's false-positive count
to place a tuning setting on the precision/recall ROC.

Usage:
    python3 bench/score_recall.py <results.json> <manifest.json> [--label NAME]
"""
import argparse
import json
import re
import sys


def has_term(text, term):
    pat = r"\b" + r"\s+".join(re.escape(w) for w in term.split()) + r"\b"
    return re.search(pat, text, flags=re.IGNORECASE) is not None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("results")
    ap.add_argument("manifest")
    ap.add_argument("--label", default=None)
    args = ap.parse_args()

    rows = json.load(open(args.results))
    manifest = json.load(open(args.manifest))
    label = args.label or args.results

    expected = {c["id"]: (c.get("terms") or []) for c in manifest["clips"]}
    raw = {r["id"]: r for r in rows if not r.get("biasing")}
    boost = {r["id"]: r for r in rows if r.get("biasing")}

    pairs = raw_hit = boost_hit = 0
    missed_by_boost = []
    for cid, terms in expected.items():
        if cid not in boost:
            continue
        for term in terms:
            pairs += 1
            r_ok = has_term(raw.get(cid, {}).get("hyp", ""), term)
            b_ok = has_term(boost[cid]["hyp"], term)
            raw_hit += r_ok
            boost_hit += b_ok
            if not b_ok:
                missed_by_boost.append((cid, term, boost[cid]["hyp"]))

    rr = raw_hit / pairs if pairs else 0.0
    br = boost_hit / pairs if pairs else 0.0
    print(f"\n=== recall report: {label} ===")
    print(f"expected (clip,term) pairs: {pairs}")
    print(f"raw ASR recall:      {raw_hit}/{pairs}  ({rr:.1%})")
    print(f"boosted recall:      {boost_hit}/{pairs}  ({br:.1%})")
    print(f"rescorer net adds:   {boost_hit - raw_hit:+d}")
    for cid, term, hyp in missed_by_boost[:12]:
        print(f"  miss [{cid}] want '{term}': {hyp}")
    print(json.dumps({
        "label": label, "pairs": pairs,
        "raw_recall": round(rr, 4), "boosted_recall": round(br, 4),
        "net_adds": boost_hit - raw_hit,
    }))


if __name__ == "__main__":
    main()
