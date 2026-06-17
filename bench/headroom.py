#!/usr/bin/env python3
"""Phase 16 — headroom / oracle experiment (should we build our own small LLM?).

Quantifies how much accuracy a CUSTOM small correction model could add over what
we already have. The chain:
  oracle (perfect)        = 0 WER  (the ceiling)
  raw ASR                 = baseline WER
  local deterministic     = + compound/acronym join only (Ph7/15) — NO model
  cloud cleanup LLM        = what Parleq already ships (gemini-2.5-flash)
A custom small model's accuracy is bounded above by a good general LLM, so the
LLM residual WER is (approximately) the hard part a small model is UNLIKELY to
beat. If that residual is small, a custom model has ~no ACCURACY headroom — its
only case is non-accuracy (size/speed/privacy vs the 4GB tier, or less over-fire).

Also measures the LLM's OVER-FIRE (inserting a dict term where none was meant) —
the faithfulness cost a specialized model could in principle avoid.

Public clips only (no proprietary text to the cloud).

Usage:
  bench/.venv/bin/python bench/headroom.py --results /tmp/pub.json \
    --llm /tmp/pub-llm.jsonl --dictionary bench/blurbs-overfire.json
"""
import argparse
import importlib.util
import json
import re

import jiwer
from whisper_normalizer.english import EnglishTextNormalizer

NORM = EnglishTextNormalizer()


def _load(mod):
    here = __file__.rsplit("/", 1)[0]
    spec = importlib.util.spec_from_file_location(mod, f"{here}/{mod}.py")
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m); return m


cj = _load("compound_join")


def wer(refs, hyps):
    r = [NORM(x) for x in refs]
    h = [NORM(x) for x in hyps]
    keep = [(a, b) for a, b in zip(r, h) if a.strip()]
    return jiwer.wer([a for a, _ in keep], [b for _, b in keep])


def apply_local_join(text, compounds):
    for canon, forms in compounds.items():
        for f in sorted(forms, key=len, reverse=True):
            pat = r"\b" + r"\s+".join(re.escape(w) for w in f.split()) + r"\b"
            text = re.sub(pat, canon, text, flags=re.IGNORECASE)
    return text


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--results", required=True)
    ap.add_argument("--llm", required=True)
    ap.add_argument("--dictionary", required=True)
    args = ap.parse_args()

    res = {r["id"]: r for r in json.load(open(args.results)) if not r.get("biasing")}
    llm = {}
    for line in open(args.llm):
        line = line.strip()
        if line:
            r = json.loads(line); llm[r["id"]] = r["cleaned"]

    terms = [e["term"] for e in json.load(open(args.dictionary))["terms"]]
    compounds = {t: cj.spoken_forms(t) for t in terms if cj.spoken_forms(t)}

    ids = [i for i in res if i in llm and res[i].get("ref")]
    refs = [res[i]["ref"] for i in ids]
    raw = [res[i]["hyp"] for i in ids]
    local = [apply_local_join(res[i]["hyp"], compounds) for i in ids]
    cleaned = [llm[i] for i in ids]

    print(f"=== HEADROOM ({len(ids)} public clips) ===\n")
    print("Word Error Rate (lower = closer to the oracle):")
    print(f"  oracle (perfect)            0.0%")
    w_raw, w_loc, w_llm = wer(refs, raw), wer(refs, local), wer(refs, cleaned)
    print(f"  cloud cleanup LLM           {w_llm:.1%}   <- what Parleq already ships")
    print(f"  local deterministic only    {w_loc:.1%}   (compound/acronym join, NO model)")
    print(f"  raw ASR                     {w_raw:.1%}   (baseline)")
    print(f"\n  errors the shipped LLM already removes: {((w_raw-w_llm)/w_raw if w_raw else 0):.0%} of raw WER")
    print(f"  residual after the LLM (the hard part a small model would have to beat): {w_llm:.1%}")

    # term recovery (c* clips) + over-fire (o* clips)
    def has_term(text):
        t = text.lower()
        return [tm for tm in terms if re.search(r"\b" + re.escape(tm.lower()) + r"\b", t)]

    c_ids = [i for i in ids if i[0] == "c"]
    o_ids = [i for i in ids if i[0] == "o"]
    # expected term for a c* clip = the slug
    def expected(i):
        slug = i.split("-")[1].lower()
        for tm in terms:
            if tm.lower().replace(" ", "").startswith(slug) or tm.lower().split()[0] == slug or slug == tm.lower():
                return tm
        return None
    rec_raw = sum(1 for i in c_ids if (e := expected(i)) and e.lower() in res[i]["hyp"].lower())
    rec_llm = sum(1 for i in c_ids if (e := expected(i)) and e.lower() in llm[i].lower())
    of_llm = sum(1 for i in o_ids if has_term(llm[i]))
    of_raw = sum(1 for i in o_ids if has_term(res[i]["hyp"]))
    nc = len(c_ids) or 1; no = len(o_ids) or 1   # guard div-by-zero on degenerate subsets
    print(f"\nTerm recovery (term-intended c* clips, n={len(c_ids)}):")
    print(f"  raw ASR had the term:   {rec_raw}/{len(c_ids)} ({rec_raw/nc:.0%})")
    print(f"  after LLM cleanup:      {rec_llm}/{len(c_ids)} ({rec_llm/nc:.0%})")
    print(f"\nOver-fire (common-intended o* clips where a term wrongly appears, n={len(o_ids)}):")
    print(f"  raw ASR:   {of_raw}/{len(o_ids)} ({of_raw/no:.0%})")
    print(f"  after LLM: {of_llm}/{len(o_ids)} ({of_llm/no:.0%})   <- the faithfulness cost a specialized model could avoid")


if __name__ == "__main__":
    main()
