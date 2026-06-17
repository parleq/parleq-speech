#!/usr/bin/env python3
"""Phase 11 — phonetic-aware triggering (intent-recovery program, trunk open-Q #4).

The dictionary-proximity TRIGGER that every handler depends on (Ph6/9/10) uses
GRAPHEME proximity (difflib on spelling). That misses real near-homophones whose
spellings diverge: difflib rates Snyk↔"sync" ~0.50 (under the 0.60 gate), yet
phonetically they're identical — metaphone(Snyk)=metaphone(sync)="SNK". This
experiment asks: does PHONETIC proximity widen trigger coverage (catch the
near-homophones grapheme misses) without over-firing on ordinary speech?

Two measurements:
  (1) TRIGGER RECALL on near-term clips (c*/o*, all designed to contain a
      near-homophone of their term): fraction where the gate fires on the
      intended term, under grapheme / phonetic / combined gates.
  (2) SPURIOUS-FIRE on ordinary dictation (general corpus, NO dict terms): rate
      of words that wrongly fire the gate to some term — the precision cost.

Usage:
  bench/.venv/bin/python bench/phonetic_trigger.py --results /tmp/all.json \
    --dictionary bench/dictionary-work.json --general bench/corpus/general.json
"""
import argparse
import difflib
import json
import re

import jellyfish


def load_terms(dict_path):
    d = json.load(open(dict_path))
    out = []
    for e in d["terms"]:
        cands = [e["term"]] + [a for a in e.get("aliases", []) if a.strip()]
        out.append((e["term"], [c.lower() for c in cands]))
    return out


def gra(word, cands):
    """max grapheme (difflib) ratio of word to any candidate."""
    w = word.lower().strip(".,?!\"'")
    best = 0.0
    for c in cands:
        r = 1.0 if w == c else difflib.SequenceMatcher(a=w, b=c, autojunk=False).ratio()
        best = max(best, r)
    return best


def _mphone(s):
    # metaphone of the whole token (handles multi-word terms by stripping spaces)
    return jellyfish.metaphone(re.sub(r"[^a-z]", "", s.lower()))


def pho(word, cands):
    """max phonetic ratio: difflib on metaphone codes (1.0 if codes identical)."""
    w = word.lower().strip(".,?!\"'")
    mw = _mphone(w)
    if not mw:
        return 0.0
    best = 0.0
    for c in cands:
        mc = _mphone(c)
        if not mc:
            continue
        r = 1.0 if mw == mc else difflib.SequenceMatcher(a=mw, b=mc, autojunk=False).ratio()
        best = max(best, r)
    return best


SLUG_OVERRIDE = {"ultra": "ultrathink", "sonnet": "Sonnet Opus"}


def intended_term(cid, terms):
    """The dict term a near-term clip is built around, from the clip-id slug
    (cNN-<slug>-... / oNN-<slug>-...)."""
    parts = cid.split("-")
    if len(parts) < 2:
        return None
    slug = parts[1].lower()
    if slug in SLUG_OVERRIDE:
        slug = SLUG_OVERRIDE[slug].lower()
    for canon, cands in terms:
        nospace = canon.lower().replace(" ", "")
        if slug == canon.lower() or slug == nospace or nospace.startswith(slug) or canon.lower().split()[0] == slug:
            return canon, cands
    return None


def content_words(text):
    return [w for w in re.findall(r"[A-Za-z0-9]+", text) if len(w) > 1]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--results", required=True, help="asr-bench results json (c*/o* near-term clips)")
    ap.add_argument("--dictionary", required=True)
    ap.add_argument("--general", required=True, help="no-term corpus for spurious-fire (utterances json)")
    ap.add_argument("--gra-gate", type=float, default=0.60)
    ap.add_argument("--pho-gate", type=float, default=0.90)  # Ph11 validated operating point (0 spurious-fire)
    args = ap.parse_args()

    terms = load_terms(args.dictionary)
    rows = [r for r in json.load(open(args.results)) if not r.get("biasing")]

    # (1) trigger recall on near-term clips
    fired = {"gra": 0, "pho": 0, "both": 0}
    total = 0
    gra_miss_pho_hit = []
    for r in rows:
        it = intended_term(r["id"], terms)
        if it is None:
            continue
        canon, cands = it
        words = content_words(r.get("hyp", ""))
        if not words:
            continue
        total += 1
        gmax = max((gra(w, cands) for w in words), default=0.0)
        pmax = max((pho(w, cands) for w in words), default=0.0)
        g = gmax >= args.gra_gate
        p = pmax >= args.pho_gate
        fired["gra"] += g
        fired["pho"] += p
        fired["both"] += (g or p)
        if p and not g:
            bw = max(words, key=lambda w: pho(w, cands))
            gra_miss_pho_hit.append((r["id"], bw, canon, round(gmax, 2), round(pmax, 2)))

    print(f"=== (1) TRIGGER RECALL on {total} near-term clips (dict={args.dictionary}) ===")
    print(f"  gra-gate={args.gra_gate}  pho-gate={args.pho_gate}")
    for k, lbl in [("gra", "grapheme only"), ("pho", "phonetic only"), ("both", "grapheme OR phonetic")]:
        print(f"  {lbl:22} fires on {fired[k]:>3}/{total}  ({fired[k]/total:.0%})")
    print(f"\n  clips grapheme MISSED but phonetic CAUGHT: {len(gra_miss_pho_hit)}")
    for cid, bw, canon, gm, pm in gra_miss_pho_hit[:12]:
        # anonymize proprietary clips (c5*/o5*) in printed detail
        shown = cid if not re.match(r"^[co]5", cid) else "[proprietary clip]"
        term = canon if not re.match(r"^[co]5", cid) else "[proprietary term]"
        word = bw if not re.match(r"^[co]5", cid) else "***"
        print(f"    {shown:20} '{word}' ~ {term:12} gra={gm} pho={pm}")

    # (2) spurious-fire on ordinary dictation (no terms present)
    gen = json.load(open(args.general))
    utts = gen.get("utterances", gen if isinstance(gen, list) else [])
    n_words = 0
    spur = {"gra": 0, "pho": 0, "both": 0}
    for u in utts:
        for w in content_words(u.get("text", "")):
            n_words += 1
            gmax = max((gra(w, cands) for _, cands in terms), default=0.0)
            pmax = max((pho(w, cands) for _, cands in terms), default=0.0)
            g = gmax >= args.gra_gate
            p = pmax >= args.pho_gate
            spur["gra"] += g
            spur["pho"] += p
            spur["both"] += (g or p)
    print(f"\n=== (2) SPURIOUS-FIRE on {n_words} ordinary words (no terms present) ===")
    for k, lbl in [("gra", "grapheme only"), ("pho", "phonetic only"), ("both", "grapheme OR phonetic")]:
        rate = spur[k] / n_words if n_words else 0
        print(f"  {lbl:22} {spur[k]:>3} false fires  ({rate*1000:.1f} per 1000 words)")


if __name__ == "__main__":
    main()
