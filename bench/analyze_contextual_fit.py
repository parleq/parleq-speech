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
