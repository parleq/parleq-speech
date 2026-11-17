#!/bin/sh
# Install the Parleq push gate (scripts/git-hooks/push-gate.py) as this clone's
# pre-push hook. Run via `make install-hooks`. Safe to rerun.
#
# The gate is COPIED into the hooks directory and the hook runs that copy, not
# the file in whichever worktree is pushing, so a branch can't weaken the gate
# it is being pushed through. Rerun after the gate changes on main to refresh
# the copy. If a stu-managed pre-push hook is present, the gate goes in
# pre-push.local, which that hook runs first; otherwise it is appended to (or
# becomes) pre-push. RoboRev's own pre-push flush section is left in place.
set -eu
hooks=$(git rev-parse --path-format=absolute --git-path hooks)
src="$(cd "$(dirname "$0")" && pwd)/push-gate.py"
gate="$hooks/parleq-push-gate.py"
mkdir -p "$hooks"
cp "$src" "$gate"
chmod +x "$gate"
echo "copied the gate to $gate"
marker="# parleq push gate"

if [ -f "$hooks/pre-push" ] && grep -q "stu-pre-push: managed hook" "$hooks/pre-push"; then
  target="$hooks/pre-push.local"
else
  target="$hooks/pre-push"
fi

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
else
  [ -f "$target" ] || printf '#!/bin/sh\n' > "$target"
  cat "$stanza" >> "$target"
fi
rm -f "$stanza"
chmod +x "$target"
echo "installed push gate in $target"
