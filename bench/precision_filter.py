#!/usr/bin/env python3
"""precision_filter.py — rule-stack precision post-filter for the learned
ASR-correction model (intent-recovery program, featherweight-corrector spike A.6).

The learned corrector supplies RECALL (it proposes dictionary recoveries the
rule stack misses) but over-fires: it edits non-dictionary words into dictionary
terms (the spike's observed `reddish->redis`, `Cates->CRAN`). This filter supplies
PRECISION: it diffs raw vs the model's output, and for every span where the model
INTRODUCED a dictionary term it vetoes the edit unless the edit is dictionary-
grounded AND supported. Non-dict edits (ordinary ASR fixes like `cash->cache`)
pass through untouched — policing dict-term insertions is the filter's only job.

Accept a model edit (keep the model's span) iff:

    grounded AND (class2 OR class3 OR strong_phonetic)

  grounded         the raw word being replaced is near the inserted term —
                   grapheme proximity >= near_gate OR phonetic >= pho_gate
                   (reuses analyze_personal_prior.proximity + phonetic_proximity).
  class2           token confidence available AND the raw word's confidence is
                   below conf_floor (acoustically uncertain region). Skipped when
                   token_conf is None (the text-only eval path).
  class3           the term's blurb fits the surrounding context:
                   embed_cosine(context, blurb) >= ctx_thresh (the class-3 signal
                   acoustic confidence can't flag — analyze_contextual_fit).
  strong_phonetic  the raw word is a near-exact homophone of the term
                   (phonetic >= pho_gate). A near-exact phonetic match is its own
                   evidence (Ph11: ~0 spurious fire) and carries the edit even
                   without token confidence — this is what keeps `sneak->Snyk`
                   while `reddish->redis` (phonetic 0.67, grapheme-only) is vetoed.

Otherwise the span reverts to the raw words.

Defaults: Ph19 tuned operating point (near_gate 0.7, pho_gate 0.90, ctx_thresh 0.08).

Self-test (the spike's named over-fires + a legitimate recovery):
    bench/.venv/bin/python bench/precision_filter.py --selftest
"""

import argparse
import difflib
import importlib.util
import json
import re
from pathlib import Path

_HERE = Path(__file__).resolve().parent


def _load(mod):
    spec = importlib.util.spec_from_file_location(mod, str(_HERE / f"{mod}.py"))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


# Lazy-loaded rule-stack modules (importing pulls in sentence-transformers etc.).
_CF = None
_PP = None


def _modules():
    global _CF, _PP
    if _CF is None:
        _CF = _load("analyze_contextual_fit")
        _PP = _CF.pp  # analyze_personal_prior, already imported by analyze_contextual_fit
    return _CF, _PP


_WORD = re.compile(r"\S+")


def _tokens(text):
    return _WORD.findall(text or "")


def _norm(tok):
    return tok.lower().strip(".,?!\"':;()[]")


def _term_near(word, terms, near_gate, pho_gate):
    """(grapheme, phonetic, who, who_pho) proximity of `word` to the dict terms."""
    cf, pp = _modules()
    g, who_g = pp.proximity(word, terms)
    p, who_p = cf.phonetic_proximity(word, terms)
    return g, p, who_g, who_p


def _has_term(text, canon, cands):
    """Does `text` contain the canonical term or an alias (whole-word, ci)?"""
    for c in [canon] + list(cands):
        pat = r"\b" + r"\s+".join(re.escape(w) for w in c.split()) + r"\b"
        if re.search(pat, text, flags=re.IGNORECASE):
            return True
    return False


def _load_dictionary(dictionary):
    """Accept a path (str/Path) to a blurbs/dict JSON, or a pre-parsed
    {'terms': [...]} dict. Returns (terms, blurb_map) where terms is
    [(canon, [cands_lower])] and blurb_map is {canon: blurb}."""
    cf, pp = _modules()
    if isinstance(dictionary, (str, Path)):
        terms = pp.load_terms(str(dictionary))
        blurb_map = cf.load_blurbs(str(dictionary))
        return terms, blurb_map
    # pre-parsed dict
    import os
    import tempfile
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
        json.dump(dictionary, f)
        tmp = f.name
    try:
        terms = pp.load_terms(tmp)
        blurb_map = cf.load_blurbs(tmp)
    finally:
        os.unlink(tmp)
    return terms, blurb_map


def filter_edits(raw, model_out, dictionary, token_conf=None,
                 near_gate=0.7, pho_gate=0.90, ctx_thresh=0.08, conf_floor=0.97):
    """Veto non-dictionary-grounded model edits. See module docstring.

    raw         the raw ASR transcript (model input).
    model_out   the learned model's correction.
    dictionary  path to a blurbs/dict JSON, or a {'terms':[...]} dict.
    token_conf  optional {normalized_word: confidence} for class-2; None disables it.

    Returns the filtered text: model spans that survive the gate, raw spans
    where the gate vetoed a dict-term insertion.
    """
    cf, pp = _modules()
    terms, blurb_map = _load_dictionary(dictionary)

    raw_toks = _tokens(raw)
    out_toks = _tokens(model_out)
    raw_l = [_norm(t) for t in raw_toks]
    out_l = [_norm(t) for t in out_toks]

    sm = difflib.SequenceMatcher(None, raw_l, out_l, autojunk=False)
    result = []
    for tag, i1, i2, j1, j2 in sm.get_opcodes():
        if tag == "equal":
            result.extend(out_toks[j1:j2])
            continue

        raw_span = raw_toks[i1:i2]
        model_span = out_toks[j1:j2]

        # Which dict terms did the model span INTRODUCE that the raw span lacked?
        raw_text = " ".join(raw_span)
        model_text = " ".join(model_span)
        introduced = [
            (canon, cands) for (canon, cands) in terms
            if _has_term(model_text, canon, cands) and not _has_term(raw_text, canon, cands)
        ]

        if not introduced:
            # Not a dictionary-term insertion — an ordinary edit. Trust the model.
            result.extend(model_span)
            continue

        # Context = all OTHER raw words (mirrors analyze_contextual_fit.score_clip).
        context = " ".join(
            raw_toks[k] for k in range(len(raw_toks)) if not (i1 <= k < i2)
        )

        keep = False
        for canon, cands in introduced:
            # Best raw word in (or adjacent to) the span to ground this term on.
            anchor_words = raw_span or (
                ([raw_toks[i1 - 1]] if i1 > 0 else []) +
                ([raw_toks[i2]] if i2 < len(raw_toks) else [])
            )
            best_g = best_p = 0.0
            best_anchor = None
            for w in anchor_words:
                wn = _norm(w)
                g, p, _, _ = _term_near(wn, [(canon, cands)], near_gate, pho_gate)
                if g > best_g:
                    best_g, best_anchor = g, wn
                if p > best_p:
                    best_p = p

            grounded = (best_g >= near_gate) or (best_p >= pho_gate)
            if not grounded:
                continue

            strong_phonetic = best_p >= pho_gate

            class2 = False
            if token_conf is not None and best_anchor is not None:
                conf = token_conf.get(best_anchor)
                class2 = conf is not None and conf < conf_floor

            class3 = False
            if canon in blurb_map and context.strip():
                fit = cf.embed_cosine(context, cf.sanitize_blurb(blurb_map[canon]))
                class3 = fit >= ctx_thresh

            if grounded and (class2 or class3 or strong_phonetic):
                keep = True
                break

        result.extend(model_span if keep else raw_span)

    return " ".join(result)


# ── self-test ────────────────────────────────────────────────────────────────
def _selftest():
    dict_path = str(_HERE / "blurbs-overfire.json")
    cases = [
        # (name, raw, model_out, expect_term_in_output, term)
        ("over-fire reddish->redis (revert)",
         "The sky turned a reddish orange at sunset.",
         "The sky turned a redis orange at sunset.",
         False, "Redis"),
        ("over-fire Cates->CRAN (revert)",
         "We met Cates by the river on Tuesday.",
         "We met CRAN by the river on Tuesday.",
         False, "CRAN"),
        ("legit sneak->Snyk (keep)",
         "We bumped the library version after sneak reported the advisory.",
         "We bumped the library version after Snyk reported the advisory.",
         True, "Snyk"),
    ]
    cf, pp = _modules()
    terms = pp.load_terms(dict_path)
    ok = True
    for name, raw, model_out, expect, term in cases:
        out = filter_edits(raw, model_out, dict_path)
        cands = dict(terms).get(term, [term.lower()])
        present = _has_term(out, term, cands)
        status = "PASS" if present == expect else "FAIL"
        if present != expect:
            ok = False
        # show the proximity evidence for transparency
        rawword = {"Redis": "reddish", "CRAN": "Cates", "Snyk": "sneak"}[term]
        g, p, _, _ = _term_near(rawword, [(term, cands)], 0.7, 0.90)
        print(f"  [{status}] {name}")
        print(f"          grounding {rawword!r}~{term}: gra={g:.2f} pho={p:.2f}")
        print(f"          -> {out}")
    print("\nSELFTEST:", "PASS" if ok else "FAIL")
    assert ok, "precision_filter self-test failed"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--raw")
    ap.add_argument("--model-out")
    ap.add_argument("--dictionary", default=str(_HERE / "blurbs-overfire.json"))
    args = ap.parse_args()

    if args.selftest:
        _selftest()
        return
    if args.raw and args.model_out:
        print(filter_edits(args.raw, args.model_out, args.dictionary))
        return
    ap.error("provide --selftest, or --raw and --model-out")


if __name__ == "__main__":
    main()
