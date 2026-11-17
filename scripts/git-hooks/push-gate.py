#!/usr/bin/env python3
"""Parleq push gate: what must hold before commits leave this machine.

Installed as a git pre-push hook by `make install-hooks`. Git hands the hook the
refs being pushed on stdin; for every commit the push would publish that no remote
already has, two checks run:

  1. RoboRev review handled. Each non-merge commit needs at least one finished
     RoboRev review, and every review of it must be closed. A passing review closes
     itself; a failing one is closed once its findings are fixed or consciously
     skipped (`roborev job comment --job N "..."` then `roborev job close N`).
     Reviews still queued or running are waited for (PARLEQ_REVIEW_WAIT seconds,
     default 900), so a push right after a commit just takes a minute.

  2. Public-content scan. This repo is public, so the pushed range is checked for:
       - secrets (gitleaks over the pushed commits; fake test values live in
         .gitleaksignore),
       - files that must never be published (dictation audio, usage logs, encrypted
         voiceprint stores, signing keys, build products, model weights) and any
         blob over 5 MB,
       - site copy promises the product can't keep (web/src only),
       - the maintainer's PRIVATE denylist: one case-insensitive regex per line in
         ~/.config/parleq/push-denylist.txt (override the path with
         PARLEQ_PUSH_DENYLIST). It lives outside the repo because listing private
         names in a public repo would publish them. It is matched against added
         lines, commit messages, file paths and ref names.
     A line that is a deliberate exception can carry the marker `push-gate:allow`.

Fails closed: if roborev, gitleaks or the private denylist is missing, or anything
errors, the push is refused.
Owner-only overrides, which agents never set:
  PARLEQ_PUSH_GATE_SKIP_REVIEW=1   skip check 1 (e.g. RoboRev is down)
  PARLEQ_PUSH_GATE_SKIP_SCAN=1     skip check 2 (a false positive you have read)
  PARLEQ_PUSH_GATE_NO_DENYLIST=1   push without the private denylist file

CI mode (no RoboRev, no private denylist; used by .github/workflows/public-scan.yml):
  push-gate.py --scan-range <base> <head>
"""
import fnmatch
import json
import os
import re
import shutil
import subprocess
import sys
import time

ZERO = "0" * 40
ALLOW_MARKER = "push-gate:allow"
MAX_BLOB_BYTES = 5 * 1024 * 1024
REVIEW_WAIT = int(os.environ.get("PARLEQ_REVIEW_WAIT", "900"))
APPEAR_GRACE = 90  # seconds to wait for a just-made commit's review job to be enqueued
POLL = 10
DENYLIST = os.path.expanduser(
    os.environ.get("PARLEQ_PUSH_DENYLIST", "~/.config/parleq/push-denylist.txt"))

AUDIO = ("*.wav", "*.m4a", "*.caf", "*.flac", "*.mp3", "*.aif", "*.aiff", "*.ogg",
         "*.opus", "*.webm")
# (glob on the repo path, reason, allowed-prefixes)
BLOCKED_PATHS = (
    [(g, "audio file: dictation audio is never committed", ("bench/fixtures/",))
     for g in AUDIO] +
    [(g, "usage/dictation data", ()) for g in
     ("*usage.jsonl", "*flywheel/*", "*config.backup*", "*.parleq/*")] +
    [("*.enc", "encrypted voiceprint/enrollment store",
      ("parleq-app/Tests/ParleqAppCoreTests/Fixtures/",))] +
    [(g, "signing key or credential file", ()) for g in
     ("*.p12", "*.pem", "*.key", "*.cer", "*.mobileprovision", "*.keychain*",
      ".env", "*/.env", ".env.*", "*/.env.*", "*credentials.json",
      "*service-account*.json")] +
    [(g, "build product (ship it as a release asset instead)", ()) for g in
     ("*.dmg", "*.pkg", "*.app/*", "*.xcarchive/*")] +
    [(g, "model weights", ()) for g in
     ("*.safetensors", "*.gguf", "*.onnx", "*.mlmodelc/*", "*.mlpackage/*")]
)
ALLOWED_ENV_FILES = (".env.example", ".env.sample")

# (regex, reason, path prefix the rule applies to)
REPO_TEXT_RULES = [
    (re.compile(r"nothing\s+leaves\s+your\s+mac", re.I),
     "site copy must not promise 'nothing leaves your Mac' (cloud cleanup sends text)",
     "web/src/"),
    (re.compile(r"100\s*%\s*on[- ]device", re.I),
     "site copy must not claim '100% on-device'", "web/src/"),
]


def git(*args, ok=(0,)):
    p = subprocess.run(["git", *args], capture_output=True, text=True)
    if p.returncode not in ok:
        raise RuntimeError("git %s failed: %s" % (" ".join(args), p.stderr.strip()))
    return p.stdout


def say(msg):
    print("push-gate: " + msg, file=sys.stderr)


# ---------------------------------------------------------------- the pushed range

def range_args(lsha, rsha):
    """git rev-list arguments for the commits this ref update would newly publish."""
    args = [lsha, "--not", "--remotes"]
    if rsha != ZERO and subprocess.run(["git", "cat-file", "-e", rsha + "^{commit}"],
                                       capture_output=True).returncode == 0:
        args.append(rsha)
    return args


def commits(rargs, merges=True):
    extra = [] if merges else ["--no-merges"]
    return git("rev-list", "--reverse", *extra, *rargs).split()


# ---------------------------------------------------------------- 1. RoboRev

def roborev_jobs():
    exe = shutil.which("roborev") or os.path.expanduser("~/.local/bin/roborev")
    if not os.access(exe, os.X_OK):
        raise RuntimeError("roborev not found (install it, or owner-only: "
                           "PARLEQ_PUSH_GATE_SKIP_REVIEW=1)")
    p = subprocess.run([exe, "job", "list", "--json", "--all-branches", "--limit", "5000"],
                       capture_output=True, text=True)
    if p.returncode != 0:
        raise RuntimeError("roborev job list failed: " + p.stderr.strip()[:300])
    by_sha = {}
    for j in json.loads(p.stdout or "[]"):
        if j.get("job_type", "review") != "review":
            continue
        by_sha.setdefault(j.get("git_ref", ""), []).append(j)
    return by_sha


def review_state(jobs):
    """-> ('ok'|'wait'|'missing'|'failed'|'open', detail)"""
    if not jobs:
        return "missing", ""
    if any(j.get("status") in ("queued", "running") for j in jobs):
        return "wait", ""
    done = [j for j in jobs if j.get("status") == "done"]
    if not done:
        return "failed", ", ".join("job %s %s" % (j["id"], j.get("status")) for j in jobs)
    still_open = [j for j in done if not j.get("closed")]
    if still_open:
        return "open", ", ".join("job %s (verdict %s)" % (j["id"], j.get("verdict") or "?")
                                 for j in still_open)
    return "ok", ""


def check_reviews(shas):
    if not shas:
        return []
    start = time.monotonic()
    announced = False
    while True:
        by_sha = roborev_jobs()
        states = {s: review_state(by_sha.get(s, [])) for s in shas}
        elapsed = time.monotonic() - start
        waiting = [s for s, (st, _) in states.items()
                   if st == "wait" or (st == "missing" and elapsed < APPEAR_GRACE)]
        if waiting and elapsed < REVIEW_WAIT:
            if not announced:
                say("waiting for RoboRev to finish reviewing %d commit(s): %s"
                    % (len(waiting), " ".join(s[:9] for s in waiting)))
                announced = True
            time.sleep(POLL)
            continue
        break
    out = []
    for s, (st, detail) in states.items():
        subj = git("log", "-1", "--format=%s", s).strip()[:60]
        if st == "ok":
            continue
        if st == "wait":
            out.append("%s %s: RoboRev review still running after %ds; push again when "
                       "it finishes" % (s[:9], subj, REVIEW_WAIT))
        elif st == "missing":
            out.append("%s %s: no RoboRev review; run `roborev review %s`"
                       % (s[:9], subj, s[:9]))
        elif st == "failed":
            out.append("%s %s: RoboRev review did not complete (%s); run `roborev review "
                       "%s`" % (s[:9], subj, detail, s[:9]))
        else:
            out.append("%s %s: open RoboRev review: %s. Fix or consciously skip the "
                       "findings, then `roborev job comment --job N \"what you did\"` and "
                       "`roborev job close N`" % (s[:9], subj, detail))
    return out


# ---------------------------------------------------------------- 2. content scan

def load_denylist(required):
    if not os.path.exists(DENYLIST):
        if required and os.environ.get("PARLEQ_PUSH_GATE_NO_DENYLIST") != "1":
            raise RuntimeError("no private denylist at %s; create it (one regex per line), "
                               "or owner-only: PARLEQ_PUSH_GATE_NO_DENYLIST=1" % DENYLIST)
        return []
    rules = []
    with open(DENYLIST, encoding="utf-8") as f:
        for n, line in enumerate(f, 1):
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            try:
                rules.append(re.compile(line, re.I))
            except re.error as e:
                raise RuntimeError("bad regex on line %d of %s: %s" % (n, DENYLIST, e))
    return rules


def path_blocked(path):
    base = os.path.basename(path)
    if base in ALLOWED_ENV_FILES:
        return None
    for glob, reason, allowed in BLOCKED_PATHS:
        if any(path.startswith(a) for a in allowed):
            continue
        if fnmatch.fnmatch(path, glob) or fnmatch.fnmatch(base, glob):
            return reason
    return None


def changed_paths(rargs):
    """Every path a commit in the range adds or changes, merges included (a file copied
    from an existing blob still counts, since this reads the diffs, not new objects)."""
    names = git("log", "--format=", "--name-only", "--no-renames", "--diff-filter=ACMRT",
                "-m", *rargs).split("\n")
    return sorted({n for n in names if n})


def scan_objects(rargs):
    """Blocked paths among the changed files, and oversized new blobs."""
    out = []
    for path in changed_paths(rargs):
        reason = path_blocked(path)
        if reason:
            out.append("%s: %s" % (path, reason))
    objs = git("rev-list", "--objects", "--no-object-names", *rargs).split()
    named = {}
    for line in git("rev-list", "--objects", *rargs).splitlines():
        parts = line.split(" ", 1)
        if len(parts) == 2:
            named[parts[0]] = parts[1]
    if not objs:
        return out
    p = subprocess.run(["git", "cat-file", "--batch-check=%(objectname) %(objecttype) "
                        "%(objectsize)"], input="\n".join(objs) + "\n",
                       capture_output=True, text=True, check=True)
    for line in p.stdout.splitlines():
        sha, typ, size = line.split()
        if typ != "blob" or sha not in named:
            continue
        path = named[sha]
        if int(size) > MAX_BLOB_BYTES:
            out.append("%s: %.1f MB blob (limit 5 MB)" % (path, int(size) / 1048576))
    return out


def added_lines(rargs):
    """-> [(commit, path, line)] for every added line in the range. A merge contributes
    its combined diff (--cc): the lines its result has that no parent had, which is
    where a conflict resolution can introduce new text."""
    out, commit, path, width = [], None, None, 1
    txt = git("log", "-p", "--cc", "--format=COMMIT %H %P", "--unified=0", "--no-color",
              "--no-ext-diff", "--no-renames", *rargs)
    for line in txt.splitlines():
        if line.startswith("COMMIT "):
            parts = line.split()
            commit, path, width = parts[1], None, max(1, len(parts) - 2)
        elif line.startswith("+++ "):
            path = line[6:] if line.startswith("+++ b/") else None
        elif path is not None and line[:width].strip("+ ") == "" and "+" in line[:width]:
            out.append((commit, path, line[width:]))
    return out


def scan_text(rargs, refname, private):
    out = []
    for commit, path, line in added_lines(rargs):
        if ALLOW_MARKER in line:
            continue
        for rx, reason, prefix in REPO_TEXT_RULES:
            if path.startswith(prefix) and rx.search(line):
                out.append("%s (%s): %s" % (path, commit[:9], reason))
        for rx in private:
            if rx.search(line):
                out.append("%s (%s): added line matches private denylist rule /%s/"
                           % (path, commit[:9], rx.pattern))
    if private:
        for c in commits(rargs):
            msg = git("log", "-1", "--format=%B", c)
            for rx in private:
                if rx.search(msg):
                    out.append("commit message of %s matches private denylist rule /%s/"
                               % (c[:9], rx.pattern))
        names = set(git("log", "--format=", "--name-only", *rargs).split("\n"))
        for name in sorted(n for n in names if n):
            for rx in private:
                if rx.search(name):
                    out.append("file path %s matches private denylist rule /%s/"
                               % (name, rx.pattern))
        for rx in private:
            if refname and rx.search(refname):
                out.append("ref name %s matches private denylist rule /%s/"
                           % (refname, rx.pattern))
    return sorted(set(out))


def gitleaks(rargs):
    exe = shutil.which("gitleaks")
    if not exe:
        raise RuntimeError("gitleaks not found (`brew install gitleaks`, or owner-only: "
                           "PARLEQ_PUSH_GATE_SKIP_SCAN=1)")
    root = git("rev-parse", "--show-toplevel").strip()
    ignore = os.environ.get("PARLEQ_GITLEAKSIGNORE") or root
    base = [exe, "--no-banner", "--no-color", "-v", "--redact", "--exit-code", "3", "-i", ignore]
    runs = [(["git", *base[1:], "--log-opts", " ".join(rargs), root], None)]
    # gitleaks reads a merge's diff against neither parent, so text a conflict
    # resolution adds is invisible to it; feed it each merge's combined diff instead.
    for m in git("rev-list", "--merges", *rargs).split():
        runs.append((["stdin", *base[1:]],
                     git("show", "--cc", "--format=", "--no-color", "--unified=0", m)))
    out = []
    for args, stdin in runs:
        p = subprocess.run([exe, *args], input=stdin, capture_output=True, text=True)
        if p.returncode == 3:
            # Keep only where it is; the verbose report also carries author name and
            # email, which a public CI log should not repeat.
            keep = ("RuleID:", "File:", "Line:", "Commit:", "Fingerprint:")
            lines = [l.strip() for l in (p.stdout + p.stderr).splitlines()
                     if l.strip().startswith(keep)]
            out.append("gitleaks found a likely secret: " + "; ".join(lines[:25]) +
                       " (a fake test value goes in .gitleaksignore by fingerprint)")
        elif p.returncode != 0:
            raise RuntimeError("gitleaks failed: " + (p.stderr or p.stdout).strip()[-500:])
    return out


def scan(rargs, refname, private):
    return scan_objects(rargs) + scan_text(rargs, refname, private) + gitleaks(rargs)


# ---------------------------------------------------------------- entry points

def hook():
    skip_review = os.environ.get("PARLEQ_PUSH_GATE_SKIP_REVIEW") == "1"
    skip_scan = os.environ.get("PARLEQ_PUSH_GATE_SKIP_SCAN") == "1"
    private = [] if skip_scan else load_denylist(required=True)
    refusals, review_shas = [], []
    for line in sys.stdin.read().splitlines():
        parts = line.split()
        if len(parts) != 4:
            raise RuntimeError("malformed ref line from git: %r" % line)
        lref, lsha, rref, rsha = parts
        if lsha == ZERO:  # deleting a ref publishes nothing
            continue
        rargs = range_args(lsha, rsha)
        if not commits(rargs):
            continue
        if not skip_scan:
            refusals += ["%s: %s" % (rref, r) for r in scan(rargs, rref, private)]
        review_shas += [c for c in commits(rargs, merges=False) if c not in review_shas]
    if not skip_review:
        refusals += check_reviews(review_shas)
    if skip_review:
        say("RoboRev check SKIPPED (PARLEQ_PUSH_GATE_SKIP_REVIEW=1)")
    if skip_scan:
        say("public-content scan SKIPPED (PARLEQ_PUSH_GATE_SKIP_SCAN=1)")
    if refusals:
        say("push refused:")
        for r in refusals:
            print("  - " + r, file=sys.stderr)
        return 1
    return 0


def ci(base, head):
    rargs = [head, "--not", base] if base and set(base) != {"0"} else [head]
    refusals = scan(rargs, "", [])
    for r in refusals:
        print("::error::" + r.replace("\n", " "))
    if not refusals:
        print("push-gate: public-content scan clean (%d commit(s))" % len(commits(rargs)))
    return 1 if refusals else 0


def main(argv):
    try:
        if len(argv) >= 1 and argv[0] == "--scan-range":
            return ci(argv[1], argv[2])
        return hook()
    except Exception as e:  # fail closed
        say("error, refusing the push: %s" % e)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
