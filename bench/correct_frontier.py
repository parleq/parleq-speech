#!/usr/bin/env python3
"""Phase 19 — tune the LOCAL correction rule stack to its own frontier.

Before training any model (Ph18), find the best operating point the hand-built
rules can reach. Precompute each clip's per-word recovery features ONCE (the
expensive context embeddings), then sweep the thresholds cheaply:
  - near_gate   : dict proximity to be a recovery candidate
  - floor       : confidence below which a near-term word is class-2 (recover)
  - ctx_thresh  : context-embedding fit required for a class-3 (confident) recovery
  - ctx_all     : also require context fit for class-2 (precision mode)
Map the precision/recall frontier (term recovery vs over-fire vs WER) and pin the
best rule point against the LLM ceiling (Ph16/18: 89% recovery, 0 over-fire, 2.1% WER).
The gap that remains is what a learned corrector would have to buy.

Public clips only. Usage:
  bench/.venv/bin/python bench/correct_frontier.py --tokens /tmp/pub-tokens.jsonl \
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


def _load(mod):
    here = __file__.rsplit("/", 1)[0]
    spec = importlib.util.spec_from_file_location(mod, f"{here}/{mod}.py")
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m); return m


cf = _load("analyze_contextual_fit"); pp = cf.pp; cj = _load("compound_join")


def wer(refs, hyps):
    r = [NORM(x) for x in refs]; h = [NORM(x) for x in hyps]
    keep = [(a, b) for a, b in zip(r, h) if a.strip()]
    return jiwer.wer([a for a, _ in keep], [b for _, b in keep])


def near(word, terms):
    g, who_g = pp.proximity(word, terms)
    p, who_p = cf.phonetic_proximity(word, terms)
    return (p, who_p) if (p >= 0.90 and p > g) else (g, who_g)


def clip_features(words, terms, blurb_map):
    feats = []
    for i, w in enumerate(words):
        prox, who = near(w["word"].lower().strip(".,?!\"'"), terms)
        emb = None
        if prox >= 0.5 and who in blurb_map:
            ctx = " ".join(x["word"] for j, x in enumerate(words) if j != i)
            emb = cf.embed_cosine(ctx, cf.sanitize_blurb(blurb_map[who]))
        feats.append({"word": w["word"], "conf": w["conf_min"], "prox": prox, "who": who, "emb": emb})
    return feats


def apply_cfg(feats, compounds, near_gate, floor, ctx_thresh, ctx_all):
    out = []
    for f in feats:
        rec = None
        if f["prox"] >= near_gate and f["who"]:
            ctxok = f["emb"] is not None and f["emb"] >= ctx_thresh
            if f["conf"] < floor:                       # class-2
                rec = f["who"] if (not ctx_all or ctxok) else None
            elif ctxok:                                 # class-3
                rec = f["who"]
        out.append(rec or f["word"])
    text = " ".join(out)
    for canon, forms in compounds.items():
        for fm in sorted(forms, key=len, reverse=True):
            text = re.sub(r"\b" + r"\s+".join(re.escape(p) for p in fm.split()) + r"\b",
                          canon, text, flags=re.IGNORECASE)
    return text


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tokens", required=True); ap.add_argument("--results", required=True)
    ap.add_argument("--llm", required=True); ap.add_argument("--blurbs", required=True)
    args = ap.parse_args()

    toks = defaultdict(list)
    for line in open(args.tokens):
        line = line.strip()
        if line:
            r = json.loads(line); toks[r["id"]].append(r)
    res = {r["id"]: r for r in json.load(open(args.results)) if not r.get("biasing")}
    llm = {json.loads(l)["id"]: json.loads(l)["cleaned"] for l in open(args.llm) if l.strip()}

    terms = pp.load_terms(args.blurbs); blurb_map = cf.load_blurbs(args.blurbs)
    names = [e["term"] for e in json.load(open(args.blurbs))["terms"]]
    compounds = {t: cj.spoken_forms(t) for t in names if cj.spoken_forms(t)}

    ids = [i for i in res if i in toks and i in llm and res[i].get("ref")]
    refs = [res[i]["ref"] for i in ids]
    feats = {i: clip_features(cf.ac.group_words(toks[i]), terms, blurb_map) for i in ids}
    c_ids = [i for i in ids if i[0] == "c"]; o_ids = [i for i in ids if i[0] == "o"]

    def expected(i):
        slug = i.split("-")[1].lower()
        for tm in names:
            if tm.lower().replace(" ", "").startswith(slug) or tm.lower().split()[0] == slug or slug == tm.lower():
                return tm
        return None
    def has(t, tm): return re.search(r"\b" + re.escape(tm.lower()) + r"\b", t.lower()) is not None

    def score(texts):
        rec = sum(1 for i in c_ids if (e := expected(i)) and has(texts[i], e))
        of = sum(1 for i in o_ids if any(has(texts[i], tm) for tm in names))
        w = wer(refs, [texts[i] for i in ids])
        return rec, of, w

    # sweep
    results = []
    for near_gate in (0.6, 0.7):
        for floor in (0.90, 0.95, 0.97, 0.99, 1.0):
            for ctx_thresh in (0.0, 0.05, 0.08, 0.10, 0.12, 0.15):
                for ctx_all in (False, True):
                    texts = {i: apply_cfg(feats[i], compounds, near_gate, floor, ctx_thresh, ctx_all) for i in ids}
                    rec, of, w = score(texts)
                    results.append({"near": near_gate, "floor": floor, "ctx": ctx_thresh,
                                    "ctx_all": ctx_all, "rec": rec, "of": of, "wer": w})

    nc = len(c_ids)
    print(f"=== rule-stack frontier ({len(ids)} clips; {nc} c* / {len(o_ids)} o*; {len(results)} configs) ===")
    print(f"  baselines — raw: rec 39%/of 0/WER 6.3% | LLM: rec 89%/of 0/WER 2.1%\n")

    # Pareto front: maximize rec, minimize of (then wer)
    pf = []
    for r in sorted(results, key=lambda x: (-x["rec"], x["of"], x["wer"])):
        if not any(p["rec"] >= r["rec"] and p["of"] <= r["of"] and (p["rec"] > r["rec"] or p["of"] < r["of"]) for p in pf):
            pf.append(r)
    print("Pareto frontier (recall vs over-fire), best WER per point:")
    print("  recovery   over-fire   WER     (near/floor/ctx/ctx_all)")
    for r in sorted(pf, key=lambda x: -x["rec"]):
        print(f"   {r['rec']}/{nc} ({r['rec']/nc:.0%})    {r['of']:>2}        {r['wer']:.1%}   "
              f"({r['near']}/{r['floor']}/{r['ctx']}/{r['ctx_all']})")

    print("\nBest rule point at each over-fire budget:")
    for budget in (0, 1, 2, 3):
        cands = [r for r in results if r["of"] <= budget]
        if cands:
            b = max(cands, key=lambda x: (x["rec"], -x["wer"]))
            print(f"  over-fire <= {budget}:  recovery {b['rec']}/{nc} ({b['rec']/nc:.0%})  WER {b['wer']:.1%}  "
                  f"(near {b['near']}, floor {b['floor']}, ctx {b['ctx']}, ctx_all {b['ctx_all']})")
    best_wer = min(results, key=lambda x: x["wer"])
    print(f"\nBest WER overall: {best_wer['wer']:.1%}  (recovery {best_wer['rec']/nc:.0%}, over-fire {best_wer['of']}, "
          f"near {best_wer['near']}/floor {best_wer['floor']}/ctx {best_wer['ctx']}/ctx_all {best_wer['ctx_all']})")


if __name__ == "__main__":
    main()
