#!/usr/bin/env python3
"""Accuracy grader: run each parser's adapter over the corpora and diff against the
reference trees (schema/org-node.schema.json shape, org-element's answers).

    python3 bench/accuracy/grade.py [--parser P ...] [--corpus C ...] [--out DIR]

Parsers:  organism  uniorg  orgize  go-org  org-element
Corpora:  conformance (conformance/*/input.org vs expected.json)
          real        (real/**/*.org vs a cached org-element oracle dump)
          sweep       (sweep/cases/*.org vs sweep/expected/*.json)

Verdicts, most severe wins:
  crash             adapter exited non-zero, emitted unparseable JSON, or timed out
  cannot-represent  strict diff failed AND the reference tree needs a node type or field
                    the parser's own AST has no slot for (per-parser marker list below);
                    the miss is an AST-capability gap, not a parse bug
  wrong-tree        strict diff failed on information the parser's AST does claim to carry
  pass-structure    strict diff failed ONLY on blank-run bookkeeping (postBlank/preBlank);
                    tree matches after stripping those fields from both sides
  pass              byte-identical tree after canonical key ordering

Every failed case is re-checked under the structure comparison too, so the summary's
"structure" column = pass + pass-structure + the cannot-represent/wrong-tree cases that
match structurally.

Build the adapters first (each lives beside its speed runner, sharing the same pinned
dependency, so accuracy grades exactly the build the speed table times):
  swift build -c release --package-path bench
  cd bench/competitors/orgize  && cargo build --release --bin orgize-adapter
  cd bench/competitors/go-org  && go build -o go-org-adapter.bin ./adapter
  (uniorg adapter is bench/competitors/uniorg/adapt.mjs, no build step)
"""

import argparse
import copy
import datetime as _dt
import json
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
BENCH = os.path.join(ROOT, "bench")
CACHE = os.path.join(BENCH, "accuracy", ".cache")
TIMEOUT = 120

# ---------------------------------------------------------------- parser command lines

PARSERS = {
    "organism": lambda f: [os.path.join(BENCH, ".build", "release", "orgbench"), "json", f],
    "uniorg": lambda f: ["node", os.path.join(BENCH, "competitors", "uniorg", "adapt.mjs"), f],
    "orgize": lambda f: [os.path.join(BENCH, "competitors", "orgize", "target", "release", "orgize-adapter"), f],
    "go-org": lambda f: [os.path.join(BENCH, "competitors", "go-org", "go-org-adapter.bin"), f],
    "org-element": lambda f: [
        "emacs", "--batch", "-Q", "-l", os.path.join(ROOT, "harness", "oracle-dump.el"),
        "--eval", '(org-swift-dump "%s")' % f,
    ],
}

# ------------------------------------------------------- cannot-represent marker lists
#
# A marker fires when the REFERENCE tree for a case contains a node type or a populated
# field that the parser's own AST cannot express at all (checked against its published
# AST type definitions, and recorded in bench/accuracy/README.md). A fired marker
# reclassifies a strict failure from wrong-tree to cannot-represent. It never upgrades
# anything to a pass.


def _walk(node):
    yield node
    if isinstance(node, dict):
        for v in node.values():
            yield from _walk(v)
    elif isinstance(node, list):
        for v in node:
            yield from _walk(v)


def _nodes(tree):
    for n in _walk(tree):
        if isinstance(n, dict) and isinstance(n.get("type"), str):
            yield n


def _timestamp_extras(n):
    if n.get("type") != "timestamp":
        return None
    if n.get("rangeType") is not None:
        return "timestamp rangeType"
    if n.get("repeater") is not None:
        return "timestamp repeater"
    if n.get("delay") is not None:
        return "timestamp delay"
    if "diarySexp" in n:
        return "timestamp diary sexp"
    for side in ("start", "end"):
        d = n.get(side)
        if isinstance(d, dict) and d.get("dayname") is not None:
            return "timestamp dayname"
    return None


UNIORG_TYPES = {
    "dynamic-block", "inline-src-block", "inline-babel-call", "babel-call",
    "macro", "target", "radio-target",
}


def uniorg_markers(tree):
    for n in _nodes(tree):
        t = n["type"]
        if t in UNIORG_TYPES:
            yield "node type " + t
        m = _timestamp_extras(n)
        if m:
            yield m
        if t == "example-block" and n.get("switches") is not None:
            yield "example-block switches"
        if t == "special-block" and n.get("parameters") is not None:
            yield "special-block parameters"
        if t == "link" and n.get("pathType") == "radio":
            yield "radio link"
        if t == "table" and n.get("affiliated"):
            yield "affiliated keywords on a table"


ORGIZE_TYPES = {
    "entity", "latex-fragment", "latex-environment", "subscript", "superscript",
    "line-break", "citation", "citation-reference", "diary-sexp",
}


def orgize_markers(tree):
    for n in _nodes(tree):
        t = n["type"]
        if t in ORGIZE_TYPES:
            yield "node type " + t
        if t == "link":
            # orgize 0.9 stores no :type equivalent (pathType) and matches only bracket
            # links, so angle/plain/radio forms have no slot either
            yield "link pathType"
        if t == "timestamp" and n.get("rangeType") is not None:
            yield "timestamp rangeType"
        if t == "item":
            if n.get("checkbox") is not None:
                yield "item checkbox"
            if n.get("counter") is not None:
                yield "item counter"
            if n.get("tag") is not None:
                yield "item tag (descriptive list)"
        if t == "list" and n.get("kind") == "descriptive":
            yield "descriptive list"
        if t == "headline" and n.get("commented"):
            yield "commented headline"
        if t == "src-block" and n.get("switches") is not None:
            yield "src-block switches (fused into arguments)"
        if t == "footnote-definition" and n.get("preBlank"):
            yield "footnote-definition preBlank"
        if n.get("affiliated"):
            yield "affiliated keywords (no attachment in AST)"


GO_ORG_TYPES = {
    "babel-call", "inline-babel-call", "citation", "citation-reference", "entity",
    "export-snippet", "radio-target", "target", "diary-sexp", "clock", "planning",
    "dynamic-block",
}

GO_ORG_AFFILIATED_KEYS = {"CAPTION", "NAME", "ATTR_HTML"}


def go_org_markers(tree):
    for n in _nodes(tree):
        t = n["type"]
        if t in GO_ORG_TYPES:
            yield "node type " + t
        if t == "timestamp":
            if n.get("kind") != "active":
                yield "timestamp kind %s (only the active <...> form is parsed)" % n.get("kind")
            if n.get("end") is not None:
                yield "timestamp range"
            if n.get("delay") is not None:
                yield "timestamp delay"
            d = n.get("start")
            if isinstance(d, dict) and d.get("dayname") is not None:
                yield "timestamp dayname (normalized through time.Time)"
        if t == "headline" and n.get("commented"):
            yield "commented headline"
        if t == "item" and n.get("counter") is not None:
            yield "item counter"
        if t in ("headline", "item", "footnote-definition") and n.get("preBlank"):
            yield "preBlank"
        if t == "src-block" and n.get("switches") is not None:
            yield "src-block switches (fused into the language token)"
        if t == "table" and "value" in n:
            yield "table.el table"
        if t in ("subscript", "superscript") and n.get("useBrackets") is False:
            yield "bare (unbraced) sub/superscript"
        if t == "link" and n.get("linkType") == "angle":
            yield "angle link"
        for entry in n.get("affiliated") or []:
            if not isinstance(entry, dict):
                continue
            if entry.get("key") not in GO_ORG_AFFILIATED_KEYS:
                yield "affiliated key " + str(entry.get("key"))
            if entry.get("key") == "CAPTION":
                for v in entry.get("value") or []:
                    if isinstance(v, dict) and v.get("short") is not None:
                        yield "dual CAPTION[short]"


MARKERS = {
    "organism": lambda tree: iter(()),
    "org-element": lambda tree: iter(()),
    "uniorg": uniorg_markers,
    "orgize": orgize_markers,
    "go-org": go_org_markers,
}

# ---------------------------------------------------------------------------- corpora


def conformance_cases():
    base = os.path.join(ROOT, "conformance")
    for name in sorted(os.listdir(base)):
        d = os.path.join(base, name)
        inp, exp = os.path.join(d, "input.org"), os.path.join(d, "expected.json")
        if os.path.isfile(inp) and os.path.isfile(exp):
            yield name, inp, exp


def sweep_cases():
    cases = os.path.join(ROOT, "sweep", "cases")
    expected = os.path.join(ROOT, "sweep", "expected")
    for f in sorted(os.listdir(cases)):
        if f.endswith(".org"):
            name = f[: -len(".org")]
            exp = os.path.join(expected, name + ".json")
            if os.path.isfile(exp):
                yield name, os.path.join(cases, f), exp


def real_cases():
    """Real files graded against a cached org-element dump (the oracle mints the answer)."""
    files = []
    base = os.path.join(ROOT, "real")
    for sub in sorted(os.listdir(base)):
        d = os.path.join(base, sub)
        if not os.path.isdir(d):
            continue
        for f in sorted(os.listdir(d)):
            if f.endswith(".org"):
                files.append((sub + "/" + f, os.path.join(d, f)))
    os.makedirs(os.path.join(CACHE, "real-expected"), exist_ok=True)
    for name, path in files:
        exp = os.path.join(CACHE, "real-expected", name.replace("/", "__") + ".json")
        if not os.path.isfile(exp):
            r = subprocess.run(
                PARSERS["org-element"](path), capture_output=True, timeout=600)
            if r.returncode != 0:
                raise RuntimeError("oracle failed on %s: %s" % (path, r.stderr.decode()[:400]))
            json.loads(r.stdout)  # unreadable oracle output must be fatal, not cached
            with open(exp, "wb") as fh:
                fh.write(r.stdout)
        yield name, path, exp


CORPORA = {"conformance": conformance_cases, "real": real_cases, "sweep": sweep_cases}

# ----------------------------------------------------------------------------- grading


def strip_blanks(tree):
    t = copy.deepcopy(tree)
    for n in _walk(t):
        if isinstance(n, dict):
            n.pop("postBlank", None)
            n.pop("preBlank", None)
    return t


def grade_case(parser, inp, expected):
    try:
        r = subprocess.run(PARSERS[parser](inp), capture_output=True, timeout=TIMEOUT)
    except subprocess.TimeoutExpired:
        return "crash", "timeout after %ss" % TIMEOUT
    if r.returncode != 0:
        return "crash", "exit %d: %s" % (r.returncode, r.stderr.decode("utf-8", "replace").strip()[:200])
    try:
        actual = json.loads(r.stdout)
    except json.JSONDecodeError as e:
        return "crash", "unparseable JSON: %s" % e
    if actual == expected:
        return "pass", ""
    structure = strip_blanks(actual) == strip_blanks(expected)
    if structure:
        return "pass-structure", "postBlank/preBlank bookkeeping only"
    markers = sorted(set(MARKERS[parser](expected)))
    if markers:
        return "cannot-represent", "; ".join(markers[:4])
    return "wrong-tree", first_divergence(expected, actual)


def first_divergence(exp, act, path="$"):
    if type(exp) is not type(act):
        return "%s: %s vs %s" % (path, _short(exp), _short(act))
    if isinstance(exp, dict):
        for k in sorted(set(exp) | set(act)):
            if k not in act:
                return "%s.%s missing" % (path, k)
            if k not in exp:
                return "%s.%s unexpected" % (path, k)
            if exp[k] != act[k]:
                return first_divergence(exp[k], act[k], "%s.%s" % (path, k))
        return path
    if isinstance(exp, list):
        for i, (e, a) in enumerate(zip(exp, act)):
            if e != a:
                return first_divergence(e, a, "%s[%d]" % (path, i))
        if len(exp) != len(act):
            return "%s: length %d vs %d" % (path, len(exp), len(act))
        return path
    return "%s: %s vs %s" % (path, _short(exp), _short(act))


def _short(v):
    s = json.dumps(v, ensure_ascii=False)
    return s if len(s) <= 80 else s[:77] + "..."


BY_CONSTRUCTION = {("org-element", "real"), ("org-element", "sweep")}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--parser", action="append", choices=sorted(PARSERS), default=None)
    ap.add_argument("--corpus", action="append", choices=sorted(CORPORA), default=None)
    ap.add_argument("--out", default=None)
    args = ap.parse_args()
    parsers = args.parser or ["organism", "uniorg", "orgize", "go-org", "org-element"]
    corpora = args.corpus or ["conformance", "real", "sweep"]
    out = args.out or os.path.join(
        BENCH, "results", "accuracy-" + _dt.date.today().isoformat())
    os.makedirs(out, exist_ok=True)

    summary = []
    for corpus in corpora:
        cases = list(CORPORA[corpus]())
        for parser in parsers:
            if (parser, corpus) in BY_CONSTRUCTION:
                # The reference trees for this corpus are themselves org-element output
                # (regenerated from the oracle), so this cell is a tautology, not a result.
                summary.append((parser, corpus, "by construction", len(cases), None))
                continue
            counts = {}
            rows = []
            for name, inp, exp_path in cases:
                with open(exp_path, "rb") as fh:
                    expected = json.load(fh)
                verdict, note = grade_case(parser, inp, expected)
                counts[verdict] = counts.get(verdict, 0) + 1
                rows.append("%s\t%s\t%s" % (name, verdict, note))
                if len(rows) % 200 == 0:
                    print("  ... %s/%s: %d/%d" % (parser, corpus, len(rows), len(cases)),
                          file=sys.stderr)
            tsv = os.path.join(out, "%s-%s.tsv" % (parser, corpus))
            with open(tsv, "w") as fh:
                fh.write("case\tverdict\tnote\n" + "\n".join(rows) + "\n")
            summary.append((parser, corpus, counts, len(cases), tsv))
            print("%-12s %-12s %s" % (parser, corpus, fmt_counts(counts, len(cases))))

    print("\n== summary ==")
    for parser, corpus, counts, total, _ in summary:
        if counts == "by construction":
            print("%-12s %-12s %d/%d (by construction: reference IS this parser's output)"
                  % (parser, corpus, total, total))
        else:
            print("%-12s %-12s %s" % (parser, corpus, fmt_counts(counts, total)))


def fmt_counts(counts, total):
    strict = counts.get("pass", 0)
    structure = strict + counts.get("pass-structure", 0)
    rest = ", ".join(
        "%s %d" % (k, v)
        for k, v in sorted(counts.items())
        if k not in ("pass", "pass-structure") and v)
    return "strict %d/%d, structure %d/%d%s" % (
        strict, total, structure, total, (", " + rest) if rest else "")


if __name__ == "__main__":
    main()
