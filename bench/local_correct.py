#!/usr/bin/env python3
"""Phase 18 — the full LOCAL correction pipeline, end-to-end, vs the LLM ceiling.

The real "small ASR-correction model" question: how close can dictionary-aware
LOCAL correction get to the cleanup LLM WITHOUT an LLM pass on every dictation?
This runs the whole handler stack as one corrector over raw ASR and scores it
against the LLM (Ph16: 2.1% WER, 89% term recovery, 0 over-fire) and raw ASR.

Pipeline (all local, dictionary-scoped, per the trunk):
  per word, if near a dict term (grapheme OR near-exact phonetic):
    conf < FLOOR  -> recover to the term            (class-2, Ph6 confidence x dict)
    conf >= FLOOR -> recover IF context fits the term's blurb (class-3, Ph9 embed)
  then deterministic compound/acronym JOIN on the text (class-1, Ph7/15).

The gap to the LLM is the headroom a LEARNED small model could try to close (by
combining the same local signals — confidence, posterior, dict proximity,
context — more optimally than the hand-built rules).

Public clips only. Usage:
  bench/.venv/bin/python bench/local_correct.py --tokens /tmp/pub-tokens.jsonl \
    --results /tmp/pub.json --llm /tmp/pub-llm.jsonl --blurbs bench/blurbs-overfire.json
"""
import argparse
import importlib.util
import json
import re
from collections import defaultdict

import jiwer
from whisper_normalizer.english import EnglishTextNormalizer

NORM = EnglishTextNormalizer()
FLOOR = 0.97
CTX_THRESH = 0.10   # Ph9: term-intended embed ~0.2, common ~0.03; midpoint ~0.1


def _load(mod):
    here = __file__.rsplit("/", 1)[0]
    spec = importlib.util.spec_from_file_location(mod, f"{here}/{mod}.py")
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m); return m


cf = _load("analyze_contextual_fit")
pp = cf.pp
cj = _load("compound_join")


def wer(refs, hyps):
    r = [NORM(x) for x in refs]; h = [NORM(x) for x in hyps]
    keep = [(a, b) for a, b in zip(r, h) if a.strip()]
    return jiwer.wer([a for a, _ in keep], [b for _, b in keep])


def near(word, terms):
    """grapheme OR near-exact phonetic proximity -> (score, canon)."""
    g, who_g = pp.proximity(word, terms)
    p, who_p = cf.phonetic_proximity(word, terms)
    if p >= 0.90 and p > g:
        return p, who_p
    return g, who_g


def local_correct(words, terms, blurb_map, compounds, ctx_all=False):
    out = []
    for i, w in enumerate(words):
        word = w["word"]
        score, who = near(word.lower().strip(".,?!\"'"), terms)
        recovered = None
        if score >= 0.6 and who:
            def ctx_fits():
                if who not in blurb_map:
                    return False
                ctx = " ".join(x["word"] for j, x in enumerate(words) if j != i)
                return cf.embed_cosine(ctx, cf.sanitize_blurb(blurb_map[who])) >= CTX_THRESH
            if w["conf_min"] < FLOOR:                       # class-2: unsure near-term
                recovered = who if (not ctx_all or ctx_fits()) else None
            elif ctx_fits():                                # class-3: confident near-term -> context
                recovered = who
        out.append(recovered if recovered else word)
    text = " ".join(out)
    # class-1: deterministic compound/acronym join (catches correctly-heard splits)
    for canon, forms in compounds.items():
        for f in sorted(forms, key=len, reverse=True):
            pat = r"\b" + r"\s+".join(re.escape(p) for p in f.split()) + r"\b"
            text = re.sub(pat, canon, text, flags=re.IGNORECASE)
    return text


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tokens", required=True)
    ap.add_argument("--results", required=True)
    ap.add_argument("--llm", required=True)
    ap.add_argument("--blurbs", required=True)
    ap.add_argument("--ctx-all", action="store_true",
                    help="gate ALL recoveries (incl class-2) on context fit (precision mode)")
    args = ap.parse_args()

    toks = defaultdict(list)
    for line in open(args.tokens):
        line = line.strip()
        if line:
            r = json.loads(line); toks[r["id"]].append(r)
    res = {r["id"]: r for r in json.load(open(args.results)) if not r.get("biasing")}
    llm = {}
    for line in open(args.llm):
        line = line.strip()
        if line:
            r = json.loads(line); llm[r["id"]] = r["cleaned"]

    terms = pp.load_terms(args.blurbs)
    blurb_map = cf.load_blurbs(args.blurbs)
    term_names = [e["term"] for e in json.load(open(args.blurbs))["terms"]]
    compounds = {t: cj.spoken_forms(t) for t in term_names if cj.spoken_forms(t)}

    ids = [i for i in res if i in toks and i in llm and res[i].get("ref")]
    refs, raw, local, llmc = [], [], [], []
    for i in ids:
        refs.append(res[i]["ref"]); raw.append(res[i]["hyp"]); llmc.append(llm[i])
        local.append(local_correct(cf.ac.group_words(toks[i]), terms, blurb_map, compounds, ctx_all=args.ctx_all))

    print(f"=== LOCAL correction pipeline vs LLM ({len(ids)} public clips) ===\n")
    print("Word Error Rate:")
    print(f"  raw ASR                  {wer(refs, raw):.1%}")
    print(f"  LOCAL pipeline (no LLM)  {wer(refs, local):.1%}   <- the fast on-device path")
    print(f"  cloud cleanup LLM        {wer(refs, llmc):.1%}   <- the ceiling")

    def expected(i):
        slug = i.split("-")[1].lower()
        for tm in term_names:
            if tm.lower().replace(" ", "").startswith(slug) or tm.lower().split()[0] == slug or slug == tm.lower():
                return tm
        return None

    def has(text, tm):
        return re.search(r"\b" + re.escape(tm.lower()) + r"\b", text.lower()) is not None

    c_ids = [i for i in ids if i[0] == "c"]
    o_ids = [i for i in ids if i[0] == "o"]
    def rec(seq):
        return sum(1 for i, t in zip(ids, seq) if i[0] == "c" and (e := expected(i)) and has(t, e))
    def of(seq):
        return sum(1 for i, t in zip(ids, seq) if i[0] == "o" and any(has(t, tm) for tm in term_names))
    nc = len(c_ids) or 1   # guard div-by-zero on a corpus with no c* clips
    rr, rl, rc = rec(raw), rec(local), rec(llmc)
    print(f"\nTerm recovery (c* clips, n={len(c_ids)}):")
    print(f"  raw {rr}/{len(c_ids)} ({rr/nc:.0%})  |  "
          f"LOCAL {rl}/{len(c_ids)} ({rl/nc:.0%})  |  "
          f"LLM {rc}/{len(c_ids)} ({rc/nc:.0%})")
    print(f"\nOver-fire (o* clips, n={len(o_ids)}):")
    print(f"  raw {of(raw)}  |  LOCAL {of(local)}  |  LLM {of(llmc)}")


if __name__ == "__main__":
    main()
