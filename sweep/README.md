# `sweep/` - the generated differential corpus

1,312 inputs, each with org's own answer stored beside it. Run automatically by `swift test`
via `Tests/OrgSwiftTests/SweepTests.swift`.

```
sweep/cases/<name>.org        the input
sweep/expected/<name>.json    org's answer, from harness/oracle-dump.el
sweep/regen-expected.sh       rebuild every answer from this repo's own oracle
sweep/gen/                    the probe generators the cases came from
```

## Why this exists when `conformance/` already does

`conformance/` and `harness/verify-corpus.sh` prove **non-drift**: the parser still agrees with
checked-in trees the oracle generated. Neither can see an input the corpus does not contain, and
the corpus contains only inputs somebody thought to write down.

The sharper problem is that `withKnownIssue` records a THROW and a WRONG TREE **identically**.
Both stay green. That is measured, not assumed: a wrapped file that MATCHES records a real
failure, while a wrapped file that MISMATCHES records only a known issue. So a wrapped case that
starts emitting a wrong tree is indistinguishable from one that is merely unimplemented, and it
can stay that way indefinitely. SCHEMA.md section 8 is the same asymmetry from the other side.

This corpus reports **three** states where the rest of the repository reports two:

```
MATCH      the parser's tree equals org's
MISMATCH   the parser emitted a tree org does not produce   <- a WRONG TREE, right now
THROW      the parser refused
```

and the test enforces the invariant `parseOrg`'s own doc comment states: never emit a tree it is
not confident is correct.

**A MISMATCH fails the build. A THROW does not.** Over-throwing costs a construct; a wrong tree
costs trust in every tree the parser produces, and only one of those is allowed to be silent.

Nine defects were found by this instrument - ORG-22 through ORG-30, plus the citation-prefix
restriction row found by the Wave 3 generator - five of them live in the published repository at
the time. Not one was visible to `swift test`,
`harness/verify-corpus.sh`, or the 80 conformance fixtures.

## What a zero here does NOT mean

"1,312 inputs, 0 mismatches" is **not a correctness proof** and must never be quoted as one.

It means: no disagreement with org on inputs someone THOUGHT TO CONSTRUCT. This corpus is the
product of one reviewer's guesses about where the parser might be wrong. Every defect it found was
found by probing somewhere nobody had probed before, and there is no reason to believe that
process is exhausted.

THREE times now the count has read zero, a new group of cases has been added, and wrong trees
that were present all along appeared immediately. The first two took it from 0 to 14 with no
change to the parser. The third was `sweep/gen/gen-wave3-containers.py`, whose very first run
found four -- a citation's own prefix and suffix were lexed under the wrong restriction row,
in code that had landed an hour earlier and passed every other gate.

Quote the count and this section together, or neither.

## The known-wrong list is a list of names, not a wrapper

`SweepTests.knownWrongTrees` names the cases that produce a wrong tree today. All of them are
**ORG-28**.

This is deliberately not `withKnownIssue`. A blanket wrapper absorbs any number of new wrong trees
silently; a list of names absorbs exactly those names. A thirty-first wrong tree fails the run, and
a listed case that starts MATCHING also fails the run - which is what forces the name back out
when the defect is fixed.

**Adding a name to make a red run green is always the wrong fix.** A new entry means a wrong tree
was introduced; fix it or revert.

## Regenerating

```sh
sweep/regen-expected.sh              # all of them
sweep/regen-expected.sh caption-bold # or just some
```

Answers are rebuilt from `harness/oracle-dump.el`, this repository's own oracle. Nothing in
`sweep/` is the source of an expected answer, so a reader never has to trust the checked-in
files - rebuild them and diff.

That diff is also the drift guard for the corpus itself. Run it against a clean tree and
`git diff`: empty means the stored answers still match live Emacs. Non-empty means either org
changed under us or an answer was hand-edited.

**Never hand-edit a file in `expected/`.** It is org's answer, not ours. If the parser disagrees
with it, either the parser is wrong or org's behaviour changed; editing the answer to match the
parser destroys the only independent signal in the directory.

## `gen/`

The probe generators the cases came from, each carrying its derivation and result counts in its
own header. Several enumerate the whole Unicode scalar space against live Emacs and are the
regeneration path for the four pinned tables in `ParserPrimitives.swift` - see ORG-17. The large
intermediate dumps they produce are not checked in; they are reproducible by running the
generators.

## Requirements

Emacs with org-mode, same as `harness/verify-corpus.sh`. The Swift test needs no Emacs: it
compares against the stored answers, so it runs anywhere.

Measured on Emacs 30.2 / org-mode 9.7.11.
