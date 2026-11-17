#!/bin/sh
# Install the Parleq push gate (scripts/git-hooks/push-gate.py) as this clone's
# pre-push hook. Run via `make install-hooks`. Safe to rerun.
#
# The gate is COPIED into the hooks directory and the hook runs that copy, not
# the file in whichever worktree is pushing, so a branch can't weaken the gate
# it is being pushed through. Rerun after the gate changes on main to refresh
# the copy. If the existing pre-push hook chains a pre-push.local, the gate goes in
# pre-push.local, which that hook runs first; otherwise it is inserted near the
# top of pre-push (after RoboRev's flush section, if any). The install runs the
# hook in a probe mode to prove the gate is reached.
set -eu
hooks=$(git rev-parse --path-format=absolute --git-path hooks)
src="$(cd "$(dirname "$0")" && pwd)/push-gate.py"
gate="$hooks/parleq-push-gate.py"
mkdir -p "$hooks"
cp "$src" "$gate"
chmod +x "$gate"
echo "copied the gate to $gate"
marker="# parleq push gate"

# Our section. The gate reads git's ref lines on stdin; it saves them so later
# sections still get them.
stanza=$(mktemp "${TMPDIR:-/tmp}/parleq-install.XXXXXX")
cat > "$stanza" <<HOOK
$marker (written by scripts/git-hooks/install.sh)
_pg_in=\$(mktemp "\${TMPDIR:-/tmp}/parleq-push-gate.XXXXXX") || exit 1
cat > "\$_pg_in"
python3 "$gate" "\$@" < "\$_pg_in" || { rc=\$?; rm -f "\$_pg_in"; exit \$rc; }
exec 0< "\$_pg_in"
rm -f "\$_pg_in"
# parleq push gate end
HOOK

place() {  # write or refresh our section in hook file $1
  target=$1
  if [ -f "$target" ] && grep -q "$marker" "$target"; then
    # Replace our section where it stands, so a rerun picks up changes to it and
    # the order of every other section is unchanged.
    tmp=$(mktemp "${TMPDIR:-/tmp}/parleq-install.XXXXXX")
    awk -v m="$marker" -v f="$stanza" '
      index($0, m) == 1 && $0 != "# parleq push gate end" {
        while ((getline l < f) > 0) print l; close(f); skip=1; next }
      skip { if ($0 == "# parleq push gate end") skip=0; next }
      { print }' "$target" > "$tmp"
    cat "$tmp" > "$target"
    rm -f "$tmp"
  elif [ ! -f "$target" ]; then
    { printf '#!/bin/sh\n'; cat "$stanza"; } > "$target"
  else
    # Insert near the top, so an earlier `exit` in the existing hook can't skip
    # it: after RoboRev's flush section when there is one (it enqueues the
    # reviews the gate waits for), otherwise right after the shebang line.
    tmp=$(mktemp "${TMPDIR:-/tmp}/parleq-install.XXXXXX")
    if grep -q "^# roborev hook end" "$target"; then after="^# roborev hook end"; else after=""; fi
    awk -v f="$stanza" -v a="$after" '
      { print }
      !done && ((a == "" && NR == 1) || (a != "" && $0 ~ a)) {
        while ((getline l < f) > 0) print l; close(f); done=1 }' "$target" > "$tmp"
    cat "$tmp" > "$target"
    rm -f "$tmp"
  fi
  chmod +x "$target"
}

unplace() {  # remove our section from hook file $1, if present
  [ -f "$1" ] && grep -q "$marker" "$1" || return 0
  tmp=$(mktemp "${TMPDIR:-/tmp}/parleq-install.XXXXXX")
  awk -v m="$marker" '
    index($0, m) == 1 && $0 != "# parleq push gate end" { skip=1; next }
    skip { if ($0 == "# parleq push gate end") skip=0; next }
    { print }' "$1" > "$tmp"
  cat "$tmp" > "$1"
  rm -f "$tmp"
}

gate_runs() {  # does git's pre-push hook reach the gate AND fail when it refuses?
  # The probe always refuses, so a passing hook means the refusal was swallowed.
  if out=$(PARLEQ_PUSH_GATE_PROBE=1 "$hooks/pre-push" origin probe < /dev/null 2>&1); then
    return 1
  fi
  printf '%s\n' "$out" | grep -q "push-gate: probe"
}

# Prefer pre-push.local when the existing hook chains it (some hook managers
# rewrite pre-push itself), but only if probing the hook proves the gate is
# reached and its refusal stops the push. Otherwise the gate goes into pre-push,
# near the top.
where=""
if [ -f "$hooks/pre-push" ] && grep -q "pre-push\.local" "$hooks/pre-push"; then
  place "$hooks/pre-push.local"
  if gate_runs; then where="$hooks/pre-push.local"; else unplace "$hooks/pre-push.local"; fi
fi
if [ -z "$where" ]; then
  place "$hooks/pre-push"
  if ! gate_runs; then
    # e.g. a section left after an early `exit` by an older install: move it up
    unplace "$hooks/pre-push"
    place "$hooks/pre-push"
  fi
  where="$hooks/pre-push"
fi
rm -f "$stanza"
if ! gate_runs; then
  echo "install-hooks: the pre-push hook does not run the gate or ignores its refusal;" \
       "check $hooks/pre-push" >&2
  exit 1
fi
echo "installed push gate in $where (verified)"
