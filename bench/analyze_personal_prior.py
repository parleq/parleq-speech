#!/usr/bin/env python3
"""Personal-prior experiment (issue #100 / intent-recovery program, bet B).

Tests whether acoustic confidence + the user's dictionary together resolve the
irreducible case that text and CTC margin both failed: a word that is
phonetically one of the user's terms — did they mean the COMMON WORD or the TERM?

Two classes, BOTH near a dictionary term:
  A "meant common word" — CORRECT words in the over-fire corpus near a term
    (ran/crane/radish): the user said the ordinary word; do NOT recover.
  B "meant the term"    — ERROR words in colliding/stress corpora near a term
    (number/Dino/readies/SNCC): a term mis-heard; SHOULD recover.

If confidence(A) clusters high (~0.99) and confidence(B) lower, then the rule
"near-a-user-term AND confidence < floor  ⇒  they meant the term" separates them
— a personalized escalation signal that confidence-alone and dictionary-alone
each cannot provide.

Proximity = max difflib ratio of the word against each term + its aliases (exact
alias match counts as 1.0). Crude (grapheme, not phonetic) — a floor, not a
ceiling; phonetic proximity would only help.

Usage: feed one or more (tokens,results,dictionary,role) triples; role ∈ {A,B}.
  bench/.venv/bin/python bench/analyze_personal_prior.py \
    --add /tmp/of5-tokens.jsonl /tmp/of5-tok.json bench/dictionary-overfire.json A \
    --add /tmp/coll5-tokens.jsonl /tmp/coll5-tok.json bench/dictionary-overfire.json B \
    --add /tmp/stresscoll-tokens.jsonl /tmp/stresscoll-tok.json bench/dictionary-stress.json B
"""
import argparse
import difflib
import json
import statistics as st
from collections import defaultdict
import importlib.util

# reuse word-grouping + alignment from analyze_confidence.py
_spec = importlib.util.spec_from_file_location("ac", __file__.rsplit("/", 1)[0] + "/analyze_confidence.py")
ac = importlib.util.module_from_spec(_spec); _spec.loader.exec_module(ac)


def load_terms(dict_path):
    d = json.load(open(dict_path))
    terms = []
    for e in d["terms"]:
        cands = [e["term"]] + [a for a in e.get("aliases", []) if a.strip()]
        terms.append((e["term"], [c.lower() for c in cands]))
    return terms


def proximity(word, terms):
    """max similarity of `word` to any term/alias; returns (score, term)."""
    w = word.lower().strip(".,?!\"'")
    best, who = 0.0, None
    for canon, cands in terms:
        for c in cands:
            r = 1.0 if w == c else difflib.SequenceMatcher(a=w, b=c, autojunk=False).ratio()
            if r > best:
                best, who = r, canon
    return best, who


def collect(tokens_path, results_path, dict_path, role, near=0.6):
    toks = defaultdict(list)
    for line in open(tokens_path):
        line = line.strip()
        if line:
            r = json.loads(line); toks[r["id"]].append(r)
    refs = {r["id"]: r for r in json.load(open(results_path)) if not r.get("biasing")}
    terms = load_terms(dict_path)
    rows = []
    for cid, tlist in toks.items():
        ref = refs.get(cid, {}).get("ref", "")
        if not ref:
            continue
        words = ac.group_words(tlist)
        for op, w in ac.align(words, ref.split()):
            is_err = op != "match"
            # Class A = correct words near a term; Class B = error words near a term.
            want = (role == "A" and not is_err) or (role == "B" and is_err)
            if not want:
                continue
            prox, who = proximity(w["word"], terms)
            if prox >= near:
                rows.append({"cid": cid, "word": w["word"], "conf": w["conf_min"],
                             "prox": prox, "term": who, "role": role})
    return rows


def summarize(rows, role):
    sub = [r for r in rows if r["role"] == role]
    confs = [r["conf"] for r in sub]
    print(f"\nClass {role} ({'meant common word' if role=='A' else 'meant the term'}): "
          f"{len(sub)} near-term words")
    if confs:
        print(f"  confidence  median={st.median(confs):.3f}  mean={st.mean(confs):.3f}  "
              f"min={min(confs):.3f}  max={max(confs):.3f}")
        for lo, hi in [(0.0, 0.9), (0.9, 0.97), (0.97, 1.01)]:
            n = sum(1 for c in confs if lo <= c < hi)
            print(f"    conf [{lo:.2f},{hi:.2f}): {n:>3}  ({n/len(confs):.0%})")
    return sub


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--add", nargs=4, action="append", metavar=("TOKENS", "RESULTS", "DICT", "ROLE"))
    ap.add_argument("--near", type=float, default=0.6)
    args = ap.parse_args()
    allrows = []
    for tok, res, dic, role in args.add:
        allrows += collect(tok, res, dic, role, near=args.near)
    A = summarize(allrows, "A")
    B = summarize(allrows, "B")
    if A and B:
        a = [r["conf"] for r in A]; b = [r["conf"] for r in B]
        print(f"\nROC-AUC (confidence separates A 'common' from B 'term'): "
              f"{ac.auc(b, a):.3f}   (low conf => meant-the-term)")
        print("Decision rule sweep  —  near-a-term AND conf < T  => treat as 'meant the term':")
        print("  T       recovers B (want high)      false-flags A (want low)")
        for t in [0.90, 0.95, 0.97, 0.98, 0.99, 1.00]:
            br = sum(1 for c in b if c < t); af = sum(1 for c in a if c < t)
            print(f"  {t:.2f}    {br:>3}/{len(b)} ({br/len(b):.0%})            {af:>3}/{len(a)} ({af/len(a):.0%})")
        print("\nClass A high-confidence words (the genuine common words we must NOT flag):")
        for r in sorted(A, key=lambda x: -x["conf"])[:6]:
            print(f"    conf={r['conf']:.3f}  {r['word']!r:<10} ~{r['term']}  ({r['cid']})")
        print("Class B low-confidence words (term mishears we WANT to flag):")
        for r in sorted(B, key=lambda x: x["conf"])[:8]:
            print(f"    conf={r['conf']:.3f}  {r['word']!r:<10} ~{r['term']}  ({r['cid']})")


if __name__ == "__main__":
    main()
