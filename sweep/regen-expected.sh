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
# A DEGENERATE ANSWER IS A FAILURE, NOT A FILE. `harness/oracle-dump.el' has a fallback for
# org-element types it does not map: it emits a bare `{"value": ...}', warns on stderr, and exits
# 0. This script used to send stderr to /dev/null, so the exit code was the only thing it looked
# at and every such tree was written out and read back as org's answer. 11 stored answers came
# from that fallback and 6 of them were WRONG on disk: `inline-src-block' lost `:language' and
# `:parameters' on all six of its cases. The other five (`inline-babel-call', `diary-sexp') were
# right only by coincidence -- the fallback's bare `{"value": ...}' happens to be the correct
# shape for a leaf whose value is its whole source text. Nothing anywhere could tell the six from
# the five, which is the actual defect.
#
# So stderr is now captured and searched for the oracle's unmapped-type marker, and a case that
# trips it is FAILED with its file removed rather than written. The narrow marker matters: the
# oracle also warns, deliberately, that a table.el table is outside this schema, and that warning
# is a scope boundary rather than a defect. `HarnessSupport.runOracleDump' on the Swift side
# applies the identical marker, and so does `harness/verify-corpus.sh'. Those THREE are the only
# readers of this oracle, and a gate on some of three paths reports zero for the wrong reason --
# this comment said "two paths" for a day while verify-corpus.sh was ungated, which is the same
# error one layer up: a completeness claim nothing re-counted.
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

# The marker `HarnessSupport.oracleWarningMarker' uses, character for character. Matching the
# bare "WARNING" prefix instead would also catch the deliberate table.el scope note and refuse a
# case the oracle answered correctly.
UNMAPPED_MARKER="org-swift-dump: WARNING unmapped"

ERRLOG="$(mktemp)"
trap 'rm -f "$ERRLOG"' EXIT

ok=0; fail=0
for c in $NAMES; do
  src="$SWEEP/cases/$c.org"
  [ -f "$src" ] || { echo "SKIP $c (no sweep/cases/$c.org)"; continue; }
  if emacs --batch -Q -l "$ORACLE" --eval "(org-swift-dump \"$src\")" \
       > "$SWEEP/expected/$c.json" 2>"$ERRLOG" && [ -s "$SWEEP/expected/$c.json" ]; then
    if grep -qF "$UNMAPPED_MARKER" "$ERRLOG"; then
      rm -f "$SWEEP/expected/$c.json"
      fail=$((fail + 1))
      echo "FAIL $c (oracle emitted a degenerate tree, not org's answer)"
      grep -F "$UNMAPPED_MARKER" "$ERRLOG" | sed 's/^/      /'
    else
      ok=$((ok + 1))
    fi
  else
    rm -f "$SWEEP/expected/$c.json"
    fail=$((fail + 1))
    echo "FAIL $c"
  fi
done

echo "== regen-expected.sh: regenerated $ok, failed $fail =="
[ "$fail" -eq 0 ]
