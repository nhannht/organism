# Accuracy leaderboard - 2026-08-08

Every parser graded against org-element's own answers on the three corpora, through
`bench/accuracy/grade.py` (protocol and fairness rules: `bench/accuracy/README.md`).
`strict` = tree identical to the reference; `structure` additionally admits trees that
match after stripping the `postBlank`/`preBlank` blank-run bookkeeping.

| parser | conformance (121) | real files (28) | sweep (1,505) |
|---|---|---|---|
| **organism** (this repo) | **121** strict | **28** strict | **1,505** strict |
| org-element (control) | 121 strict, live run | by construction | by construction |
| uniorg-parse 3.2.2 | 81 strict / 81 structure | 13 / 17 | 693 / 698 |
| orgize 0.9.0 | 67 / 68 | 2 / 3 | 402 / 404 |
| go-org v1.7.0 | 59 / 59 | 1 / 1 | 479 / 479 |

Failure taxonomy (strict failures split into cannot-represent / wrong-tree / crash;
definitions in `bench/accuracy/README.md`):

| parser | corpus | cannot-represent | wrong-tree | crash |
|---|---|---|---|---|
| uniorg | conformance | 29 | 11 | 0 |
| uniorg | real | 4 | 7 | 0 |
| uniorg | sweep | 650 | 157 | 0 |
| orgize | conformance | 44 | 9 | 0 |
| orgize | real | 24 | 1 | 0 |
| orgize | sweep | 562 | 539 | 0 |
| go-org | conformance | 44 | 18 | 0 |
| go-org | real | 14 | 13 | 0 |
| go-org | sweep | 816 | 210 | 0 |

Per-case verdicts with the first divergence pinned: the `<parser>-<corpus>.tsv` files
beside this summary.

## Reading the table

- The org-element row is the control, not a competitor. Its conformance run is LIVE
  (121 fresh `emacs --batch -Q` parses today) and doubles as the fixture drift check:
  the committed answer key still matches Emacs 30.2 / org 9.7.11 exactly. Its other two
  cells are tautologies (those reference trees are generated from it) and are skipped.
- organism's rows go through the same external pipeline as every competitor
  (`orgbench json` output diffed by the same script), not through its own test suite.
- `cannot-represent` means the reference tree needs a node type or field the
  competitor's published AST has no slot for - an API-capability gap, distinct from a
  parse bug. Examples: uniorg drops timestamp daynames/repeaters and has no
  dynamic-block/macro/target node types; orgize 0.9 stores no link `:type` and no
  affiliated keywords; go-org parses only the active `<...>` timestamp form and holds
  no blank-line information at all.
- `wrong-tree` failures were spot-audited by hand and trace to reproducible competitor
  parse divergences (lowercase `[x]` checkboxes accepted, `#+STARTUP: odd` ignored,
  `<2026-01-01 Thu +1w>` rejected, multiple `#+TBLFM:` lines concatenated or lost, ...).

## Environment

- Emacs 30.2 / org-mode 9.7.11 (the oracle), Swift 6.3.3, Node 26.5, Rust (orgize 0.9.0
  via Cargo.lock), Go (go-org v1.7.0 via go.sum) - each adapter shares its speed
  runner's pinned dependency, so this table grades exactly the builds the speed
  benchmark times.

## Reproduce

```bash
swift build -c release --package-path bench
(cd bench/competitors/orgize && cargo build --release --bin orgize-adapter)
(cd bench/competitors/go-org && go build -o go-org-adapter.bin ./adapter)
python3 bench/accuracy/grade.py --out bench/results/accuracy-2026-08-08
```
