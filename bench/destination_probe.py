#!/usr/bin/env python3
"""Phase 17 — destination-conditioned cleanup (intent-recovery #3).

Destination is a conditioning prior on intent: the same dictated words want
different cleanup for a code editor vs a chat message vs an email vs a doc
(symbols, casing, number formatting, tone). This probe tests whether telling the
cleanup LLM the destination produces appropriately DIFFERENT output.

Two measurements over destination-divergent utterances:
  DIVERGENCE     — do the per-destination outputs actually differ?
  APPROPRIATENESS — does each destination's output match its expected form
                    (regex markers: code wants "=>"/camelCase/flags; chat wants
                    markdown; email/doc want prose)?

Uses Parleq's real baseCleanup prompt + a destination addendum, via Vertex.

Usage:
  bench/.venv/bin/python bench/destination_probe.py --out /tmp/dest.jsonl
"""
import argparse
import importlib.util
import json
import re
import sys

lp = None  # llm_cleanup_probe, loaded in main


DESTINATIONS = {
    "code": "a code editor / source file. Use code syntax: operators (=>, ===, &&), "
            "camelCase or snake_case identifiers, CLI flags (--save-dev), digits for "
            "numbers, no conversational framing.",
    "chat": "a casual chat message (Slack/Discord). Conversational tone, contractions "
            "are fine, and markdown like **bold**, `code`, and - bullet lists is welcome.",
    "email": "a professional email. Complete sentences, a polite greeting and closing, "
             "expanded contractions, formal but warm tone.",
    "doc": "a formal written document. Clean prose, proper punctuation and capitalization, "
           "well structured, no chat shorthand.",
}

# Destination-divergent utterances. expect[dest] = list of regexes that SHOULD
# appear if the conditioning worked (only defined where there's a clear marker).
TESTS = [
    {"text": "the handler is an arrow function that takes x and returns x plus one",
     "expect": {"code": [r"=>"], "doc": [r"\barrow function\b|returns"]}},
    {"text": "call get user by id with the current session token",
     "expect": {"code": [r"getUserById|get_user_by_id"]}},
    {"text": "email the report to jane dot doe at example dot com by friday",
     "expect": {"code": [r"jane\.doe@example\.com"], "email": [r"jane\.doe@example\.com"]}},
    {"text": "install the dev dependency with npm install dash dash save dev",
     "expect": {"code": [r"--save-dev"]}},
    {"text": "make the word urgent bold and list milk eggs and bread",
     "expect": {"chat": [r"\*\*urgent\*\*", r"[-*]\s*(milk|eggs|bread)"]}},
    {"text": "the release is version two point three point one and it ships friday",
     "expect": {"code": [r"2\.3\.1"], "doc": [r"2\.3\.1"]}},
    {"text": "set the request timeout to five hundred milliseconds",
     "expect": {"code": [r"\b500\b"]}},
    {"text": "hey just checking if you had a chance to look at the pull request thanks",
     "expect": {"email": [r"(?i)\b(hi|hello|dear)\b"]}},
]


def clean(token, base, dest_desc, raw, project, region, model="gemini-2.5-flash"):
    sp = base + f"\n\nThe cleaned text will be pasted into: {dest_desc} Format it appropriately for that destination."
    return lp.call_vertex(token, project, region, model, sp, raw)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="/tmp/dest.jsonl")
    ap.add_argument("--model", default="gemini-2.5-flash")
    ap.add_argument("--project", default="keavi-beta")   # GCP project (Vertex); override as needed
    ap.add_argument("--region", default="us-central1")
    args = ap.parse_args()

    global lp
    spec = importlib.util.spec_from_file_location("lp", __file__.rsplit("/", 1)[0] + "/llm_cleanup_probe.py")
    lp = importlib.util.module_from_spec(spec); spec.loader.exec_module(lp)
    base, _ = lp.extract_prompts(lp.SP)
    token = lp.gcloud_token()

    out = open(args.out, "w")
    diverged = 0
    appr_hit = appr_tot = 0
    for i, t in enumerate(TESTS, 1):
        outs = {}
        for dest, desc in DESTINATIONS.items():
            outs[dest] = clean(token, base, desc, t["text"], args.project, args.region, args.model)
        out.write(json.dumps({"text": t["text"], "outputs": outs}) + "\n"); out.flush()
        uniq = len(set(outs.values()))
        diverged += (uniq > 1)
        print(f"\n[{i}] {t['text']!r}")
        for dest in DESTINATIONS:
            marks = ""
            if dest in t["expect"]:
                hits = [bool(re.search(rx, outs[dest])) for rx in t["expect"][dest]]
                appr_hit += sum(hits); appr_tot += len(hits)
                marks = "  [" + ("OK" if all(hits) else "MISS") + "]"
            print(f"   {dest:5}: {outs[dest]!r}{marks}")
        print(f"   -> {uniq}/4 distinct outputs")
    out.close()
    print(f"\n=== SUMMARY ({len(TESTS)} utterances) ===")
    print(f"  DIVERGENCE: {diverged}/{len(TESTS)} utterances produced destination-varying output")
    print(f"  APPROPRIATENESS: {appr_hit}/{appr_tot} expected destination markers present "
          f"({appr_hit/appr_tot:.0%})")


if __name__ == "__main__":
    main()
