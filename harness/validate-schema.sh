#!/usr/bin/env bash
# validate-schema.sh
#
# Validates every conformance/*/expected.json against schema/org-node.schema.json, the schema
# SCHEMA.md positions as the language-agnostic contract other implementations must satisfy.
#
# ## Why this exists
#
# Until this script, NOTHING in the repository ever validated a tree against that schema. The
# schema could disagree with the oracle, with SCHEMA.md, and with the fixtures indefinitely while
# every gate stayed green, and it did: `$defs.affiliated`'s ATTR key pattern forbade the hyphen
# that org's own `org-element--affiliated-re` allows, so an ordinary `#+ATTR_MY-BACKEND:` line
# produced a tree that was correct by the oracle and INVALID by the published schema. A
# third-party implementation reproducing org faithfully would have failed conformance and been
# right. Nothing could see it, because the only mention of the schema file anywhere in the
# repository was a comment in verify-corpus.sh.
#
# `CorpusIntegrityTests.schemaShapeIsValid` reads like this gate and is not: it hand-checks two
# invariants (every node has a non-empty `type`, no node carries both `value` and `children`) and
# never loads the schema file.
#
# ## The self-test is not optional, and it runs first
#
# A gate that reports "104/104 valid" is worth nothing until it has been shown able to say
# anything else. So before the corpus sweep, this script validates a small set of hand-built
# trees whose verdicts are known, in BOTH directions:
#
#   - a minimal well-formed tree that MUST be accepted, so a validator that rejects everything
#     (a broken schema load, a wrong draft, an unresolvable $ref) cannot make every negative
#     below "pass" and report a green sweep;
#   - several malformed trees that MUST each be rejected, so a validator that accepts everything
#     (the actual historical failure mode here: no validator at all) is caught immediately.
#
# If any self-test verdict is wrong the script exits 1 WITHOUT sweeping the corpus, and says the
# validator or the schema is broken rather than blaming a fixture. A corpus result printed by an
# instrument that has not proven it discriminates is not evidence.
#
# ## Usage (from the repo root)
#
#   bash harness/validate-schema.sh
#
# A parser author in Rust, JS, Python or Go runs this same script: it validates the corpus, not
# any particular implementation's output. To validate your OWN parser's output, point a
# Draft 2020-12 validator at schema/org-node.schema.json and feed it your tree; this script is
# the worked example of that call.
#
# Exit code: 0 if every case validates, or if python3 / the jsonschema module are not available
# (a graceful skip, not a false pass - the SKIP message says plainly that nothing was checked).
# 1 if a self-test verdict is wrong, if the schema is not itself a valid Draft 2020-12 schema, or
# if any fixture fails validation.
#
# Read-only: reads conformance/ and schema/ only, writes nothing.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCHEMA_FILE="$ROOT_DIR/schema/org-node.schema.json"
CONFORMANCE_DIR="$ROOT_DIR/conformance"

# --- Dependency checks: degrade with a clear message, never a silent pass. ---

if ! command -v python3 >/dev/null 2>&1; then
  echo "SKIP: python3 not found on PATH -- cannot run a JSON Schema validator. Install Python 3.9+ and the jsonschema package, then re-run. No cases were checked." >&2
  exit 0
fi

if ! python3 -c "import jsonschema" >/dev/null 2>&1; then
  echo "SKIP: the 'jsonschema' Python package is not installed -- cannot validate. Install it (pip install jsonschema) and re-run. No cases were checked." >&2
  exit 0
fi

if [ ! -f "$SCHEMA_FILE" ]; then
  echo "ERROR: expected schema not found at $SCHEMA_FILE" >&2
  exit 1
fi

if [ ! -d "$CONFORMANCE_DIR" ]; then
  echo "ERROR: expected corpus directory not found at $CONFORMANCE_DIR" >&2
  exit 1
fi

python3 - "$SCHEMA_FILE" "$CONFORMANCE_DIR" <<'PYTHON_VALIDATOR'
import json
import pathlib
import sys

from jsonschema import Draft202012Validator

schema_file = pathlib.Path(sys.argv[1])
conformance_dir = pathlib.Path(sys.argv[2])

schema = json.loads(schema_file.read_text(encoding="utf-8"))

# The schema must itself be a valid Draft 2020-12 schema. A typo'd keyword (a misspelled
# "patternProperties", say) is silently IGNORED by a validator rather than rejected, which would
# make this whole gate quietly weaker than it reads.
try:
    Draft202012Validator.check_schema(schema)
except Exception as exc:  # noqa: BLE001 - the message is the whole point
    print("ERROR: schema/org-node.schema.json is not a valid Draft 2020-12 schema:")
    print(f"       {exc}")
    sys.exit(1)

validator = Draft202012Validator(schema)


def first_error(tree):
    """Return the first validation error for `tree`, or None when it validates."""
    return next(iter(validator.iter_errors(tree)), None)


def node(node_type, **fields):
    """A schema node: `type` plus whatever the node type carries."""
    return {"type": node_type, **fields}


def document(*children, **fields):
    return node("document", children=list(children), postBlank=0, **fields)


def section(*children):
    return node("section", children=list(children), postBlank=0)


def comment(value="c"):
    return node("comment", value=value, postBlank=0)


def paragraph_with_affiliated(affiliated):
    return document(
        section(
            node(
                "paragraph",
                children=[{"type": "text", "value": "para\n"}],
                postBlank=0,
                affiliated=affiliated,
            )
        )
    )


# (name, tree, must_validate). Both directions are present deliberately: see the header.
SELF_TESTS = [
    (
        "positive control: a minimal well-formed document",
        document(section(comment())),
        True,
    ),
    (
        "positive control: a hyphenated ATTR backend, which org's own "
        "org-element--affiliated-re allows (ATTR_[-_A-Za-z0-9]+)",
        paragraph_with_affiliated([{"key": "ATTR_MY-BACKEND", "value": [":x 1"]}]),
        True,
    ),
    (
        "negative: a node missing its required `type`",
        document(section({"value": "c", "postBlank": 0})),
        False,
    ),
    (
        "negative: an unknown affiliated key",
        paragraph_with_affiliated([{"key": "BOGUS", "value": "x"}]),
        False,
    ),
    (
        "negative: affiliated HEADER carrying a bare string instead of an array of strings",
        paragraph_with_affiliated([{"key": "HEADER", "value": ":var x=1"}]),
        False,
    ),
    (
        "negative: affiliated NAME carrying an array instead of a plain string",
        paragraph_with_affiliated([{"key": "NAME", "value": ["x"]}]),
        False,
    ),
    (
        "negative: a negative postBlank",
        document(section(node("comment", value="c", postBlank=-1))),
        False,
    ),
]

print("== self-test: proving the validator discriminates before trusting its verdict ==")
self_test_failures = 0
for name, tree, must_validate in SELF_TESTS:
    error = first_error(tree)
    accepted = error is None
    if accepted == must_validate:
        verdict = "accepted" if accepted else "rejected"
        print(f"  ok    {verdict}: {name}")
    else:
        self_test_failures += 1
        wanted = "accept" if must_validate else "reject"
        got = "accepted" if accepted else "rejected"
        print(f"  BROKEN expected the schema to {wanted}, but it {got}: {name}")
        if error is not None:
            print(f"         {error.message}")

if self_test_failures:
    print()
    print(
        f"== validate-schema.sh: SELF-TEST FAILED ({self_test_failures} of {len(SELF_TESTS)}). "
        "The schema or this script is wrong, NOT the corpus. No fixtures were checked. =="
    )
    sys.exit(1)

print()
print("== validating every conformance case against schema/org-node.schema.json ==")

pass_count = 0
failed_cases = []

# Sorted, stable order -- the same ordering verify-corpus.sh and CorpusLoader.conformanceCases()
# use, so a failure here cross-references directly against a `swift test` run.
for case_dir in sorted(p for p in conformance_dir.iterdir() if p.is_dir()):
    case_name = case_dir.name
    expected_json = case_dir / "expected.json"

    if not expected_json.is_file():
        print(f"FAIL  {case_name} (missing expected.json)")
        failed_cases.append(case_name)
        continue

    try:
        tree = json.loads(expected_json.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        print(f"FAIL  {case_name} (expected.json is not valid JSON: {exc})")
        failed_cases.append(case_name)
        continue

    error = first_error(tree)
    if error is None:
        print(f"PASS  {case_name}")
        pass_count += 1
    else:
        location = "/".join(str(part) for part in error.absolute_path) or "(root)"
        print(f"FAIL  {case_name} (does not validate against the published schema)")
        print(f"      at {location}: {error.message}")
        failed_cases.append(case_name)

total = pass_count + len(failed_cases)
print()
print(f"== validate-schema.sh: {pass_count}/{total} valid, {len(failed_cases)} invalid ==")

if failed_cases:
    print(f"Invalid cases: {' '.join(failed_cases)}")
    sys.exit(1)

sys.exit(0)
PYTHON_VALIDATOR
