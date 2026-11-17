#!/bin/sh
# Install the Parleq push gate (scripts/git-hooks/push-gate.py) as this clone's
# pre-push hook. Run via `make install-hooks`. Safe to rerun.
#
# The hook runs the gate from the MAIN checkout (on main), not from whichever
# worktree is pushing, so a branch can't weaken the gate it is being pushed
# through. If a stu-managed pre-push hook is present, the gate goes in
# pre-push.local, which that hook runs first; otherwise it is appended to (or
# becomes) pre-push. RoboRev's own pre-push flush section is left in place.
set -eu
hooks=$(git rev-parse --path-format=absolute --git-path hooks)
main=$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")
gate="$main/scripts/git-hooks/push-gate.py"
mkdir -p "$hooks"
marker="# parleq push gate"
line="python3 \"$gate\" \"\$@\" || exit \$?"

if [ -f "$hooks/pre-push" ] && grep -q "stu-pre-push: managed hook" "$hooks/pre-push"; then
  target="$hooks/pre-push.local"
else
  target="$hooks/pre-push"
fi

if [ -f "$target" ] && grep -q "$marker" "$target"; then
  echo "push gate already installed in $target"
  exit 0
fi

if [ ! -f "$target" ]; then
  printf '#!/bin/sh\n' > "$target"
fi
# The gate reads git's ref lines on stdin; save them so later sections still get them.
cat >> "$target" <<HOOK
$marker (written by scripts/git-hooks/install.sh)
_pg_in=\$(mktemp "\${TMPDIR:-/tmp}/parleq-push-gate.XXXXXX") || exit 1
cat > "\$_pg_in"
python3 "$gate" "\$@" < "\$_pg_in" || { rc=\$?; rm -f "\$_pg_in"; exit \$rc; }
exec 0< "\$_pg_in"
rm -f "\$_pg_in"
# parleq push gate end
HOOK
chmod +x "$target"
echo "installed push gate in $target"
