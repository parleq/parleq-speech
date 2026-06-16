#!/usr/bin/env python3
"""Guided prompt-and-record tool for real-human bench audio (issue #100, Phase 4b).

Displays each utterance from a bench corpus, records you reading it aloud, and
writes an asr-bench-compatible manifest. Recording core mirrors
keavi/cmd/transcription-bench (ffmpeg -f avfoundation, 16 kHz mono) so output
drops straight into asr-bench (which requires 16 kHz mono WAV).

Resumable: existing <id>-<speaker>.wav files are detected and skippable, so you
can record in chunks. Per utterance: [Enter] record, then [Enter] stop; then
[Enter] keep+next, r = redo, s = skip, q = quit.

Usage:
    bench/.venv/bin/python bench/record_corpus.py --corpora overfire,colliding \
        --speaker jon --out bench/fixtures-human \
        --manifest bench/fixtures/manifest-human.json
"""
import argparse
import json
import os
import shutil
import signal
import subprocess
import sys


def load_utterances(corpus_dir, names):
    out = []
    for name in names:
        path = os.path.join(corpus_dir, f"{name}.json")
        if not os.path.exists(path):
            print(f"skip: {path} not found", file=sys.stderr)
            continue
        data = json.load(open(path))
        for u in data["utterances"]:
            out.append({"corpus": name, "id": u["id"], "text": u["text"],
                        "terms": u.get("terms", [])})
    return out


def list_audio_devices():
    out = subprocess.run(["ffmpeg", "-hide_banner", "-f", "avfoundation",
                          "-list_devices", "true", "-i", ""],
                         capture_output=True, text=True).stderr
    import re
    show = False
    for line in out.splitlines():
        if "audio devices" in line.lower():
            show = True
        elif "video devices" in line.lower():
            show = False
        elif show:
            m = re.search(r"(\[\d+\].*)$", line)  # only real "[N] Name" device rows
            if m:
                print("   " + m.group(1))


def record_one(out_path, device):
    """Record until the user presses Enter. Returns True on success.
    ffmpeg writes 16 kHz mono WAV from the chosen avfoundation audio input;
    SIGINT finalizes the file gracefully (same approach as transcription-bench)."""
    cmd = [
        "ffmpeg", "-loglevel", "error", "-nostdin",
        "-f", "avfoundation", "-i", device,
        "-ar", "16000", "-ac", "1", "-y", out_path,
    ]
    # CRITICAL: deny ffmpeg the terminal's stdin, otherwise it consumes the
    # Enter keypress meant to stop recording (Python's input() never sees it,
    # so "press Enter to stop" hangs). -nostdin + DEVNULL both ensure this.
    proc = subprocess.Popen(cmd, stdin=subprocess.DEVNULL)
    try:
        input("  🎙  recording… press Enter to STOP")
    finally:
        proc.send_signal(signal.SIGINT)
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()
    ok = os.path.exists(out_path) and os.path.getsize(out_path) > 1024
    if not ok:
        print("  ⚠️  recording failed or too short", file=sys.stderr)
    return ok


def main():
    ap = argparse.ArgumentParser()
    here = os.path.dirname(os.path.abspath(__file__))
    ap.add_argument("--corpora", default="overfire,colliding",
                    help="comma-separated corpus names in bench/corpus/")
    ap.add_argument("--corpus-dir", default=os.path.join(here, "corpus"))
    ap.add_argument("--out", default=os.path.join(here, "fixtures-human"))
    ap.add_argument("--speaker", default="jon", help="speaker tag in the filename")
    ap.add_argument("--manifest", default=os.path.join(here, "fixtures", "manifest-human.json"))
    ap.add_argument("--device", default=":default",
                    help='avfoundation audio input, e.g. ":2" for a specific mic (see the list printed at startup); ":default" uses the system default')
    args = ap.parse_args()

    if not shutil.which("ffmpeg"):
        sys.exit("Error: ffmpeg not found (brew install ffmpeg). Needed for mic recording.")
    print("Available audio inputs (use --device \":N\" to pick one):")
    list_audio_devices()
    print(f"Using device: {args.device}")

    os.makedirs(args.out, exist_ok=True)
    utts = load_utterances(args.corpus_dir, [c.strip() for c in args.corpora.split(",") if c.strip()])
    if not utts:
        sys.exit("no utterances loaded")

    print(f"\n{len(utts)} utterances across [{args.corpora}]. Speaker: {args.speaker}")
    print("Read each sentence naturally. Controls: [Enter]=record, s=skip, q=quit;"
          " after recording: [Enter]=keep, r=redo.\n")

    clips = []
    for i, u in enumerate(utts, 1):
        clip_id = f"{u['id']}-{args.speaker}"
        fname = f"{clip_id}.wav"
        fpath = os.path.join(args.out, fname)
        entry = {"id": clip_id, "utterance_id": u["id"], "corpus": u["corpus"],
                 "speaker": args.speaker, "terms": u["terms"],
                 "reference_transcript": u["text"], "file": fname}

        if os.path.exists(fpath) and os.path.getsize(fpath) > 1024:
            print(f"[{i}/{len(utts)}] {clip_id}: already recorded — keeping (delete the wav to redo)")
            clips.append(entry)
            continue

        print(f"\n[{i}/{len(utts)}] {clip_id}  ({u['corpus']})")
        print(f"  READ ALOUD:  “{u['text']}”")
        while True:
            choice = input("  [Enter]=record  s=skip  q=quit: ").strip().lower()
            if choice == "q":
                _write_manifest(args, clips)
                print("quit — manifest written with what's recorded so far.")
                return
            if choice == "s":
                print("  skipped.")
                break
            record_one(fpath, args.device)
            if not (os.path.exists(fpath) and os.path.getsize(fpath) > 1024):
                continue  # failed, re-offer
            post = input("  [Enter]=keep  r=redo: ").strip().lower()
            if post == "r":
                continue
            clips.append(entry)
            break

    _write_manifest(args, clips)
    print(f"\nDone. {len(clips)} clips -> {args.out}; manifest -> {args.manifest}")
    print(f"Next: asr-bench --manifest {args.manifest} --wav-dir {args.out} --paths batch ...")


def _write_manifest(args, clips):
    os.makedirs(os.path.dirname(args.manifest), exist_ok=True)
    manifest = {"generator": "record_corpus.py (human)", "speaker": args.speaker,
                "format": "16 kHz mono 16-bit PCM WAV", "clip_count": len(clips),
                "clips": clips}
    json.dump(manifest, open(args.manifest, "w"), indent=2)


if __name__ == "__main__":
    main()
