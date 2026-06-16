#!/usr/bin/env python3
"""Phase 9 contextual-fit probe (intent-recovery / issue #100).

Does sentence<->term-blurb similarity separate term-intended (c* clips) from
common-word-intended (o* clips) speech, especially in the confident slice that
acoustic confidence cannot flag (error class 3)? Two scorers: a free keyword-
overlap baseline and a tiny sentence embedder (proxy for on-device
NLContextualEmbedding). Reuses analyze_confidence.py (group_words/align) and
analyze_personal_prior.py (dictionary proximity).

Usage:
  bench/.venv/bin/python bench/analyze_contextual_fit.py \
    --tokens /tmp/human-tokens.jsonl --results /tmp/human.json \
    --blurbs bench/blurbs-overfire.json [--conf-threshold 0.97] [--no-embed]
"""
import argparse
import difflib
import importlib.util
import json
import re
import sys
from collections import defaultdict


def _load(mod):
    here = __file__.rsplit("/", 1)[0]
    spec = importlib.util.spec_from_file_location(mod, f"{here}/{mod}.py")
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


ac = _load("analyze_confidence")        # group_words, align, auc
pp = _load("analyze_personal_prior")    # proximity, load_terms

# ---- blurb sanitization -------------------------------------------------
_SELF = re.compile(r"\b(i|me|my|we|our|us)\b", re.I)
_CONFUSE = re.compile(r"confused with", re.I)


def sanitize_blurb(text):
    """Strip meta-commentary that must not enter the score: parentheticals,
    self-reference clauses ('used a lot by me'), and — critically — 'confused
    with "X"' notes that literally contain the common word and would spuriously
    match the negative clips. Keep the definitional clauses."""
    text = re.sub(r"\([^)]*\)", " ", text)              # drop parentheticals
    kept = []
    for clause in re.split(r"[.,;]", text):
        c = clause.strip()
        if not c or _CONFUSE.search(c) or _SELF.search(c):
            continue
        kept.append(c)
    out = " ".join(kept).strip()
    if not out:                                          # fallback: first clause, sans confusion note
        first = re.split(r"[.,;]", text)[0]
        out = _CONFUSE.split(first)[0].strip()
    return re.sub(r"\s+", " ", out)


# ---- keyword overlap (zero-model baseline) ------------------------------
from wordfreq import zipf_frequency

_STOP = set("a an the of to in on for and or with is are be been was were this that "
            "it its as at by from your you our we i me my they them he she his her "
            "do does did not no yes so but if then than into out up down over under".split())


def content_words(text):
    return [w for w in re.findall(r"[a-z0-9]+", text.lower())
            if w not in _STOP and len(w) > 1]


def _rarity(w):
    # zipf: ~7=very common, <3=rare; unknown -> 0. Rarer shared words weigh more.
    return max(0.0, 8.0 - zipf_frequency(w, "en"))


def keyword_overlap(context, blurb):
    """Rarity-weighted fraction of the blurb's content words present in the
    context. 0..1; rare shared words (proper nouns, jargon) count for more."""
    cw, bw = set(content_words(context)), set(content_words(blurb))
    if not bw:
        return 0.0
    num = sum(_rarity(w) for w in (cw & bw))
    den = sum(_rarity(w) for w in bw)
    return num / den if den else 0.0


# ---- tiny sentence embedder (proxy for on-device NLContextualEmbedding) -
_MODEL = None


def _embedder():
    global _MODEL
    if _MODEL is None:
        from sentence_transformers import SentenceTransformer
        _MODEL = SentenceTransformer("all-MiniLM-L6-v2")
    return _MODEL


def embed_cosine(a, b):
    import numpy as np
    va, vb = _embedder().encode([a, b], normalize_embeddings=True)
    return float(np.dot(va, vb))


# ---- labels + separation AUC --------------------------------------------
def label_for(clip_id):
    """c* = term-intended (positive), o* = common-intended (negative),
    s* = stress (positive, argmax-control only)."""
    p = clip_id[0].lower()
    return {"c": "term", "o": "common", "s": "stress"}.get(p, "other")


def auc_high(pos, neg):
    """P(positive_score > negative_score). HIGH score should mean term-intended,
    so this is the separation AUC (0.5 = useless, 1.0 = perfect)."""
    if not pos or not neg:
        return float("nan")
    wins = ties = 0
    for p in pos:
        for n in neg:
            if p > n:
                wins += 1
            elif p == n:
                ties += 1
    return (wins + 0.5 * ties) / (len(pos) * len(neg))


# ---- phonetic proximity (Phase 11): catches divergent-spelling homophones
# (Snyk<->"sync") that grapheme misses; near-exact match only, so it's a free
# OR-clause with ~0 added spurious fire. Default OFF (preserves Ph9/10 behavior).
def _metaphone(s):
    import jellyfish
    return jellyfish.metaphone(re.sub(r"[^a-z]", "", s.lower()))


def phonetic_proximity(word, terms):
    """max Metaphone-code ratio of word to any term/alias; (score, canon)."""
    mw = _metaphone(word.lower().strip(".,?!\"'"))
    if not mw:
        return 0.0, None
    best, who = 0.0, None
    for canon, cands in terms:
        for c in cands:
            mc = _metaphone(c)
            if not mc:
                continue
            r = 1.0 if mw == mc else difflib.SequenceMatcher(a=mw, b=mc, autojunk=False).ratio()
            if r > best:
                best, who = r, canon
    return best, who


# ---- per-clip scoring ----------------------------------------------------
def target_word(words, terms, near=0.6, phonetic=False, pho_gate=0.90):
    """The hyp word closest to any dictionary term (the ambiguous word).
    With phonetic=True, a near-exact Metaphone match (>=pho_gate) also qualifies
    (Phase 11). Returns (word_dict, prox, canon_term) or (None, 0, None)."""
    best = (None, 0.0, None)
    for w in words:
        prox, who = pp.proximity(w["word"], terms)
        if phonetic:
            pprox, pwho = phonetic_proximity(w["word"], terms)
            if pprox >= pho_gate and pprox > prox:
                prox, who = pprox, pwho
        if prox > best[1]:
            best = (w, prox, who)
    return best if best[1] >= near else (None, 0.0, None)


def score_clip(words, blurb_map, terms, use_embed, phonetic=False):
    """Pick the ambiguous word, build context = all OTHER words, score the
    context against that term's sanitized blurb. Returns a row or None."""
    tgt, prox, who = target_word(words, terms, phonetic=phonetic)
    if tgt is None or who not in blurb_map:
        return None
    context = " ".join(w["word"] for w in words if w is not tgt)
    blurb = sanitize_blurb(blurb_map[who])
    row = {"term": who, "target": tgt["word"], "conf": tgt["conf_min"],
           "kw": keyword_overlap(context, blurb)}
    if use_embed:
        row["emb"] = embed_cosine(context, blurb)
    return row


def load_blurbs(path):
    """Dictionary-shaped {'terms':[{'term','context'}]} -> {term: blurb}."""
    d = json.load(open(path))
    return {e["term"]: e.get("context", "") for e in d["terms"] if e.get("context", "").strip()}


def _print_auc(rows, key, label):
    pos = [r[key] for r in rows if r["label"] == "term"]
    neg = [r[key] for r in rows if r["label"] == "common"]
    print(f"  {label:<10} AUC={auc_high(pos, neg):.3f}   "
          f"(term n={len(pos)} mean={_mean(pos):.3f} | common n={len(neg)} mean={_mean(neg):.3f})")


def _mean(xs):
    return sum(xs) / len(xs) if xs else float("nan")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tokens", required=True)
    ap.add_argument("--results", required=True)
    ap.add_argument("--blurbs", required=True)
    ap.add_argument("--conf-threshold", type=float, default=0.97)
    ap.add_argument("--no-embed", action="store_true")
    ap.add_argument("--phonetic", action="store_true",
                    help="add near-exact phonetic match to the dictionary trigger (Phase 11)")
    args = ap.parse_args()
    use_embed = not args.no_embed

    toks = defaultdict(list)
    for line in open(args.tokens):
        line = line.strip()
        if line:
            r = json.loads(line)
            toks[r["id"]].append(r)
    refs = {r["id"]: r for r in json.load(open(args.results)) if not r.get("biasing")}
    blurb_map = load_blurbs(args.blurbs)
    terms = pp.load_terms(args.blurbs)

    rows = []
    for cid, tlist in toks.items():
        ref = refs.get(cid, {}).get("ref", "")
        if not ref:
            continue
        words = ac.group_words(tlist)
        r = score_clip(words, blurb_map, terms, use_embed, phonetic=args.phonetic)
        if r is None:
            continue
        r["cid"] = cid
        r["label"] = label_for(cid)
        rows.append(r)

    keys = ["kw"] + (["emb"] if use_embed else [])
    sep = [r for r in rows if r["label"] in ("term", "common")]
    print(f"=== separation (all {len(sep)} c/o clips) — blurbs={args.blurbs} ===")
    for k in keys:
        _print_auc(sep, k, "keyword" if k == "kw" else "embed")

    hi = [r for r in sep if r["conf"] >= args.conf_threshold]
    print(f"\n=== conditioned: confident slice (conf>={args.conf_threshold}, "
          f"{len(hi)} clips) — the class-3 residual acoustics can't flag ===")
    for k in keys:
        _print_auc(hi, k, "keyword" if k == "kw" else "embed")

    # argmax / discrimination control: does a term/stress-intended utterance
    # match its OWN term's blurb best among all blurbs in this set?
    print("\n=== argmax control: correct blurb ranked #1 among all blurbs ===")
    _argmax_control(toks, refs, blurb_map, terms, use_embed, phonetic=args.phonetic)


def _argmax_control(toks, refs, blurb_map, terms, use_embed, phonetic=False):
    """For each term/stress clip: the ambiguous word fixes the ground-truth term
    (via grapheme proximity, same as score_clip). Excluding that word, does the
    surrounding context rank the correct term's blurb #1 among all blurbs?
    Excluding the target word matters — otherwise the term word itself leaks into
    the context and inflates the control (must mirror score_clip)."""
    score = embed_cosine if use_embed else keyword_overlap
    hits = total = 0
    for cid, tlist in toks.items():
        if label_for(cid) not in ("term", "stress"):
            continue
        if not refs.get(cid, {}).get("ref", ""):
            continue
        words = ac.group_words(tlist)
        tgt, prox, who = target_word(words, terms, phonetic=phonetic)
        if tgt is None or who not in blurb_map:
            continue
        context = " ".join(w["word"] for w in words if w is not tgt)
        ranked = sorted(blurb_map, key=lambda t: score(context, sanitize_blurb(blurb_map[t])), reverse=True)
        total += 1
        hits += int(ranked[0] == who)
    if total:
        print(f"  top-1 accuracy: {hits}/{total} ({hits/total:.0%})  (chance ~ 1/{len(blurb_map)})")
    else:
        print("  (no scorable term/stress clips for this blurb set)")


if __name__ == "__main__":
    main()
