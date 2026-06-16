#!/usr/bin/env python3
"""Foundational experiment for the intent-recovery reframe (issue #100 Phase 5):
is the TDT ASR's per-token confidence informative about WHERE it is wrong?

Reads asr-bench's --dump-tokens JSONL (per-token: token, confidence, timing) and
the results JSON (ref + hyp per clip). Groups subword tokens into words (carrying
min & mean confidence), aligns hyp words to ref words, labels each hyp word
correct / substitution / insertion, and reports:
  (1) separation  — confidence of correct vs error words (+ ROC-AUC of confidence
      as an error detector; 0.5 = uninformative, 1.0 = perfect)
  (2) calibration — accuracy within confidence bins (does high confidence == correct?)

Usage:
  bench/.venv/bin/python bench/analyze_confidence.py --tokens /tmp/coll5-tokens.jsonl \
      --results /tmp/coll5-tok.json [--inspect]
"""
import argparse
import json
import re
import sys
from collections import defaultdict


def group_words(tokens):
    """Group subword tokens into words. Detects the word-start marker
    (SentencePiece '▁', or a leading space). Returns list of
    {word, conf_min, conf_mean, start, end}."""
    if not tokens:
        return []
    text = "".join(t["token"] for t in tokens)
    marker = "▁" if "▁" in text else (" " if any(t["token"][:1] == " " for t in tokens) else None)
    words, cur = [], []

    def flush():
        if not cur:
            return
        w = "".join(t["token"] for t in cur)
        w = w.replace("▁", " ").strip()
        if not w:
            cur.clear(); return
        confs = [t["confidence"] for t in cur]
        words.append({"word": w, "conf_min": min(confs), "conf_mean": sum(confs) / len(confs),
                      "start": cur[0]["startTime"], "end": cur[-1]["endTime"]})
        cur.clear()

    for t in sorted(tokens, key=lambda x: x["idx"]):
        is_start = (marker == "▁" and t["token"].startswith("▁")) or \
                   (marker == " " and t["token"][:1] == " ")
        if is_start and cur:
            flush()
        cur.append(t)
    flush()
    return words


def align(hyp_words, ref_words):
    """Word-level alignment via difflib; yields (op, hyp_word_dict) for hyp words,
    op in {match, sub, ins}."""
    import difflib
    h = [w["word"].lower().strip(".,?!\"'") for w in hyp_words]
    r = [w.lower().strip(".,?!\"'") for w in ref_words]
    sm = difflib.SequenceMatcher(a=r, b=h, autojunk=False)
    out = []
    for tag, i1, i2, j1, j2 in sm.get_opcodes():
        if tag == "equal":
            for j in range(j1, j2): out.append(("match", hyp_words[j]))
        elif tag == "replace":
            for j in range(j1, j2): out.append(("sub", hyp_words[j]))
        elif tag == "insert":
            for j in range(j1, j2): out.append(("ins", hyp_words[j]))
        # delete (ref words with no hyp) -> no hyp token to score
    return out


def auc(pos, neg):
    """ROC-AUC that LOW confidence flags errors: P(error_conf < correct_conf).
    pos = error confidences, neg = correct confidences. Returns prob a random
    error has lower confidence than a random correct word."""
    if not pos or not neg:
        return float("nan")
    wins = ties = 0
    for p in pos:
        for n in neg:
            if p < n: wins += 1
            elif p == n: ties += 1
    return (wins + 0.5 * ties) / (len(pos) * len(neg))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tokens", required=True)
    ap.add_argument("--results", required=True)
    ap.add_argument("--field", default="conf_min", choices=["conf_min", "conf_mean"])
    ap.add_argument("--inspect", action="store_true", help="print raw token format for a few clips and exit")
    args = ap.parse_args()

    toks = defaultdict(list)
    for line in open(args.tokens):
        line = line.strip()
        if line:
            r = json.loads(line); toks[r["id"]].append(r)
    refs = {r["id"]: r for r in json.load(open(args.results)) if not r.get("biasing")}

    if args.inspect:
        for cid in list(toks)[:3]:
            print(f"\n{cid}: ref={refs.get(cid,{}).get('ref','')!r}")
            print("  tokens:", [(t["token"], round(t["confidence"], 3)) for t in sorted(toks[cid], key=lambda x: x["idx"])])
            print("  words:", [(w["word"], round(w["conf_min"], 3)) for w in group_words(toks[cid])])
        return

    correct, error = [], []
    err_examples = []
    for cid, tlist in toks.items():
        ref = refs.get(cid, {}).get("ref", "")
        if not ref:
            continue
        words = group_words(tlist)
        for op, w in align(words, ref.split()):
            c = w[args.field]
            if op == "match":
                correct.append(c)
            else:
                error.append(c)
                err_examples.append((cid, op, w["word"], round(c, 3)))

    import statistics as st
    print(f"=== {args.tokens} ({args.field}) ===")
    print(f"correct words: {len(correct)} | error words: {len(error)}")
    if correct and error:
        print(f"  correct conf  median={st.median(correct):.3f}  mean={st.mean(correct):.3f}")
        print(f"  error   conf  median={st.median(error):.3f}  mean={st.mean(error):.3f}")
        print(f"  ROC-AUC (low conf detects error): {auc(error, correct):.3f}   (0.5=useless, 1.0=perfect)")
    # calibration
    print("  calibration (confidence bin -> word accuracy):")
    allw = [(c, 1) for c in correct] + [(c, 0) for c in error]
    for lo in [0.0, 0.5, 0.7, 0.8, 0.9, 0.95, 0.99]:
        hi = {0.0: 0.5, 0.5: 0.7, 0.7: 0.8, 0.8: 0.9, 0.9: 0.95, 0.95: 0.99, 0.99: 1.01}[lo]
        bin_ = [ok for c, ok in allw if lo <= c < hi]
        if bin_:
            print(f"    [{lo:.2f},{hi:.2f}): n={len(bin_):>4}  accuracy={sum(bin_)/len(bin_):.1%}")
    print("  lowest-confidence error words (sample):")
    for cid, op, w, c in sorted(err_examples, key=lambda x: x[3])[:10]:
        print(f"    conf={c:.3f}  {op:<4} {w!r}  ({cid})")


if __name__ == "__main__":
    main()
