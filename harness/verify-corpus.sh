#!/usr/bin/env bash
# verify-corpus.sh
#
# The honest, runnable reference adapter for Layer 1 (SCHEMA.md). orgswift's own
# `parseOrg` still throws `OrgError.notImplemented` (see Sources/OrgSwift/Parser.swift), so it
# cannot fill the "parse input.org, normalize, diff against expected.json" loop yet. Emacs itself
# can, through harness/oracle-dump.el: it already parses a file with `org-element-parse-buffer`
# and re-emits the exact JSON shape SCHEMA.md defines. This script runs that loop over every
# conformance case and reports the real result -- it stands in for "your parser" so a reader can
# see the whole check working end to end before a single line of orgswift's own parser exists.
#
# A parser author in Rust, JS, Python, or Go implements the identical loop against their own
# parseOrg equivalent: parse input.org, normalize to the schema/org-node.schema.json shape, diff
# against expected.json. This script is the worked example of that loop, not a placeholder for
# a language this project does not have yet.
#
# Semantics: "matches" means structurally equal, the same sense Tests/OrgSwiftTests/
# OracleConformanceCrossCheckTests.swift compares in Swift (OrgJSON's Equatable -- object key
# order does not matter, array order and every value does). This script gets the same semantics
# via `jq -S` (recursively sorts object keys) on both sides before diffing the canonicalized text.
#
# Usage (from the repo root):
#   bash harness/verify-corpus.sh
#
# Exit code: 0 if every case matches (or if emacs/jq are not on PATH -- a graceful skip, not a
# false pass: see the SKIP message below, which is unambiguous about what did not run). 1 if
# emacs and jq are both available but at least one case's oracle output does not match its
# checked-in expected.json, or oracle-dump.el itself failed to produce an answer for a case.
#
# Read-only: this script only reads conformance/ and writes to a self-cleaning temp directory. It
# never writes into conformance/ or real/.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFORMANCE_DIR="$ROOT_DIR/conformance"
ORACLE_SCRIPT="$ROOT_DIR/harness/oracle-dump.el"

# --- Dependency checks: degrade with a clear message, never a silent pass. ---

if ! command -v emacs >/dev/null 2>&1; then
  echo "SKIP: emacs not found on PATH -- cannot run the oracle. Install Emacs 27+ (native json-serialize; this project develops against Emacs 30.2 / org 9.7.11) and re-run. No cases were checked." >&2
  exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not found on PATH -- cannot canonicalize JSON for comparison. Install jq and re-run. No cases were checked." >&2
  exit 0
fi

if [ ! -f "$ORACLE_SCRIPT" ]; then
  echo "ERROR: expected oracle script not found at $ORACLE_SCRIPT" >&2
  exit 1
fi

if [ ! -d "$CONFORMANCE_DIR" ]; then
  echo "ERROR: expected corpus directory not found at $CONFORMANCE_DIR" >&2
  exit 1
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

pass_count=0
fail_count=0
failed_cases=()

# Sorted, stable order -- same ordering CorpusLoader.conformanceCases() uses in the Swift suite,
# so a failure here is easy to cross-reference against a `swift test` run.
for case_dir in "$CONFORMANCE_DIR"/*/; do
  case_name="$(basename "$case_dir")"
  input_org="$case_dir/input.org"
  expected_json="$case_dir/expected.json"

  if [ ! -f "$input_org" ] || [ ! -f "$expected_json" ]; then
    echo "FAIL  $case_name (missing input.org or expected.json)"
    fail_count=$((fail_count + 1))
    failed_cases+=("$case_name")
    continue
  fi

  oracle_out="$WORK_DIR/${case_name}.oracle.json"
  oracle_err="$WORK_DIR/${case_name}.oracle.stderr"

  # Escape backslashes and double quotes before interpolating the path into an elisp string
  # literal below - unescaped, a path containing either character would break out of the
  # `"..."` it is meant to sit inside. Not exploitable today (conformance/ is repo-controlled),
  # but this script is also the one third parties are told to run against their own files.
  # Backslash first, so the backslash this step inserts for a quote is not itself re-escaped.
  escaped_input_org="${input_org//\\/\\\\}"
  escaped_input_org="${escaped_input_org//\"/\\\"}"

  if ! emacs --batch -Q -l "$ORACLE_SCRIPT" \
        --eval "(org-swift-dump \"$escaped_input_org\")" \
        >"$oracle_out" 2>"$oracle_err"; then
    echo "FAIL  $case_name (oracle-dump.el exited non-zero -- see $oracle_err)"
    fail_count=$((fail_count + 1))
    failed_cases+=("$case_name")
    continue
  fi

  if [ ! -s "$oracle_out" ]; then
    echo "FAIL  $case_name (oracle-dump.el produced no output)"
    fail_count=$((fail_count + 1))
    failed_cases+=("$case_name")
    continue
  fi

  # Canonicalize both sides (recursively sorted object keys) so key order never causes a false
  # mismatch, matching OrgJSON's Equatable semantics in the Swift suite.
  oracle_canon="$WORK_DIR/${case_name}.oracle.canon.json"
  expected_canon="$WORK_DIR/${case_name}.expected.canon.json"

  if ! jq -S . "$oracle_out" >"$oracle_canon" 2>"$WORK_DIR/${case_name}.jq.stderr"; then
    echo "FAIL  $case_name (oracle-dump.el output is not valid JSON -- see $oracle_out)"
    fail_count=$((fail_count + 1))
    failed_cases+=("$case_name")
    continue
  fi
  if ! jq -S . "$expected_json" >"$expected_canon" 2>"$WORK_DIR/${case_name}.expected-jq.stderr"; then
    echo "FAIL  $case_name (checked-in expected.json is not valid JSON -- see $expected_json)"
    fail_count=$((fail_count + 1))
    failed_cases+=("$case_name")
    continue
  fi

  if diff -q "$expected_canon" "$oracle_canon" >/dev/null 2>&1; then
    echo "PASS  $case_name"
    pass_count=$((pass_count + 1))
  else
    echo "FAIL  $case_name (oracle-dump.el output does not match expected.json)"
    # `diff -u` exits 1 on a real difference (not an error - that is the whole point of this
    # branch), and under `set -o pipefail` that nonzero status propagates through `| head | sed`
    # even though both succeed. Bare in a `set -e` script, the FIRST real mismatch would abort
    # the whole run right here instead of finishing the sweep - `|| true` neutralizes that.
    diff -u "$expected_canon" "$oracle_canon" | head -20 | sed 's/^/      /' || true
    fail_count=$((fail_count + 1))
    failed_cases+=("$case_name")
  fi
done

total=$((pass_count + fail_count))
echo
echo "== verify-corpus.sh: $pass_count/$total passed, $fail_count failed =="

if [ "$fail_count" -gt 0 ]; then
  echo "Failed cases: ${failed_cases[*]}"
  exit 1
fi

exit 0
