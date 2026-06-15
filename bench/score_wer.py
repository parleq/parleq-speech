#!/usr/bin/env python3
"""Score asr-bench results: WER + latency, grouped by path and biasing.

Self-contained reimplementation of the prior-art WER methodology (Whisper English
text normalizer for inverse-text-normalization, then jiwer for WER) so the
benchmark has no dependency on the private voice-permeable-interfaces repo.

Input: a results.json produced by `asr-bench`, an array of rows:
    { "id", "path", "ref", "hyp", "latency_ms", "post_release_ms",
      "first_partial_ms", "biasing" }
`ref`/`hyp` are required; the latency fields are optional per row.

Usage:
    python3 bench/score_wer.py bench/results/<file>.json
    python3 bench/score_wer.py <results.json> --summary-out <summary.json>

Deps: jiwer, whisper-normalizer. Install into a venv:
    python3 -m venv bench/.venv && bench/.venv/bin/pip install jiwer whisper-normalizer
    bench/.venv/bin/python bench/score_wer.py ...
"""
import argparse
import json
import statistics
import sys
from collections import defaultdict

try:
    import jiwer
    from whisper_normalizer.english import EnglishTextNormalizer
except ImportError:
    sys.exit(
        "Missing deps. Run:\n"
        "  python3 -m venv bench/.venv && "
        "bench/.venv/bin/pip install jiwer whisper-normalizer\n"
        "  bench/.venv/bin/python bench/score_wer.py <results.json>"
    )

NORM = EnglishTextNormalizer()


def wer_of(ref, hyp):
    r, h = NORM(ref or ""), NORM(hyp or "")
    if not r:
        return 0.0 if not h else 1.0
    return jiwer.wer(r, h)


def pct(xs, p):
    if not xs:
        return None
    xs = sorted(xs)
    k = (len(xs) - 1) * (p / 100.0)
    lo, hi = int(k), min(int(k) + 1, len(xs) - 1)
    return xs[lo] + (xs[hi] - xs[lo]) * (k - lo)


def fmt(x, suffix="", nd=1):
    return "-" if x is None else f"{x:.{nd}f}{suffix}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("results")
    ap.add_argument("--summary-out", default=None)
    args = ap.parse_args()

    with open(args.results) as f:
        rows = json.load(f)
    if isinstance(rows, dict) and "rows" in rows:
        rows = rows["rows"]

    # Group by (path, biasing).
    groups = defaultdict(list)
    for row in rows:
        key = (row.get("path", "?"), bool(row.get("biasing", False)))
        row["_wer"] = wer_of(row.get("ref"), row.get("hyp"))
        groups[key].append(row)

    summary = []
    print(f"\n{'path':<12} {'bias':<5} {'n':>4} {'meanWER':>8} {'medWER':>7} "
          f"{'perfect':>8} {'lat.p50':>8} {'lat.p95':>8} {'1stPart':>8}")
    print("-" * 80)
    for key in sorted(groups):
        path, bias = key
        g = groups[key]
        wers = [r["_wer"] for r in g]
        # Latency: post_release_ms if present (streaming), else latency_ms (batch).
        lat = [r.get("post_release_ms") if r.get("post_release_ms") is not None
               else r.get("latency_ms") for r in g]
        lat = [x for x in lat if x is not None]
        fp = [r["first_partial_ms"] for r in g if r.get("first_partial_ms") is not None]
        rec = {
            "path": path,
            "biasing": bias,
            "n": len(g),
            "mean_wer_pct": round(statistics.mean(wers) * 100, 2),
            "median_wer_pct": round(statistics.median(wers) * 100, 2),
            "perfect": sum(1 for w in wers if w == 0.0),
            "latency_p50_ms": round(pct(lat, 50)) if lat else None,
            "latency_p95_ms": round(pct(lat, 95)) if lat else None,
            "first_partial_p50_ms": round(pct(fp, 50)) if fp else None,
        }
        summary.append(rec)
        print(f"{path:<12} {str(bias):<5} {rec['n']:>4} "
              f"{fmt(rec['mean_wer_pct'],'%'):>8} {fmt(rec['median_wer_pct'],'%'):>7} "
              f"{str(rec['perfect'])+'/'+str(rec['n']):>8} "
              f"{fmt(rec['latency_p50_ms'],'ms',0):>8} {fmt(rec['latency_p95_ms'],'ms',0):>8} "
              f"{fmt(rec['first_partial_p50_ms'],'ms',0):>8}")
    print()

    if args.summary_out:
        with open(args.summary_out, "w") as f:
            json.dump(summary, f, indent=2)
        print(f"summary -> {args.summary_out}", file=sys.stderr)


if __name__ == "__main__":
    main()
