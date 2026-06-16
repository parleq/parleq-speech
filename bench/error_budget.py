#!/usr/bin/env python3
"""Phase 14 — the error budget (intent-recovery capstone accounting).

Tests the program's central claim: every dictation error falls into one of the
three handler classes (or is scoring noise), so the 3 handlers + the trust
surface COVER the error space. Classifies each aligned hyp error:

  noise        — casing/punctuation/contraction artifact (norm(hyp)~norm(ref));
                 not a real error, a WER-alignment artifact.
  class-1      — compound split: hyp word + an adjacent word concatenates to a
                 dict term (work+tree -> worktree). Handler: Ph7 deterministic join.
  class-2      — low-confidence (conf < FLOOR) mishear/garble. Handler: the trust
                 surface flags it (Ph12) and/or confidence x dict (Ph6).
  class-3      — confident (conf >= FLOOR) AND near a dict term (grapheme/phonetic).
                 Handler: contextual-fit (Ph9).
  unexplained  — confident, off-dictionary, not compound: the genuine residual
                 the program does NOT cover.

Also emits a NORMALIZED trust curve (real errors only — noise dropped), to strip
the WER artifacts that muddied Ph12.

Usage:
  bench/.venv/bin/python bench/error_budget.py --tokens /tmp/trust-tokens.jsonl \
    --results /tmp/trust.json --dictionary bench/dictionary-work.json
"""
import argparse
import difflib
import importlib.util
import json
import re
from collections import defaultdict, Counter

import jellyfish

FLOOR = 0.97   # correct-word confidence floor (Ph5/6): >= FLOOR == "confident"


def _load(mod):
    here = __file__.rsplit("/", 1)[0]
    spec = importlib.util.spec_from_file_location(mod, f"{here}/{mod}.py")
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m); return m


ac = _load("analyze_confidence")
pp = _load("analyze_personal_prior")


def norm(w):
    return re.sub(r"[^a-z0-9]", "", w.lower())


def metaphone(s):
    return jellyfish.metaphone(re.sub(r"[^a-z]", "", s.lower()))


def near_term(word, terms):
    """grapheme OR near-exact phonetic proximity to any term/alias."""
    w = word.lower().strip(".,?!\"'")
    g, _ = pp.proximity(w, terms)
    mw = metaphone(w)
    p = 0.0
    if mw:
        for _, cands in terms:
            for c in cands:
                mc = metaphone(c)
                if mc:
                    p = max(p, 1.0 if mw == mc else difflib.SequenceMatcher(a=mw, b=mc, autojunk=False).ratio())
    return max(g, p if p >= 0.90 else 0.0)


def is_compound(hyp_words, j, terms):
    """does hyp[j] joined with an adjacent hyp word match a dict term?"""
    w = norm(hyp_words[j]["word"])
    for k in (j - 1, j + 1):
        if 0 <= k < len(hyp_words):
            joined = (w + norm(hyp_words[k]["word"])) if k > j else (norm(hyp_words[k]["word"]) + w)
            for canon, cands in terms:
                for c in cands:
                    if difflib.SequenceMatcher(a=joined, b=norm(c), autojunk=False).ratio() >= 0.85:
                        return True
    return False


def classify(hyp_words, j, ref_text, terms):
    hw = hyp_words[j]
    conf = hw["conf_min"]
    if ref_text and difflib.SequenceMatcher(a=norm(hw["word"]), b=norm(ref_text), autojunk=False).ratio() >= 0.9:
        return "noise"
    if is_compound(hyp_words, j, terms):
        return "class-1 compound"
    nt = near_term(hw["word"], terms)
    if nt >= 0.6:
        return "class-3 confident-near-term" if conf >= FLOOR else "class-2 low-conf-near-term"
    return "unexplained confident-off-dict" if conf >= FLOOR else "class-2 low-conf-garble"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tokens", required=True)
    ap.add_argument("--results", required=True)
    ap.add_argument("--dictionary", required=True)
    args = ap.parse_args()
    terms = pp.load_terms(args.dictionary)

    toks = defaultdict(list)
    for line in open(args.tokens):
        line = line.strip()
        if line:
            r = json.loads(line); toks[r["id"]].append(r)
    refs = {r["id"]: r for r in json.load(open(args.results)) if not r.get("biasing")}

    cats = Counter()
    confident_cats = Counter()
    real_words = []   # (conf, is_real_error) with noise excluded — for normalized trust
    for cid, tlist in toks.items():
        ref = refs.get(cid, {}).get("ref", "")
        if not ref:
            continue
        hyp_words = ac.group_words(tlist)
        rwords = ref.split()
        h = [w["word"].lower().strip(".,?!\"'") for w in hyp_words]
        r = [x.lower().strip(".,?!\"'") for x in rwords]
        sm = difflib.SequenceMatcher(a=r, b=h, autojunk=False)
        err_idx = {}   # hyp index -> ref text
        for tag, i1, i2, j1, j2 in sm.get_opcodes():
            if tag == "replace":
                for jj in range(j1, j2):
                    err_idx[jj] = " ".join(rwords[i1:i2])
            elif tag == "insert":
                for jj in range(j1, j2):
                    err_idx[jj] = ""
        for jj, w in enumerate(hyp_words):
            if jj in err_idx:
                cat = classify(hyp_words, jj, err_idx[jj], terms)
                cats[cat] += 1
                if w["conf_min"] >= FLOOR:
                    confident_cats[cat] += 1
                real_words.append((w["conf_min"], cat != "noise"))
            else:
                real_words.append((w["conf_min"], False))

    total_err = sum(v for k, v in cats.items())
    real_err = sum(v for k, v in cats.items() if k != "noise")
    print(f"=== ERROR BUDGET ({total_err} aligned errors; {cats['noise']} are WER noise => "
          f"{real_err} real errors) ===\n")
    order = ["class-1 compound", "class-2 low-conf-near-term", "class-2 low-conf-garble",
             "class-3 confident-near-term", "unexplained confident-off-dict", "noise"]
    for k in order:
        if cats[k]:
            handler = {"class-1 compound": "Ph7 deterministic join",
                       "class-2 low-conf-near-term": "Ph6 conf x dict / surface flags",
                       "class-2 low-conf-garble": "surface flags (Ph12)",
                       "class-3 confident-near-term": "Ph9 contextual-fit",
                       "unexplained confident-off-dict": "RESIDUAL — uncovered",
                       "noise": "(not a real error)"}[k]
            print(f"  {k:32} {cats[k]:>3}   -> {handler}")

    print(f"\n=== the CONFIDENT errors (conf>={FLOOR}) — the trust-surface blind spot ===")
    cc = sum(confident_cats.values())
    for k in order:
        if confident_cats[k]:
            print(f"  {k:32} {confident_cats[k]:>3}  ({confident_cats[k]/cc:.0%})")
    handler_fixable = sum(confident_cats[k] for k in
                          ["class-1 compound", "class-3 confident-near-term"])
    print(f"  -> handler-fixable (class-1+3): {handler_fixable}/{cc} "
          f"({handler_fixable/cc:.0%}) of confident errors")

    # normalized trust (noise dropped)
    n = len(real_words); ne = sum(1 for _, e in real_words if e)
    print(f"\n=== NORMALIZED trust ({n} words, {ne} real errors, noise excluded) ===")
    print("   re-read     errors-caught")
    confs = sorted(c for c, _ in real_words)
    for budget in [0.05, 0.10, 0.15, 0.20]:
        k = max(1, int(budget * n)); T = confs[k - 1]
        flagged = [(c, e) for c, e in real_words if c <= T][:k]
        caught = sum(1 for _, e in flagged if e) / ne if ne else 0
        print(f"   {budget:>4.0%}        {caught:>4.0%}   (lift {caught/budget:.1f}x)")


if __name__ == "__main__":
    main()
