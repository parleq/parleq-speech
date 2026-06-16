#!/usr/bin/env python3
"""Phase 12 — the trust metric / uncertainty surface (intent-recovery #2).

The program's most product-differentiating thesis: instead of WER ("how wrong is
the transcript"), measure PROOFREADING EFFORT vs SAFETY. The engine flags the
words it's unsure of; the user re-reads only those. Because acoustic confidence
is calibrated (Ph5, AUC ~0.80 real), flagging low-confidence words should catch
most errors while flagging few words.

For each word (aligned hyp->ref): conf_min + is_error (sub/ins). Flag words with
conf < T. Then:
  EFFORT  = flagged / all words            (fraction the user must double-check)
  CAUGHT  = flagged errors / all errors    (recall of errors — safety)
  SLIPS   = errors NOT flagged             (pasted unknowingly — the bad outcome)
Sweep T to get the trust curve. Compare to the random-flag baseline (effort==caught
on the diagonal): the lift is the value of calibrated confidence.

Usage:
  bench/.venv/bin/python bench/trust_metric.py --tokens /tmp/trust-tokens.jsonl \
    --results /tmp/trust.json
"""
import argparse
import importlib.util
import json
from collections import defaultdict


def _load(mod):
    here = __file__.rsplit("/", 1)[0]
    spec = importlib.util.spec_from_file_location(mod, f"{here}/{mod}.py")
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


ac = _load("analyze_confidence")   # group_words, align


def collect(tokens_path, results_path):
    """One (conf, is_error) per aligned hyp word across all clips."""
    toks = defaultdict(list)
    for line in open(tokens_path):
        line = line.strip()
        if line:
            r = json.loads(line)
            toks[r["id"]].append(r)
    refs = {r["id"]: r for r in json.load(open(results_path)) if not r.get("biasing")}
    words = []
    for cid, tlist in toks.items():
        ref = refs.get(cid, {}).get("ref", "")
        if not ref:
            continue
        for op, w in ac.align(ac.group_words(tlist), ref.split()):
            words.append((w["conf_min"], op != "match"))
    return words


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tokens", required=True)
    ap.add_argument("--results", required=True)
    args = ap.parse_args()

    words = collect(args.tokens, args.results)
    n = len(words)
    n_err = sum(1 for _, e in words if e)
    if not n or not n_err:
        print("no words / no errors to score"); return
    print(f"=== trust metric: {n} words, {n_err} errors ({n_err/n:.1%} word error rate) ===\n")

    def at_threshold(T):
        flagged = [(c, e) for c, e in words if c < T]
        caught = sum(1 for _, e in flagged if e)
        return len(flagged) / n, (caught / n_err if n_err else 0), (n_err - caught)

    print("[1] Trust curve — flag words with confidence < T:")
    print("   T       effort(re-read)   errors-caught   slips(missed)")
    for T in [0.50, 0.80, 0.90, 0.95, 0.97, 0.99, 0.995, 0.999]:
        eff, caught, slips = at_threshold(T)
        print(f"  {T:.3f}     {eff:>5.0%}            {caught:>5.0%}          {slips:>3d}")

    # headline operating points: effort needed to catch X% of errors
    print("\n[2] Effort to reach a safety target (sweep T finely):")
    Ts = [i / 1000 for i in range(0, 1001)]
    for target in [0.50, 0.80, 0.90, 0.95, 1.00]:
        best = None
        for T in Ts:
            eff, caught, _ = at_threshold(T)
            if caught >= target:
                best = (eff, T)
                break
        if best:
            print(f"  catch {target:>4.0%} of errors  ->  re-read {best[0]:>4.0%} of words  (T<{best[1]:.3f})")
        else:
            print(f"  catch {target:>4.0%} of errors  ->  not reachable")

    # value of calibration vs random flagging (diagonal): at fixed effort budgets
    print("\n[3] Calibration lift — errors caught at a fixed re-read budget (vs random=diagonal):")
    confs = sorted(c for c, _ in words)
    for budget in [0.05, 0.10, 0.15, 0.20]:
        k = max(1, int(budget * n))
        T = confs[k - 1]
        flagged = [(c, e) for c, e in words if c <= T][:k]
        caught = sum(1 for _, e in flagged if e) / n_err
        print(f"  re-read {budget:>4.0%}  ->  catch {caught:>4.0%} of errors   (random would catch ~{budget:.0%}; "
              f"lift {caught/budget:.1f}x)")


if __name__ == "__main__":
    main()
