#!/bin/sh
# Self-test for the push gate and its installer, in throwaway repos.
# Run: scripts/git-hooks/test-push-gate.sh   (needs git, python3, gitleaks)
set -u
here=$(cd "$(dirname "$0")" && pwd)
gate="$here/push-gate.py"
install="$here/install.sh"
work=$(mktemp -d "${TMPDIR:-/tmp}/push-gate-test.XXXXXX")
trap 'rm -rf "$work"' EXIT
fails=0
pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; fails=$((fails + 1)); }
expect_contains() {  # name, output, expected substring
  case "$2" in *"$3"*) pass "$1" ;; *) fail "$1 (wanted '$3' in: $2)" ;; esac
}
expect_refused() {  # name, output, expected substring, exit status (must be nonzero)
  if [ "$4" = 0 ]; then fail "$1 (exit 0: the push would be allowed)"; return; fi
  expect_contains "$1" "$2" "$3"
}
token() { python3 -c 'import random,string;random.seed(7);print("ghp_"+"".join(random.choice(string.ascii_letters+string.digits) for _ in range(36)))'; }

cd "$work" && git init -q -b main repo && cd repo
git config user.email t@example.com && git config user.name t
git commit -q --allow-empty -m base
base=$(git rev-parse HEAD)

# 1. a clean commit passes the scan
echo hello > a.txt && git add a.txt && git commit -qm clean
out=$(python3 "$gate" --scan-range "$base" HEAD 2>&1) && pass "clean commit passes" \
  || fail "clean commit passes ($out)"

# 2. a secret introduced only by a merge's conflict resolution is caught
git checkout -q -b side && echo b > f && git add f && git commit -qm side
git checkout -q main && echo c > f && git add f && git commit -qm main
git merge -q side >/dev/null 2>&1
echo "token = \"$(token)\"" > f && git add f && git commit -qm merge
out=$(python3 "$gate" --scan-range "$base" HEAD 2>&1)
rc=$?
expect_refused "secret added in a merge resolution" "$out" "github-pat" "$rc"

# 3. a file copied from an existing blob to a key path is caught
git checkout -q -b copy "$base" && echo hello > a.txt && git add a.txt && git commit -qm a
cp a.txt id.pem && git add id.pem && git commit -qm copy
out=$(python3 "$gate" --scan-range HEAD~1 HEAD 2>&1)
rc=$?
expect_refused "copied blob at a key path" "$out" "id.pem: signing key" "$rc"

# 4. dictation audio is refused outside bench/fixtures, allowed inside
git checkout -q -b audio "$base"
printf 'RIFF' > clip.wav && mkdir -p bench/fixtures && printf 'RIFF' > bench/fixtures/tts.wav
git add . && git commit -qm audio
out=$(python3 "$gate" --scan-range "$base" HEAD 2>&1)
rc=$?
expect_refused "audio outside bench/fixtures" "$out" "clip.wav: audio file" "$rc"
case "$out" in *tts.wav*) fail "bench/fixtures audio allowed" ;; *) pass "bench/fixtures audio allowed" ;; esac

# 5. the private denylist (hook mode) and its absence
echo 'secret[- ]project' > "$work/deny.txt"
git checkout -q -b priv "$base" && echo "about the Secret Project" > p.md && git add p.md && git commit -qm p
line="refs/heads/priv $(git rev-parse HEAD) refs/heads/priv 0000000000000000000000000000000000000000"
out=$(echo "$line" | PARLEQ_PUSH_DENYLIST="$work/deny.txt" PARLEQ_PUSH_GATE_SKIP_REVIEW=1 \
      python3 "$gate" origin url 2>&1)
rc=$?
expect_refused "private denylist term" "$out" "private denylist rule" "$rc"
out=$(echo "$line" | PARLEQ_PUSH_DENYLIST="$work/none.txt" PARLEQ_PUSH_GATE_SKIP_REVIEW=1 \
      python3 "$gate" origin url 2>&1)
rc=$?
expect_refused "missing denylist refuses" "$out" "no private denylist" "$rc"

# 6. installer: rerun replaces the gate in place; a later section still gets stdin
hooks=$(git rev-parse --path-format=absolute --git-path hooks)
printf '#!/bin/sh\necho before >&2\n' > "$hooks/pre-push" && chmod +x "$hooks/pre-push"
sh "$install" >/dev/null
printf 'echo "after:$(cat)" >&2\n' >> "$hooks/pre-push"
sh "$install" >/dev/null
order=$(grep -n -e 'echo before' -e 'parleq push gate (written' -e 'echo "after' "$hooks/pre-push" \
        | cut -d: -f2- | cut -c1-12 | tr '\n' '|')
[ "$order" = '# parleq pus|echo before |echo "after:|' ] && pass "rerun keeps section order" \
  || fail "rerun keeps section order ($order)"
[ "$(grep -c 'parleq push gate (written' "$hooks/pre-push")" = 1 ] && pass "rerun leaves one gate section" \
  || fail "rerun leaves one gate section"
# a hook that only MENTIONS pre-push.local (never runs it) still gets a working gate
rm -f "$hooks/pre-push" "$hooks/pre-push.local"
printf '#!/bin/sh\n# old backup: pre-push.local.bak\nexit 0\n' > "$hooks/pre-push"
chmod +x "$hooks/pre-push"
sh "$install" >/dev/null 2>&1
out=$(PARLEQ_PUSH_GATE_PROBE=1 "$hooks/pre-push" o u < /dev/null 2>&1)
expect_contains "gate reached when pre-push only mentions pre-push.local" "$out" "push-gate: probe"
# a hook that really chains pre-push.local gets the gate there
rm -f "$hooks/pre-push" "$hooks/pre-push.local"
printf '#!/bin/sh\n[ -x "$(dirname "$0")/pre-push.local" ] && { "$(dirname "$0")/pre-push.local" "$@" || exit $?; }\nexit 0\n' > "$hooks/pre-push"
chmod +x "$hooks/pre-push"
sh "$install" >/dev/null 2>&1
grep -q "parleq push gate (written" "$hooks/pre-push.local" && ! grep -q "parleq push gate (written" "$hooks/pre-push" \
  && pass "chaining hook gets the gate in pre-push.local" || fail "chaining hook gets the gate in pre-push.local"
# a hook that runs pre-push.local but ignores its exit status: gate goes into pre-push
rm -f "$hooks/pre-push" "$hooks/pre-push.local"
printf '#!/bin/sh\n"$(dirname "$0")/pre-push.local" "$@"\nexit 0\n' > "$hooks/pre-push"
chmod +x "$hooks/pre-push"
sh "$install" >/dev/null 2>&1
PARLEQ_PUSH_GATE_PROBE=1 "$hooks/pre-push" o u < /dev/null >/dev/null 2>&1 \
  && fail "refusal not swallowed by a status-ignoring hook" \
  || pass "refusal not swallowed by a status-ignoring hook"
# an old install left the section after an early exit: rerun moves it up
rm -f "$hooks/pre-push" "$hooks/pre-push.local"
{ printf '#!/bin/sh\nexit 0\n'; printf '# parleq push gate (written by scripts/git-hooks/install.sh)\necho stale\n# parleq push gate end\n'; } > "$hooks/pre-push"
chmod +x "$hooks/pre-push"
sh "$install" >/dev/null 2>&1
PARLEQ_PUSH_GATE_PROBE=1 "$hooks/pre-push" o u < /dev/null >/dev/null 2>&1 \
  && fail "unreachable old section is moved up" || pass "unreachable old section is moved up"
[ "$(grep -c 'parleq push gate (written' "$hooks/pre-push")" = 1 ] && pass "moved section not duplicated" \
  || fail "moved section not duplicated"
# the probe can't be used to skip the gate
out=$(echo "refs/heads/x $base refs/heads/x 0000000000000000000000000000000000000000" | \
      PARLEQ_PUSH_GATE_PROBE=1 python3 "$gate" o u 2>&1); rc=$?
[ "$rc" != 0 ] && pass "probe always refuses" || fail "probe always refuses"

git checkout -q main
# restore the ordered hook for the stdin passthrough check
rm -f "$hooks/pre-push" "$hooks/pre-push.local"
printf '#!/bin/sh\necho before >&2\n' > "$hooks/pre-push" && chmod +x "$hooks/pre-push"
sh "$install" >/dev/null
printf 'echo "after:$(cat)" >&2\n' >> "$hooks/pre-push"
out=$(echo "refs/heads/x $base refs/heads/x $base" | PARLEQ_PUSH_GATE_SKIP_REVIEW=1 \
      PARLEQ_PUSH_GATE_NO_DENYLIST=1 "$hooks/pre-push" origin url 2>&1)
expect_contains "later section receives the ref lines" "$out" "after:refs/heads/x"

echo
[ "$fails" = 0 ] && echo "all push-gate tests passed" || { echo "$fails failed"; exit 1; }
