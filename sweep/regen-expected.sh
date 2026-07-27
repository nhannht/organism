#!/bin/bash
# Regenerate every stored answer in sweep/expected/ from sweep/cases/, using this repository's
# OWN harness/oracle-dump.el.
#
#   usage: sweep/regen-expected.sh [case-name ...]
#
# Nothing in sweep/ is the source of an expected answer. The answers come from org itself, so a
# reader never has to trust the checked-in files -- they can rebuild them and diff.
#
# THAT DIFF IS THE DRIFT GUARD FOR THE CORPUS. Run this against a clean tree and `git diff`:
# empty means the stored answers still match live Emacs. Non-empty means either org changed
# under us or a stored answer was hand-edited, and both are things somebody needs to look at.
# `sweep/README.md` says why hand-editing one is never the right fix.
#
# Existing files are overwritten. Paths derive from this script's own location, so it works
# from any working directory.
set -e
SWEEP="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SWEEP/.." && pwd)"
ORACLE="$REPO/harness/oracle-dump.el"

[ -f "$ORACLE" ] || { echo "no harness/oracle-dump.el at $REPO" >&2; exit 2; }
command -v emacs >/dev/null || { echo "emacs not on PATH" >&2; exit 2; }

mkdir -p "$SWEEP/expected"

if [ $# -gt 0 ]; then
  NAMES="$*"
else
  NAMES=$(cd "$SWEEP/cases" && ls *.org | sed 's/\.org$//')
fi

ok=0; fail=0
for c in $NAMES; do
  src="$SWEEP/cases/$c.org"
  [ -f "$src" ] || { echo "SKIP $c (no sweep/cases/$c.org)"; continue; }
  if emacs --batch -Q -l "$ORACLE" --eval "(org-swift-dump \"$src\")" \
       > "$SWEEP/expected/$c.json" 2>/dev/null && [ -s "$SWEEP/expected/$c.json" ]; then
    ok=$((ok + 1))
  else
    rm -f "$SWEEP/expected/$c.json"
    fail=$((fail + 1))
    echo "FAIL $c"
  fi
done

echo "== regen-expected.sh: regenerated $ok, failed $fail =="
[ "$fail" -eq 0 ]
