#!/usr/bin/env python3
"""Generate voice fixtures for the ASR benchmark using macOS `say`.

Creds-free and reproducible on any macOS box: reads the text corpora in
bench/corpus/, synthesizes one 16 kHz mono 16-bit WAV per (utterance x voice)
with the built-in `say` command, and writes a manifest pairing each WAV with its
reference transcript. Commit the resulting WAVs + manifest so the benchmark runs
with zero setup; re-run this to extend or regenerate the corpus.

Usage:
    python3 bench/gen_fixtures.py
    python3 bench/gen_fixtures.py --voices Samantha,Daniel --out bench/fixtures

Voices default to three natural macOS voices spanning US/GB/AU accents. Override
with --voices if a box lacks one (check `say -v '?'`).
"""
import argparse
import json
import os
import subprocess
import sys

# Natural macOS voices and their accent tags. `say -v '?'` lists what's
# installed; these three ship with a default macOS and cover US/GB/AU.
VOICE_ACCENT = {
    "Samantha": "us",
    "Daniel": "gb",
    "Karen": "au",
}

# `say` emits a WAVE whose PCM data does not start at the canonical byte 44
# (it writes extra chunks), so the audio byte count isn't simply filesize-44.
# We report duration from afinfo when available; otherwise omit it. Duration is
# informational only — the bench measures latency itself.
def probe_duration_ms(path):
    try:
        out = subprocess.run(
            ["afinfo", path], capture_output=True, text=True, timeout=30
        ).stdout
        for line in out.splitlines():
            if "estimated duration" in line:
                secs = float(line.split(":")[1].strip().split()[0])
                return round(secs * 1000)
    except Exception:
        pass
    return None


def synth(text, voice, out_path):
    """Run `say` -> 16 kHz mono 16-bit WAV. Raises on failure."""
    subprocess.run(
        [
            "say", "-v", voice,
            "-o", out_path,
            "--file-format=WAVE",
            "--data-format=LEI16@16000",
            text,
        ],
        check=True,
        capture_output=True,
        text=True,
    )


def load_corpus(path):
    with open(path) as f:
        data = json.load(f)
    return data["utterances"]


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    ap = argparse.ArgumentParser()
    ap.add_argument("--corpus-dir", default=os.path.join(here, "corpus"))
    ap.add_argument("--out", default=os.path.join(here, "fixtures"))
    ap.add_argument("--voices", default=",".join(VOICE_ACCENT.keys()))
    ap.add_argument("--manifest", default=None,
                    help="manifest path (default <out>/manifest.json)")
    args = ap.parse_args()

    voices = [v.strip() for v in args.voices.split(",") if v.strip()]
    os.makedirs(args.out, exist_ok=True)
    manifest_path = args.manifest or os.path.join(args.out, "manifest.json")

    corpora = [
        ("general", os.path.join(args.corpus_dir, "general.json")),
        ("biasing", os.path.join(args.corpus_dir, "biasing.json")),
    ]

    clips = []
    n = 0
    for corpus_name, corpus_path in corpora:
        if not os.path.exists(corpus_path):
            print(f"skip: {corpus_path} not found", file=sys.stderr)
            continue
        for utt in load_corpus(corpus_path):
            for voice in voices:
                clip_id = f"{utt['id']}-{voice}"
                fname = f"{clip_id}.wav"
                out_path = os.path.join(args.out, fname)
                synth(utt["text"], voice, out_path)
                clips.append({
                    "id": clip_id,
                    "utterance_id": utt["id"],
                    "corpus": corpus_name,
                    "voice": voice,
                    "accent": VOICE_ACCENT.get(voice, "unknown"),
                    "category": utt.get("category", corpus_name),
                    "terms": utt.get("terms", []),
                    "reference_transcript": utt["text"],
                    "file": fname,
                    "duration_ms": probe_duration_ms(out_path),
                })
                n += 1
                print(f"  [{n}] {fname}", file=sys.stderr)

    manifest = {
        "generator": "macOS say",
        "format": "16 kHz mono 16-bit PCM WAV",
        "voices": {v: VOICE_ACCENT.get(v, "unknown") for v in voices},
        "clip_count": len(clips),
        "clips": clips,
    }
    with open(manifest_path, "w") as f:
        json.dump(manifest, f, indent=2)
    print(f"\nWrote {len(clips)} clips + manifest -> {manifest_path}", file=sys.stderr)


if __name__ == "__main__":
    main()
