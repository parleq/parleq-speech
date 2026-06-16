#!/usr/bin/env python3
"""Apply the Phase 3 frequency gate to a biasing run and emit a gated results
JSON the canonical scorers (score_overfire.py / score_recall.py / score_wer.py)
can consume directly.

The gate (validated in Phase 1/2, issue #100): SUPPRESS a dictionary replacement
iff the original word is a SINGLE token whose corpus frequency is high (a common
word). Over-fires are always a common single word being overridden; true
recoveries are ASR garble (frequency ~0) or multi-word compounds — neither is
suppressed.

We reconstruct the gated hypothesis from the BOOSTED hyp (biasing=true row) by
REVERTING only the SUPPRESSED replacements (replacementWord -> originalWord),
taken from asr-bench's --dump-replacements JSONL. Reverting (rather than
rebuilding from the raw hyp) guarantees that when the gate suppresses nothing the
gated hyp is byte-identical to the boosted hyp — no reconstruction artifacts.

Frequency source: wordfreq zipf (install in bench/.venv). zipf is log10(per-billion)+9;
0 == not in the corpus (non-word / OOV garble). Threshold T ~ 2.5 cleanly
separates common words (ran 4.87, radish 2.78) from garble (0.0).

Usage:
    bench/.venv/bin/python bench/apply_gate.py \
        --results /tmp/of.json --dump /tmp/of-dump.jsonl --zipf 2.5 --out /tmp/of-gated.json
"""
import argparse
import json
import re
from collections import defaultdict

from wordfreq import zipf_frequency


def suppressed(original_word, zipf_threshold):
    """Gate predicate: suppress iff the original is a single common word."""
    toks = original_word.split()
    if len(toks) != 1:
        return False  # multi-word compound (work tree -> worktree): keep
    return zipf_frequency(toks[0].lower(), "en") >= zipf_threshold


def apply_one(boosted_hyp, replacements, zipf_threshold):
    """Revert only the SUPPRESSED replacements in the boosted hypothesis
    (replacementWord -> originalWord). Kept replacements are left untouched, so
    a clip with nothing suppressed is returned byte-identical to boosted_hyp."""
    text = boosted_hyp
    for r in replacements:
        rep = r.get("replacementWord")
        if rep is None:
            continue
        if not suppressed(r["originalWord"], zipf_threshold):
            continue  # gate kept this replacement -> leave it in place
        pat = r"\b" + r"\s+".join(re.escape(w) for w in rep.split()) + r"\b"
        text = re.sub(pat, r["originalWord"], text, count=1, flags=re.IGNORECASE)
    return text


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--results", required=True, help="asr-bench results JSON")
    ap.add_argument("--dump", required=True, help="--dump-replacements JSONL for the same run")
    ap.add_argument("--zipf", type=float, default=2.5, help="suppress single words with zipf >= this")
    ap.add_argument("--out", required=True, help="gated results JSON to write")
    args = ap.parse_args()

    rows = json.load(open(args.results))
    dump = defaultdict(list)
    with open(args.dump) as f:
        for line in f:
            line = line.strip()
            if line:
                r = json.loads(line)
                dump[r["id"]].append(r)

    raw = {r["id"]: r for r in rows if not r.get("biasing")}
    out_rows = []
    n_sup = n_keep = 0
    for r in rows:
        if not r.get("biasing"):
            out_rows.append(r)
            continue
        cid = r["id"]
        reps = dump.get(cid, [])
        for rep in reps:
            if rep.get("replacementWord") is not None and suppressed(rep["originalWord"], args.zipf):
                n_sup += 1
            else:
                n_keep += 1
        gated = apply_one(r["hyp"], reps, args.zipf)  # r is the boosted row
        nr = dict(r)
        nr["hyp"] = gated
        out_rows.append(nr)

    json.dump(out_rows, open(args.out, "w"), indent=2, sort_keys=True)
    print(f"gate zipf>={args.zipf}: suppressed {n_sup} / kept {n_keep} replacements "
          f"-> {args.out}")


if __name__ == "__main__":
    main()
