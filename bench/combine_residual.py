#!/usr/bin/env python3
"""Phase 10 — combine the two LOCAL class-3 signals and measure the residual the
cloud/Gemma LLM must still handle (intent-recovery program, follows Ph8 usage-prior
+ Ph9 contextual-fit).

Class 3 = confident near-homophone (Snyk->"sneak"): acoustics useless, so the only
local evidence is (a) the personal USAGE-PRIOR — does this user say the term more
than the colliding common word? (Ph8; we have no deployment data, so it's a swept
PARAMETER lambda) and (b) CONTEXTUAL-FIT — does the sentence match the term's blurb?
(Ph9; measured embed-cosine).

We fuse them as additive log-odds (the trunk's evidence-combination model:
P(intent|evidence) ∝ product of likelihoods => log-odds add), with an abstention
band => escalate-to-LLM. We also run OR-gate / cascade / single-signal baselines so
we can SEE what each rule and each signal actually buys.

"Residual the LLM must handle" has two parts at any operating point:
  - ESCALATIONS: clips in the abstain band (we punt to the LLM).
  - SLIPS:       clips we decided locally but got WRONG (escape the LLM => bad).
The goal: low escalation AND zero slips. Two summaries per (model, lambda):
  - forced balanced accuracy (band=0, always decide) — raw discriminative power.
  - min escalation for 0 slips — how much must we punt to make no local mistake.

Reuses analyze_contextual_fit.py for per-clip rows (term, target word, conf, embed).

Usage:
  bench/.venv/bin/python bench/combine_residual.py --tokens /tmp/pub-tokens.jsonl \
    --results /tmp/pub.json --blurbs bench/dictionary-work.json [--conf-threshold 0.97] [--all-near-term]
"""
import argparse
import importlib.util
import json
from collections import defaultdict

from wordfreq import zipf_frequency


def _load(mod):
    here = __file__.rsplit("/", 1)[0]
    spec = importlib.util.spec_from_file_location(mod, f"{here}/{mod}.py")
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


cf = _load("analyze_contextual_fit")

# contextfit-cosine -> log-odds calibration (Ph9: term emb mean ~0.20, common ~0.03)
CTX_MID = 0.11      # midpoint between the two class means
CTX_SCALE = 0.10    # term (~0.21) -> +1.0, common (~0.01) -> -1.0


def build_rows(tokens_path, results_path, blurbs_path):
    """One row per scorable clip: cid, label (term/common), term, target word,
    conf (acoustic), emb (contextfit cosine), zipf(target)."""
    toks = defaultdict(list)
    for line in open(tokens_path):
        line = line.strip()
        if line:
            r = json.loads(line)
            toks[r["id"]].append(r)
    refs = {r["id"]: r for r in json.load(open(results_path)) if not r.get("biasing")}
    blurb_map = cf.load_blurbs(blurbs_path)
    terms = cf.pp.load_terms(blurbs_path)
    rows = []
    for cid, tlist in toks.items():
        if not refs.get(cid, {}).get("ref", ""):
            continue
        words = cf.ac.group_words(tlist)
        r = cf.score_clip(words, blurb_map, terms, use_embed=True)
        if r is None:
            continue
        label = cf.label_for(cid)
        if label not in ("term", "common"):
            continue
        tw = r["target"].lower().strip(".,?!\"'")
        rows.append({"cid": cid, "label": label, "term": r["term"], "target": tw,
                     "conf": r["conf"], "emb": r["emb"], "zipf": zipf_frequency(tw, "en")})
    return rows


# ---- evidence terms (log-odds; positive => favors the TERM) --------------
def usage_logodds(row, lam, freq_aware):
    """Personal usage-prior. lambda = how many log-units this user favors their
    dict terms over the colliding common word. freq_aware subtracts the common
    word's global frequency (rarer common word => easier to override)."""
    return lam - (row["zipf"] - 5.0) * (1.0 if freq_aware else 0.0)


def ctx_logodds(row):
    return (row["emb"] - CTX_MID) / CTX_SCALE


# ---- decision models: return "term" | "common" | "abstain" --------------
def decide_additive(row, lam, band, alpha=1.0, beta=1.0, freq_aware=True):
    s = alpha * usage_logodds(row, lam, freq_aware) + beta * ctx_logodds(row)
    return "term" if s > band else "common" if s < -band else "abstain"


def decide_usage_only(row, lam, band, freq_aware=True):
    s = usage_logodds(row, lam, freq_aware)
    return "term" if s > band else "common" if s < -band else "abstain"


def decide_ctx_only(row, band):
    s = ctx_logodds(row)
    return "term" if s > band else "common" if s < -band else "abstain"


def decide_or_gate(row, lam, ut=0.0, ct=0.0, freq_aware=True):
    """Recover the term if EITHER signal says term (no abstention)."""
    fire = usage_logodds(row, lam, freq_aware) > ut or ctx_logodds(row) > ct
    return "term" if fire else "common"


def decide_cascade(row, lam, u_band=1.0, c_band=0.0, freq_aware=True):
    """Usage decides when confident; else context breaks the tie (no abstain)."""
    u = usage_logodds(row, lam, freq_aware)
    if abs(u) >= u_band:
        return "term" if u > 0 else "common"
    return "term" if ctx_logodds(row) > c_band else "common"


# ---- metrics ------------------------------------------------------------
def balanced_acc(rows, decide):
    """Forced decision (no abstain expected): mean of term-recall and
    common-specificity, so class imbalance doesn't flatter a majority guesser."""
    t = [r for r in rows if r["label"] == "term"]
    c = [r for r in rows if r["label"] == "common"]
    tr = sum(decide(r) == "term" for r in t) / len(t) if t else float("nan")
    cs = sum(decide(r) == "common" for r in c) / len(c) if c else float("nan")
    return (tr + cs) / 2, tr, cs


def min_escalation_for_zero_slips(rows, decide_band):
    """Sweep the abstain band upward; report the smallest escalation fraction at
    which NO decided clip is wrong (a slip). decide_band(row, band)->decision."""
    best = None
    for band in [x / 20 for x in range(0, 81)]:   # 0.0 .. 4.0
        decided = [(r, decide_band(r, band)) for r in rows]
        slips = sum(1 for r, d in decided if d != "abstain" and d != r["label"])
        if slips == 0:
            esc = sum(1 for _, d in decided if d == "abstain") / len(rows)
            best = (band, esc)
            break
    return best   # (band, escalation_fraction) or None if never slip-free


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tokens", required=True)
    ap.add_argument("--results", required=True)
    ap.add_argument("--blurbs", required=True)
    ap.add_argument("--conf-threshold", type=float, default=0.97)
    ap.add_argument("--all-near-term", action="store_true",
                    help="use ALL near-term clips, not just the confident class-3 slice")
    ap.add_argument("--no-freq-aware", action="store_true",
                    help="flat usage prior (do not subtract the common word's frequency)")
    args = ap.parse_args()
    fa = not args.no_freq_aware

    rows = build_rows(args.tokens, args.results, args.blurbs)
    if not args.all_near_term:
        rows = [r for r in rows if r["conf"] >= args.conf_threshold]
    t = sum(r["label"] == "term" for r in rows)
    c = sum(r["label"] == "common" for r in rows)
    scope = "ALL near-term clips" if args.all_near_term else f"confident slice (conf>={args.conf_threshold})"
    print(f"=== {scope}: {len(rows)} clips ({t} term / {c} common) — blurbs={args.blurbs}, "
          f"freq_aware={fa} ===")
    if t == 0 or c == 0:
        print("  (need both classes present to score — skipping)")
        return

    lams = [-1.0, 0.0, 1.0, 2.0, 3.0]

    print("\n[1] FORCED balanced accuracy (band=0; term-recall / common-specificity):")
    bc, btr, bcs = balanced_acc(rows, lambda r: decide_ctx_only(r, 0.0))
    print(f"  context-only            bal={bc:.2f}  (recall {btr:.2f} / spec {bcs:.2f})")
    for lam in lams:
        bu = balanced_acc(rows, lambda r, l=lam: decide_usage_only(r, l, 0.0, fa))
        bd = balanced_acc(rows, lambda r, l=lam: decide_additive(r, l, 0.0, freq_aware=fa))
        bo = balanced_acc(rows, lambda r, l=lam: decide_or_gate(r, l, freq_aware=fa))
        bca = balanced_acc(rows, lambda r, l=lam: decide_cascade(r, l, freq_aware=fa))
        print(f"  λ={lam:+.0f}  usage-only {bu[0]:.2f} | additive {bd[0]:.2f} | "
              f"OR-gate {bo[0]:.2f} | cascade {bca[0]:.2f}")

    print("\n[2] MIN escalation for ZERO local slips (lower = better; '—' = never slip-free):")
    def fmt(x):
        return "—" if x is None else f"esc={x[1]:.0%} @band={x[0]:.2f}"
    co = min_escalation_for_zero_slips(rows, lambda r, b: decide_ctx_only(r, b))
    print(f"  context-only            {fmt(co)}")
    for lam in lams:
        uo = min_escalation_for_zero_slips(rows, lambda r, b, l=lam: decide_usage_only(r, l, b, fa))
        ad = min_escalation_for_zero_slips(rows, lambda r, b, l=lam: decide_additive(r, l, b, freq_aware=fa))
        print(f"  λ={lam:+.0f}  usage-only {fmt(uo):<22} | additive {fmt(ad)}")


if __name__ == "__main__":
    main()
