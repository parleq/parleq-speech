#!/usr/bin/env python3
"""LLM-context leg probe (issue #100, Phase 4). Runs the REAL Parleq cleanup
prompt over raw-ASR transcripts via Vertex Gemini, to measure whether the
cleanup LLM (a) recovers dictionary terms the rescorer/gate missed, and (b)
avoids inserting dictionary terms on over-fire clips (LLM hallucination check).

Faithfulness: the system prompt is extracted live from
parleq-app/Sources/ParleqAppCore/SystemPrompts.swift (baseCleanup +
vocabularyHint header), and the request mirrors VertexProvider
(systemInstruction + user "Transcript to clean up:\\n\\n<raw>",
temperature 0, thinkingBudget 0 for flash-lite). Auth: gcloud ADC token.

Usage:
    bench/.venv/bin/python bench/llm_cleanup_probe.py \
        --results /tmp/coll5.json --dictionary bench/dictionary-overfire.json \
        --out /tmp/coll5-llm.jsonl [--no-dict-hint]
"""
import argparse
import json
import os
import re
import subprocess
import sys
import urllib.request

SP = "parleq-app/Sources/ParleqAppCore/SystemPrompts.swift"


def _unescape(s):
    return s.replace("\\'", "'").replace('\\"', '"').replace("\\\\", "\\")


def extract_prompts(path):
    src = open(path).read()
    # baseCleanup = """ ... """
    m = re.search(r'baseCleanup\s*=\s*"""\n(.*?)\n\s*"""', src, re.DOTALL)
    if not m:
        sys.exit("could not extract baseCleanup from SystemPrompts.swift")
    base = _unescape(m.group(1))
    # vocabularyHint header: the return """ ... \(bullets) ... """ block
    m2 = re.search(r'return\s*"""\n(.*?Vocabulary:\n)\s*\\\(bullets\)', src, re.DOTALL)
    if not m2:
        sys.exit("could not extract vocabularyHint header")
    hint_header = _unescape(m2.group(1))
    return base, hint_header


def build_bullets(dict_path):
    d = json.load(open(dict_path))
    lines = []
    for e in d["terms"]:
        line = f'- "{e["term"]}"'
        aliases = [a for a in e.get("aliases", []) if a.strip()]
        if aliases:
            line += " (also: " + ", ".join(f'"{a}"' for a in aliases) + ")"
        if e.get("context", "").strip():
            line += f' — {e["context"].strip()}'
        lines.append(line)
    return "\n".join(lines)


def system_prompt(base, hint_header, bullets, use_hint):
    if not use_hint:
        return base
    return base + "\n\n" + hint_header + bullets


def gcloud_token():
    return subprocess.run(
        ["gcloud", "auth", "print-access-token"],
        capture_output=True, text=True, check=True
    ).stdout.strip()


def call_vertex(token, project, region, model, sys_prompt, raw):
    url = (f"https://{region}-aiplatform.googleapis.com/v1/projects/{project}"
           f"/locations/{region}/publishers/google/models/{model}:generateContent")
    body = {
        "systemInstruction": {"parts": [{"text": sys_prompt}]},
        "contents": [{"role": "user", "parts": [{"text": f"Transcript to clean up:\n\n{raw}"}]}],
        "generationConfig": {"temperature": 0, "maxOutputTokens": 2048,
                             "thinkingConfig": {"thinkingBudget": 0}},
    }
    req = urllib.request.Request(
        url, data=json.dumps(body).encode(),
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=60) as r:
        resp = json.load(r)
    try:
        return "".join(p.get("text", "")
                       for p in resp["candidates"][0]["content"]["parts"]).strip()
    except (KeyError, IndexError):
        return f"[no-output: {json.dumps(resp)[:200]}]"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--results", required=True)
    ap.add_argument("--dictionary", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--project", default="keavi-beta")
    ap.add_argument("--region", default="us-central1")
    ap.add_argument("--model", default="gemini-2.5-flash-lite")
    ap.add_argument("--no-dict-hint", action="store_true",
                    help="omit the vocabulary hint (test pure context recovery)")
    args = ap.parse_args()

    base, hint_header = extract_prompts(SP)
    bullets = build_bullets(args.dictionary)
    sp = system_prompt(base, hint_header, bullets, use_hint=not args.no_dict_hint)
    token = gcloud_token()

    rows = json.load(open(args.results))
    raw_rows = [r for r in rows if not r.get("biasing")]
    out = open(args.out, "w")
    for i, r in enumerate(raw_rows, 1):
        cleaned = call_vertex(token, args.project, args.region, args.model, sp, r["hyp"])
        out.write(json.dumps({"id": r["id"], "raw": r["hyp"], "cleaned": cleaned}) + "\n")
        out.flush()
        if i % 20 == 0:
            print(f"  {i}/{len(raw_rows)}", file=sys.stderr)
    out.close()
    print(f"wrote {len(raw_rows)} rows -> {args.out} (dict_hint={not args.no_dict_hint})")


if __name__ == "__main__":
    main()
