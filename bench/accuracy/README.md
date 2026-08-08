# Accuracy grading: every parser against org-element's own answers

This directory grades org parsers - this repo's own included - against the reference trees
of the conformance suite: `conformance/*/expected.json`, the 1,505-case differential sweep
(`sweep/`), and an org-element oracle dump of every vendored real-world file (`real/`).
The speed side of the benchmark lives in `bench/README.md`; this is the accuracy side.
`ADAPTER.md` at the repo root is the general contract this directory instantiates per
competitor.

Run it:

```bash
swift build -c release --package-path bench
(cd bench/competitors/orgize && cargo build --release --bin orgize-adapter)
(cd bench/competitors/go-org && go build -o go-org-adapter.bin adapter.go)
python3 bench/accuracy/grade.py            # all parsers, all corpora
python3 bench/accuracy/grade.py --parser uniorg --corpus conformance
```

Results land in `bench/results/accuracy-<date>/` as one TSV per parser per corpus plus the
summary printed at the end. `.cache/` holds the oracle dumps for `real/` and is gitignored.

## The adapters

Each competitor gets a thin adapter that parses a file with the competitor's own published
API and re-encodes ITS AST into this repo's schema shape (`schema/org-node.schema.json`).
Each adapter lives beside that competitor's speed runner and shares its pinned dependency
(`pnpm-lock.yaml` / `Cargo.lock` / `go.sum`), so the accuracy table grades exactly the
build the speed table times:

| parser | version | adapter |
|---|---|---|
| organism | this repo | `bench/Sources/orgbench` (`orgbench json`) |
| uniorg | uniorg-parse 3.2.2 | `bench/competitors/uniorg/adapt.mjs` |
| orgize | 0.9.0 | `bench/competitors/orgize/src/bin/adapter.rs` |
| go-org | 2f088a1 | `bench/competitors/go-org/adapter.go` |
| org-element | Emacs 30.2 / org 9.7.11 | `harness/oracle-dump.el` (the oracle itself) |

org-element is the control row, not a competitor: the reference trees ARE its output
(`sweep/expected/` and the `real/` cache are generated from it, and `conformance/`'s
fixtures were minted by it), so its non-conformance cells are tautologies and are reported
as "by construction". Its live conformance run is still worth having - it is the drift
check that the committed fixtures still match today's Emacs.

## Fairness rules (what an adapter may and may not do)

The point of the leaderboard is that a failure means THE PARSER got the document wrong,
never that the adapter was lazy. Every adapter follows the same rules:

1. **Re-encode, never re-parse.** The adapter maps the competitor's emitted AST. It never
   runs its own org parsing over the source text or over raw-value string fields the
   competitor stored (`rawValue`, `rawLink` used as-is is fine; EXTRACTING the sexp out of
   a diary `rawValue` is not).
2. **Position arithmetic is allowed.** Where the competitor emits node positions, the
   adapter may derive whitespace bookkeeping from them - org-element's `postBlank`/
   `preBlank` counts, brace-vs-bare `useBrackets` - by counting whitespace bytes in the
   gaps between the competitor's own node extents. Those scalars are encoded by the
   positions the parser itself claims. Copying non-whitespace source bytes into the tree
   is never allowed.
3. **Lossless re-encodings are the adapter's job.** Type/enum renames, restructuring an
   equivalent nesting (uniorg's inverted section/headline shape), moving whitespace a
   competitor stores at the head of the next text node onto the previous object's
   `postBlank` (org-element's own canonical form of the same bytes), assembling a raw
   value the schema wants from the exact captured fields it splits into. Where org-element
   itself normalizes (keyword names upcased), applying the same pure normalization to the
   competitor's captured field is allowed.
4. **As shipped, default configuration.** Each parser runs exactly as its speed runner
   runs it. If a parser leaves in-buffer configuration (`#+TODO:`, `#+STARTUP:`) for the
   caller to supply as options, the adapter does not compensate - org-element `-Q` reads
   those lines itself, and doing so is part of parsing org.
5. **Missing information is emitted honestly** - null/absent, never guessed - and graded
   as a failure with the taxonomy below saying why.

## Verdicts

- `pass` - tree identical to the reference (canonical key order, structural compare).
- `pass-structure` - identical after stripping `postBlank`/`preBlank` from both sides;
  the parser got the whole tree right except blank-run bookkeeping. The summary's
  "structure" score counts `pass` + `pass-structure`.
- `cannot-represent` - failed, and the reference tree needs a node type or field that has
  no slot in the competitor's published AST (the per-parser marker lists in `grade.py`).
  This is an AST-capability gap, not a parse bug; conflating the two would overstate how
  wrong the competitor's parsing is.
- `wrong-tree` - failed on information the competitor's AST does claim to carry. The TSV
  note pins the first divergence.
- `crash` - non-zero exit, unparseable output, or timeout.

A case classifies as `cannot-represent` when ANY marker fires, even if it also has
ordinary divergences - the verdict is a taxonomy of failures, not a partial credit. The
headline number for every parser is strict passes.

## Per-adapter judgment calls (recorded, not hidden)

- **uniorg** parses affiliated captions' short form into a plain string where org-element
  parses objects; the adapter wraps it as a single text node, so a markup-bearing short
  caption fails honestly. An item's swallowed bullet-line whitespace is moved into
  `preBlank`/`postBlank` per org-element's measured conventions (see the comments in
  `adapt.mjs`), and a paragraph that held nothing but that structural whitespace is
  dropped - org-element emits no node for it. uniorg exposes `todoKeywords` as a parse
  option; per rule 4 it is not supplied, so in-buffer `#+TODO:` cases grade as parsed.
- **orgize** stores a source block's switches and header arguments as ONE `arguments`
  string; the schema splits them. Splitting is org grammar, so the adapter emits the
  string as `params` and `switches: null`, and the marker list flags every case whose
  reference needs the split. Repeater/delay cookies are stored as raw strings (`"+1w"`);
  decomposing that already-isolated token into `{type, value, unit}` is a re-encode, not
  parsing, and is done.
- **go-org**: see the marker list in `grade.py` beside its adapter.

Verdicts were spot-audited by hand: every conformance `wrong-tree` for uniorg was traced
to a reproducible uniorg parse divergence (lowercase `[x]` accepted as a checkbox,
`#+STARTUP: odd` not honored, `$...$` accepted where org rejects, trailing newline
truncated from latex environments, tblfm lines concatenated, ...), not to adapter choices.
