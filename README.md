# organism

A language-agnostic conformance suite for Emacs org-mode, graded against `org-element`
(org-mode's own reference parser), plus one reference implementation of it in Swift.

## Current state (read this first)

This suite is real and usable today. The Swift parser is real and PARTIAL.

- `parseOrg` parses a growing subset and refuses the rest honestly. On the 82 conformance
  cases it produces a tree matching `org-element`'s own, node for node, on **81 of 82**. The one
  case it refuses (`todo-hidden-by-unterminated-example`) was added deliberately AHEAD of the
  parser: it pins the answer for a document whose block opener is broken by a headline, and it
  starts asserting the moment unpaired block openers stop throwing. On the
  13 vendored real-world files it is **5 of 13** - those files are dense, and one unimplemented
  construct anywhere in a file fails the whole file, so this number moves in jumps rather than
  one file at a time.
- `renderOrg` is real now, grown the same way. On the 82 conformance cases it re-emits
  `input.org` byte-for-byte from the checked-in tree on **81 of 82**. The case that used to be
  blocked on a schema decision about affiliated-keyword ordering asserts now - `affiliated`
  became an ordered array and the order became data. The permanent 82nd is its successor,
  `affiliated-interleaved-repeat`, which deliberately pins bytes NO tree built on `org-element`
  can carry (SCHEMA.md section 10, item 8; see
  `RendererConformanceTests.schemaLossCases`). Full-file round-trip
  `renderOrg(parseOrg(text))` stands at **5 of 13**: 2 files byte-exact, 3 more byte-exact
  modulo the SCHEMA.md section 10 losses they demonstrably hit, and the remaining 8 blocked on
  parsing, not rendering.
- **Implemented:** headlines with the two-pass `#+TODO:` keyword set, priority cookies, tag
  groups and COMMENT; sections, paragraphs, keywords and the affiliated-keyword grammar; the
  four literal block types, quote/center/verse, src and example switch grammars; pipe tables,
  `table.el` grids, fixed-width, lists; drawers and property drawers; dynamic blocks; links
  (regular, angle, plain, and radio with its document-wide target pass); timestamps (all five
  kinds); planning lines; footnote references and definitions; statistics cookies;
  subscript and superscript; latex fragments in their two bracket forms; and emphasis with
  org's border rules.
  **Still refused:** entities, `$...$` latex fragments, underline and strike-through, citations,
  macros, export snippets, targets, inline src blocks and babel calls, clock lines, diary sexps
  and latex environments. Underline and strike-through are a documented decision rather than an
  oversight, and they are the largest single reason the real-world figure is 5 rather than
  higher.
- `swift test` reports green, and the reason matters. Every case the parser cannot yet handle
  is wrapped in Swift Testing's `withKnownIssue`, so those are expected failures, not passes.
  See "What is verified" below for the exact split, and SCHEMA.md section 8 for how a wrapper
  is meant to be removed, case by case, as the parser grows.
- If you came here looking for a COMPLETE Swift org-mode parser, it is not here yet. What is
  here: a portable test corpus and harness that any parser in any language can run against,
  and a Swift parser that is honest about where it stops.
- The answer key this suite grades against has its own open risk: see "The oracle's answer key:
  the circularity remains, but it has now been audited" below before you adopt
  `conformance/*/expected.json` as ground truth.

## The numbers

Every figure below is reproducible from a clean clone. The two commands in the left column are
the whole verification story - run them yourself rather than taking this table's word for it.

| What | Result |
|---|---|
| `harness/verify-corpus.sh` | 82 of 82 cases pass, 0 fail |
| `swift test` | 17 tests, 8 suites, 0 failures, 51 known issues |
| Layer 1 conformance cases | 82 pairs of `input.org` + `expected.json` |
| Layer 2 real-world files | 13 vendored MIT files, from 2 sources |
| `sweep/` differential corpus | 1,208 inputs, 0 wrong trees - see `sweep/README.md` |
| `parseOrg` matches the oracle tree, conformance | 81 of 82 |
| `parseOrg` matches the oracle tree, real-world | 5 of 13 |
| `renderOrg` re-emits `input.org` from the tree | 81 of 82 |
| `renderOrg(parseOrg(text))` round-trip | 5 of 13 (2 byte-exact, 3 modulo annotated losses) |
| `org-element` types mapped by the oracle | 40 of 54 |
| Mapped types that also have a fixture | 38 of 40 |
| Byte-exact round-trip through `org-element` | 62 of 95 files |
| Documented round-trip losses | 10 - see SCHEMA.md section 10 |

Two of those numbers are easy to misread, so they are stated plainly here.

**51 known issues are not 51 passes, and they are not one thing either.** A case the parser
cannot yet handle is wrapped in `withKnownIssue`, so the run is green because those failures are
expected, not because they do not happen. **17 of the 51 are parser-shaped** - 1 conformance,
8 oracle diff, 8 round-trip - and those go to zero as the parser gets written; every one of the
8 remaining round-trip files is blocked on parsing, not rendering. **1 is renderer-shaped and
permanent by measurement** (`affiliated-interleaved-repeat` in
`RendererConformanceTests.schemaLossCases`: it pins an ordering fact `org-element` itself does
not store, so its render is correct AND can never equal its input - SCHEMA.md section 10 item
8). The other **33 belong to the `org-element-interpret-data` suite**, which measures org-mode's
own round-trip losses on its own parser. Writing a perfect Swift parser does not move that 33 at
all. The parser-shaped count goes DOWN as the parser grows and UP whenever a new fixture is
added ahead of it; both directions are correct - the 1 conformance entry is exactly such a
fixture, added ahead of the parser on purpose (see below).

**The conformance suite carries exactly one known issue, and it is deliberate.** 81 of the 82
cases assert normally. The wrapped one, `todo-hidden-by-unterminated-example`, is the fixture
the parser-run open-claims register specifies for its rows 2 and 6: a `#+begin_example` broken
by a headline, so the opener must NOT hide the `#+TODO:` line after it. `parseOrg` still
refuses unpaired block openers today, so the case cannot assert yet; the moment that refusal is
lifted, `withKnownIssue` itself goes red and forces the case into `implementedCases`, which is
the discriminating assertion the register was waiting for.
`withKnownIssue` records a THROW and a WRONG TREE identically, so a green suite has never been
evidence of correctness here - see SCHEMA.md section 8.

**`sweep/` is the answer to that last problem, and it is the only gate here that can fail on a
wrong tree.** 1,208 generated inputs, each with org's own answer stored beside it, reporting
three states rather than two: MATCH, MISMATCH (a wrong tree, right now) and THROW. A MISMATCH
fails the build; a THROW does not, because over-throwing costs a construct while a wrong tree
costs trust in every tree. Eight defects were found this way in one session - five of them live
in this repository at the time, none visible to `swift test`, `verify-corpus.sh` or the 80
fixtures. Its count is NOT a correctness proof and `sweep/README.md` says at length why.

**The 10 round-trip losses are two different things.** 8 are irreducible - the byte is not
recoverable from any tree built on `org-element`, so no parser on this foundation can fix them.
The other 2 are properties this schema declines to read, with the decision and its measured
reason recorded. SCHEMA.md section 10 splits them and says which is which. This list was 15 until
eight of the closable entries were closed by actually reading the properties they named; closing
them surfaced two losses nobody had looked for, and closing the affiliated-ordering gap (the
ordered array) surfaced a third - all three are now in the 8.

## What this is

Two things live in the same repository, and the split matters:

1. **The conformance suite** - `conformance/`, `real/`, `harness/`, `schema/`, `SCHEMA.md`,
   `ADAPTER.md`. Plain text (`.org`), JSON, and one Elisp script. No Swift toolchain, no Swift
   code, nothing to build. A parser author working in Rust, Go, Python, or anything else can use
   this suite without ever touching the rest of the repository.
2. **A Swift reference adapter** - `Sources/OrgSwift/`, `Tests/OrgSwiftTests/`, `Package.swift`.
   One implementation that plugs into the suite above. `parseOrg` handles a growing subset and
   refuses the rest; `renderOrg` re-emits any tree the schema can express and refuses malformed
   ones (see "Current state").

```
organism/
├── conformance/            Layer 1: 82 cases, each a pair of input.org + expected.json
├── real/                   Layer 2/3: 13 vendored MIT real-world .org files, 2 sources
├── harness/                Layer 3: oracle-dump.el (the Emacs oracle), fetch-corpus.sh
├── schema/                 formal JSON Schema for the tree shape (companion to SCHEMA.md)
├── SCHEMA.md               the authoritative tree-shape contract, written in prose
├── ADAPTER.md              how to point your own parser, in any language, at this suite
├── NOTICE.md               provenance and license for every vendored real-world file
│
├── Sources/OrgSwift/       one reference adapter, written in Swift - parseOrg is PARTIAL
│                           and renderOrg refuses what it cannot re-emit, see "Current state"
└── Tests/OrgSwiftTests/    wires the three layers above into `swift test`
```

## Why a conformance suite, not just unit tests

Org-mode has one authoritative reference implementation (`org-element.el`, inside Emacs) and one
authoritative written spec (Nicolas Goaziou's `org-syntax.html`), but no independent, portable
test suite that checks a new parser against either of them. Every existing parser project, in
any language, has so far only tested itself against its own idea of what org-mode does. This
suite checks against both: a hand-written corpus that pins down the spec's hard cases one rule
at a time, and real Emacs itself as a live oracle.

## The three layers

```
Layer 1: spec conformance          Layer 2: round-trip              Layer 3: oracle diff
(hand-written, one rule each)      (real-world files)                (real Emacs, live)

conformance/*/                    real/**/*.org                     harness/oracle-dump.el
  input.org                       real-fetched/** (optional)        -> org-element-parse-buffer
  expected.json  <- SCHEMA.md            |                                  |
       |                                 v                                  v
       v                          renderOrg(parseOrg(text))          parseOrg(text)
  parseOrg(input.org)                    |                                  |
       |                                 v                                  v
       v                          == text, byte-for-byte           == oracle's own JSON tree
  == expected.json (structural)
```

- **Layer 1, spec conformance** (`conformance/`): 82 small, hand-written `.org` fixtures, each
  isolating one rule from the spec - emphasis border rules, runtime `#+TODO:` keywords, list
  item boundaries, planning-line position, timestamps, and the rest of the cases where org-mode
  is genuinely hard. Each fixture's `expected.json` is the normalized tree a parser must
  produce for that input. This is the fastest, most precise layer: it tells you exactly which
  rule broke.
- **Layer 2, round-trip fidelity** (`real/`, plus `real-fetched/` if you run
  `harness/fetch-corpus.sh`): whole, unmodified real-world `.org` files (see NOTICE.md for
  exactly which files and where they came from). The assertion is
  `renderOrg(parseOrg(text)) == text`, byte-for-byte, with 10 documented exceptions - see
  "The round-trip loss contract" below.
- **Layer 3, oracle diff** (`harness/oracle-dump.el`): the same real-world files, parsed by
  actual Emacs (`org-element-parse-buffer`) and by your own parser, then compared structurally.
  This is the layer that catches a case where a project's own reading of the spec is subtly
  wrong - the referee is real org-mode, not any one project's understanding of it.

## The schema

`SCHEMA.md` is the full, authoritative shape: every node type, its fields, how objects nest
inside elements, and the specific rules a conformant parser has to encode (emphasis borders,
two-pass TODO keywords, block content modes, affiliated keywords, and more). `schema/` carries
the same contract as a formal JSON Schema. Read `SCHEMA.md` before writing a single line of
parser code against this suite - it is the contract all three layers check against.

## What is verified

Every number below was checked directly in this repository, on this commit, not assumed:

- 82 Layer 1 conformance cases in `conformance/`, each a matched `input.org` + `expected.json`
  pair.
- 13 vendored real-world `.org` files in `real/`, across 2 sources
  (`org-mode-samples/`, `doomemacs-docs/`), each with its own `LICENSE` file copied alongside it.
- `swift test` on this commit: 17 tests, 8 suites, 0 real failures, 51 known issues: 17
  parser-shaped, 1 renderer pin that is permanent by measurement (section 10 item 8), and 33
  org-mode `interpret-data` losses.
- 1,208 `sweep/` inputs on this commit: 0 wrong trees. The 30 cases that DO produce one are
  named individually in `SweepTests.knownWrongTrees` and are all ORG-28; a thirty-first fails
  the build. Read `sweep/README.md` before quoting that zero anywhere.
- `parseOrg` on this commit: 81 of 82 conformance cases produce a tree matching the oracle's,
  5 of 13 real-world files. `renderOrg` on this commit: 81 of 82 conformance cases re-emitted
  byte-for-byte from the checked-in tree, and full round-trip on 5 of 13 real files (2
  byte-exact, 3 modulo their annotated section 10 losses). Measured by reading the per-suite
  known-issue counts off the run, not inferred from the total.
- `harness/verify-corpus.sh` on this commit: 82/82 conformance cases pass (a runnable reference
  adapter that uses the Emacs oracle itself as the stand-in parser).
- Every `conformance/*/expected.json` fixture validates against `schema/org-node.schema.json`:
  82/82 valid, 0 invalid (see `schema/README.md` for how to run this check yourself). The
  rewritten `affiliated` def was also shown able to fail: the old object container, a
  wrong-typed `HEADER` value, and an unknown key are each rejected, while entry order is
  correctly shape-valid in any order (order correctness belongs to the corpus comparison).
- Emacs 30.2, org-mode 9.7.11, confirmed installed. `harness/oracle-dump.el` runs clean against
  it on all 82 conformance inputs: valid JSON, zero unmapped `org-element` node types, and
  exactly one case emitting anything on stderr - `table-el-flavour`, which warns by design.
  Measured by re-running the sweep with stderr captured per case. This was checked by running the script directly against each input file, not inferred
  from a passing test run - see the next section for why that distinction matters here.

## Type coverage: what the oracle maps today

Org-mode defines 54 distinct `org-element` node types in total (30 elements, 24 objects).
`harness/oracle-dump.el` maps 40 of those 54 today, plus two branches that sit outside either
official list: `org-data` (the parse-tree root) and `plain-text` (the bare-string branch). 14
types are not yet mapped. (`radio-target` left this list recently, mapped because a radio link
cannot be fixtured without a target in the same buffer - see the round-trip loss section.)

Ranked below by how likely your own `.org` files contain one, not by anything about the code
itself:

Likely - assume an ordinary file will contain one of these:
- `clock` - any file using time tracking, any `:LOGBOOK:` drawer.
- `entity` - any backslash word, e.g. `\alpha`, `\to`, `\ldots`, `\nbsp`.
- `special-block` - `#+begin_aside`, `#+begin_note`, `#+begin_warning`, `#+begin_tip`.
- `macro` - `{{{title}}}`, `{{{date}}}`, `{{{author}}}`.
- `latex-environment` - `\begin{equation}...`, any math or academic file.
- `target` - `<<anchor>>` internal link targets.

Common within specific communities:
- `inline-src-block`, `babel-call`, `inline-babel-call` - literate-programming and Babel users.
- `export-snippet` - `@@html:...@@`, export-heavy users.
- `inlinetask` - requires the `org-inlinetask` extension.

Genuinely rare:
- `citation`, `citation-reference` - `[cite:@key]`, `org-cite` (a growing but still niche
  extension).
- `diary-sexp` - `%%(diary-...)`.

None of these 14 types, and no `table.el`-style table (see below), occurs anywhere in the 82
conformance inputs or the 13 vendored real-world files. This disclosure is about what happens
when you point the oracle at your own files - the shipped corpus is unaffected either way.

### What actually happens when the oracle meets one of these

Tested directly against the current script, invoking the oracle the way a reader would and
checking exit code, stdout, and stderr: all 14 exit 0 and produce valid, parseable JSON. None of
them crash the script. Each produces a stderr warning naming the unmapped type - checked
directly, e.g. a synthetic file containing a `special-block` and an `entity` produces exactly
the two expected warnings - which a plain stdout redirect throws away, so validating the output
against `schema/org-node.schema.json` is what actually catches an unmapped type in practice; a
`"type"` string outside the schema's known set fails validation immediately.

What survives in the fallback node's own JSON differs by what `org-element` itself stores as
that type's `:value`, confirmed directly for all 15:

- Eight types carry a plain string `:value`, so that raw text survives in the JSON `value` field:
  `macro`, `target`, `latex-environment`, `inline-src-block`, `export-snippet`,
  `babel-call`, `inline-babel-call`, `diary-sexp`. Wrapping syntax `org-element` itself already
  strips before this schema ever sees `:value` - delimiters, the source-block language tag, the
  export backend name - does not come back with it.
- Five types carry no `:value` at all (`org-element` tracks them as containers instead):
  `entity`, `special-block`, `citation`, `citation-reference`, `inlinetask`. The fallback dumps
  their children as usual, so nested content (a paragraph inside a `special-block`, a reference
  inside a `citation`) survives structurally, but the node's own identity - which special block,
  which citation style - is gone. A bare `entity` with no children of its own (`\alpha`),
  confirmed live, comes back as `{"type":"entity","children":[],"postBlank":1}` - an empty
  `children` array and a `postBlank` count, no trace of which entity it was.
- One type, `clock`, carries a `:value` that is neither a plain string nor empty - a whole
  nested timestamp - so the fallback omits it entirely rather than guess at its shape, firing a
  second, more specific stderr warning and reporting a bare `{"type":"clock", ...}` node with no
  `value` and no `children` key at all.

### `table.el` tables: a fixed defect, and a deliberate limit that remains

`table.el`-style ASCII tables (a `+---+` grid, distinct from org's native `| a | b |` row
syntax) are not one of the 14 unmapped types above - they are the mapped `table` type, with
`:type 'table.el`. This used to be the single most dangerous gap this suite found: the mapped
branch ignored `:type` entirely and emitted `{"type":"table","children":[]}` for a `table.el`
table - valid JSON, exit 0, no warning, passing schema validation, while every byte of the table
was gone. That is fixed: a `table.el` table now fires a loud stderr warning and its raw text
survives verbatim in a `value` field instead, confirmed directly against the current script.
What remains, by design rather than by defect, is that `table.el` content is still not
structurally parsed into `table-row`/`table-cell` nodes - `org-element` itself never
decomposes a `table.el` table that way either, and this schema does not claim to represent one
as a structured table. The raw text is preserved; the grid structure is not modeled.

## The oracle's answer key: the circularity remains, but it has now been audited

`harness/oracle-dump.el`'s own file header used to say `STATUS: UNTESTED`. That is fixed: the
oracle has been run live for real, and that live run found and fixed two genuine bugs before
this corpus's `expected.json` fixtures were first regenerated from it - a spurious `"type"` key
on nested `date`/`rep` objects, and a UTF-8 double-encoding bug in the script's own `princ`
output (see SCHEMA.md section 9).

Even so, do not read a passing `swift test` as proof the oracle is correct. Every one of the 82
`conformance/*/expected.json` fixtures is generated BY running `oracle-dump.el` itself, so
`OracleConformanceCrossCheckTests` compares the oracle against a snapshot of its own prior
output, not against anything independent. A green run there proves only that
`oracle-dump.el`'s output for these 82 cases has not drifted since the fixtures were minted -
across an Emacs or org-mode version bump, or a future edit to the script. It says nothing, on
its own, about whether that output is actually correct org-mode behavior. This circularity is
real, and it still stands today.

What has changed is the compensating control this section used to describe as outstanding: a
focused human review of `oracle-dump.el`'s per-type property mappings against `org-element`'s
own source. That review has now been carried out - it is the one thing the circular cross-check
could never supply on its own - and it produced 22 findings, ranked and published in full in
`AUDIT.md`. 3 were critical, and all 3 are fixed, each reproduced live before the fix:

- Any file containing a `CLOCK:` line crashed the dump entirely. The generic fallback for an
  unmapped type assumed its `:value` was always a string; `clock`'s own `:value` is a whole
  nested timestamp instead. `clock` now degrades loudly - a stderr warning and a content-less
  node - instead of crashing. See "Type coverage" above for the exact current behavior.
- `entity` lost its content and additionally fabricated an affiliated keyword out of thin air:
  `\alpha` used to emit `"affiliated":{"NAME":"alpha"}`. The code was reading an `:name`
  property that happens to exist on several node types, and an entity's own `:name` is its own
  name, not an affiliated keyword. `entity` still loses its content (see "Type coverage" above),
  but no longer fabricates anything.
- `table.el`-style tables silently lost every byte: valid JSON, exit 0, no warning, and
  schema-valid - the only defect that defeated every gate that would normally catch a problem.
  Fixed; see the `table.el` note above.

The other 19 findings - 6 high, 7 medium, 6 low - are not summarized here; `AUDIT.md` ranks and
states the current status of every one: fixed, remains as a documented round-trip loss, partly
fixed, or informational. The review returned clean verdicts on the
areas that matter most: timestamps (including the
historically buggy date/rep nesting the original two-bug find already touched), emphasis,
tables, lists, planning, links, footnotes, UTF-8 handling, and the nil/false/empty-array
ambiguity the script's own header describes.

So: the circularity itself has not gone away. Every fixture is still generated by the same
oracle it is checked against, and a passing cross-check still proves non-drift, not correctness.
What the audit adds is independent evidence about the generator itself, checked directly against
`org-element`'s source rather than against its own prior output - which measurably reduces the
risk this section describes. It does not eliminate it. A fourth bug the audit missed is still
possible, and this section keeps saying so until a second, independent audit says otherwise.

One further independent, non-circular signal exists: `harness/interpret-data-check.el` runs
`org-element-interpret-data(org-element-parse-buffer(file))` - Emacs's own unparser, which never
touches `oracle-dump.el` or `expected.json` at all - against all 95 files in this corpus (the 82
conformance inputs plus the 13 real-world files). 62 of 95 matched the original bytes exactly.
The other 33 were inspected by hand, one at a time, and every first divergence traces to a
known, harmless `org-element-interpret-data` re-emit convention (keyword-name case-folding,
block and property-drawer reindentation, headline-tag column alignment, planning-line keyword
reordering, list-counter renumbering, interleaved affiliated-keyword grouping,
and dropping the blank line between a section's last
element and the next headline), not an information loss. `compare-strings` only reports
the first divergence per file, so this check is scoped to what was actually inspected: for the
largest real-world files, a second, independent divergence later in the same file would not have
been caught by this pass.

Some of `oracle-dump.el`'s own inline `UNTESTED:` comments, on individual properties, may still
be accurate for that one property even though the file as a whole has been run live and audited
- check the comment next to the specific property you care about.

## What protects each claim

Two different kinds of evidence back this suite's claims, and they protect against different
failure modes. A regression fixture (one of the 82 `conformance/*/expected.json` files) pins a
shape against DRIFT: if `oracle-dump.el`, or a future Emacs or org-mode version, ever changes
what it produces for that case, `harness/verify-corpus.sh` and `swift test` go red on the next
run. A one-time audit finding proves a mapping was correct AT THE TIME it was checked, against
`org-element`'s own source directly - nothing in this repository re-checks it automatically.
"One-time verified" is not a euphemism for "assumed": every item below was checked against
`org-element` by reading its source, by a live parse, or both. What it lacks is an alarm that
fires if the mapping ever breaks later.

Of the 40 mapped `org-element` types (see "Type coverage" above), plus `org-data` and
`plain-text`, **38 carry regression-fixture coverage**: `bold`, `center-block`, `code`, `comment`,
`comment-block`, `drawer`, `dynamic-block`, `example-block`, `export-block`, `fixed-width`,
`footnote-definition`, `footnote-reference`, `headline`, `horizontal-rule`, `italic`, `item`,
`keyword`, `latex-fragment`, `line-break`, `link`, `node-property`, `paragraph`, `plain-list`,
`planning`, `property-drawer`, `quote-block`, `section`, `src-block`, `statistics-cookie`,
`radio-target`, `subscript`, `superscript`, `table` (both the org-style pipe flavour and the `table.el` flavour),
`table-cell`, `table-row`, `timestamp` (`active`, `active-range`, `inactive`, `inactive-range`,
and `diary` kinds), `verbatim`, `verse-block` - plus `org-data` and `plain-text` themselves, and,
at the property level, the affiliated `NAME`, `CAPTION`, `HEADER`, `RESULTS`, `ATTR_*` and `PLOT`
keywords, and `preBlank` on `headline`, `item`, and `footnote-definition`.

**2 mapped types carry no fixture** and rest solely on the one-time audit against `org-element`'s
own source: `strike-through` and `underline`. Both are a documented decision, not an oversight:
all six emphasis markers share one border-rule mechanism, and the Layer 1 corpus already tests it
representatively via bold/italic/verbatim/code (SCHEMA.md section 7). Dedicated fixtures for those
two would add coverage on paper and nothing in fact.

`conformance/line-break-simple` used to be listed here as a fixture worth distrusting: it was
named for `line-break` but contained no `line-break` node, because the oracle flattened a hard
break into a `text` node holding a single newline, so the `\\` bytes were not represented at all.
That is fixed. `line-break` is now its own node type, the fixture contains a real `line-break`
node, and `conformance/line-break-in-verse` pins the same thing inside a verse block, where the
distinction between a forced break and an ordinary line boundary actually matters. The old note
also mis-stated its own point - it said the flattened node carried no `preBlank`, where the field
that mattered was `postBlank` (that was the real bug, and it is audit finding 9).

**The 6 variant gaps this section used to list are now closed.** Each was a variant or a property
the corpus did not happen to exercise even though the type itself was covered: `table.el`-flavour
tables and their `value`; timestamp kinds `inactive-range` and `diary` plus the `diarySexp` field;
`preBlank` on `footnote-definition`; the affiliated `CAPTION` keyword including its long/short dual
shape and the multi-caption list; and affiliated `HEADER`, `RESULTS`, `ATTR_*` and `PLOT`. All five
now have a dedicated fixture.

The sixth item on that old list stays open on purpose: the fallback behavior for the 14 unmapped
types. They are unmapped, so there is no mapping to pin - only a warning to emit, which is a
different kind of guarantee and belongs with the work that maps them.

One gap here is worse than the rest: `inlinetask`. It is not merely unfixtured - it is the one
mapping this audit could not verify at all. No constructed input actually produced an
`inlinetask` node during the review, because that requires the `org-inlinetask` package loaded
and a minimum level configured, and nothing in this pass set that up. Its mapping in
`oracle-dump.el` has not been checked against a real parse, by fixture or by audit. Stated here
plainly, because an honest gap is worth more than a silent one.

A future Emacs or org-mode version could change either of the 2 unfixtured types, the fallback
behavior for the 14 unmapped types, or the unverified `inlinetask` mapping, without this suite
noticing - nothing here re-runs against them. That exposure is far smaller than it was: it used to
cover 14 unfixtured types and 6 variant gaps as well, and those now go red on the next run.

## The round-trip loss contract (Rule D)

`renderOrg(parseOrg(text)) == text`, byte-exact, except 9 documented, confirmed instances where
the byte is not recoverable from the tree this schema builds. Full detail, including how each
one was confirmed against `org-element`'s own internal representation, is in SCHEMA.md section
10, which is the single authoritative copy - this summary cites it and does not redefine it.

This list was 15. Eight entries were closed by reading the `org-element` properties they named
(`:switches`, `:tblfm`, `:counter`, `:use-brackets-p`, `:range-type`, a link's `:type`,
`:true-level`, and the hard line break), each now carried by a schema field and pinned by a
conformance fixture. Doing that surfaced two losses nobody had checked for, and closing the
affiliated cross-key ordering gap (`affiliated` is an ordered array now) surfaced a third; all
are included below rather than omitted. Summary:

Unrecoverable from any string property in the tree - a buffer-position loss, or an upstream
normalization that happens before this schema ever sees the buffer:

1. Keyword name case (`org-element` upcases it; original case is gone).
2. Keyword/property value alignment and leading whitespace.
3. Headline tag-column padding.
4. Planning-keyword source order (`SCHEDULED`/`DEADLINE`/`CLOSED` written out of canonical
   order).
5. Trailing spaces on otherwise-blank lines.
6. Affiliated keyword aliases - `org-element` itself normalizes `#+TBLNAME:` to `NAME`,
   `#+RESULT:` to `RESULTS`, and `#+HEADERS:` to `HEADER` before this schema ever sees the
   keyword.
7. Whitespace between a hard line break's `\\` and its newline. New, found while closing the old
   item 15: `org-element`'s line-break parser swallows the trailing spaces into the node's span
   and stores nothing but positions, which this schema strips.
8. Interleaved repeats of one affiliated keyword (`#+HEADER: a`, `#+NAME: x`, `#+HEADER: b`).
   `org-element` stores each affiliated key once, at its first occurrence, values accumulated in
   source order - the interleaving exists nowhere in its tree, and Emacs's own
   `org-element-interpret-data` re-emits the grouped form too. Found while making `affiliated`
   an ordered array; pinned by `conformance/affiliated-interleaved-repeat`.

A chosen non-capture, not a position loss (the byte exists in `org-element`'s tree, just not in
a field this schema reads). Both are the same family - the plain-list `:structure` vector - and
both are declined on value rather than difficulty, with the reasoning recorded in section 10:

9. A malformed lowercase checkbox, `- [x]`, which `org-element` itself does not recognize as a
   checkbox state. Capturing it is feasible and was rejected: the entire closable surface is that
   one spelling, because `[y]`, `[XX]` and `[]` are not consumed at all and their bytes survive
   verbatim in the item's own text.
10. Alphabetical list counters, `1. [@c]`. New, found while closing the old item 10: `:counter`
   is an integer and `org-element` converts a letter to its alphabet index, so `[@c]` and `[@3]`
   are indistinguishable once parsed.

Nothing else is excused. Block content indent, headline body indent, list numbering, multiple
blank lines (including immediately before a `headline`, `item`, or `footnote-definition`, via the
`preBlank` field), inline spacing, all text, and embedded NUL bytes must all round-trip exactly.

## Running the suite

Against your own parser, in any language: read `conformance/*/input.org`, parse it, compare the
result structurally against `conformance/*/expected.json` per SCHEMA.md. Then read
`real/**/*.org`, round-trip it through your parser and renderer, and diff against the source
bytes per the loss contract above. `ADAPTER.md` walks through this in full, including how to
call `harness/oracle-dump.el` for Layer 3.

Against the Swift reference adapter:

```bash
swift build      # compiles OrgSwift + the test target
swift test        # runs all three layers
```

This reports green with 51 known issues alongside the real passes - see "Current state" above
for the split.

## Regenerating the oracle answers (Layer 3)

Layer 3 needs a local Emacs (27 or later, for native `json-serialize`) on `PATH`. Without one,
`OracleDiffTests` is skipped entirely - `swift test` stays green, it just does not run that
layer.

```bash
brew install emacs
emacs --batch -Q -l harness/oracle-dump.el --eval '(org-swift-dump "real/org-mode-samples/blocks.org")'
```

This prints one JSON document to stdout: `org-element`'s own parse of that file, normalized into
the exact shape SCHEMA.md defines.

## Fetching the wider (copyleft) corpus

`real/` holds only permissively (MIT) licensed files, because they are vendored directly into
this repository. A wider real-world sample exists under GPL/GNU FDL licenses - Worg (the
org-mode community manual) and org-mode's own official test files - which this repo fetches on
demand instead of vendoring, to keep this repository's own license unambiguous:

```bash
bash harness/fetch-corpus.sh
```

This downloads into `real-fetched/`, which is gitignored and never committed. See NOTICE.md for
exactly which files, from which repositories, under which licenses.

## Provenance and licensing

This repository is MIT licensed (see `LICENSE`). NOTICE.md records, for every vendored file,
the source repository, the exact commit fetched, the license, and any byte-level oddity worth
knowing about before it surprises someone in a round-trip diff - for example, several
`org-mode-samples` files contain embedded NUL bytes, genuine and verified against the upstream
repository, not a fetch artifact.

## Using this suite against a different parser

Nothing about Layers 1 to 3 is Swift-specific except the test runner glue
(`ConformanceTests.swift`, `RoundTripTests.swift`, `OracleDiffTests.swift`) and the
`OrgJSON`/`parseOrg`/`renderOrg` seam they call. The actual test material -
`conformance/*/{input.org,expected.json}`, `real/**/*.org`, and `harness/oracle-dump.el` - is
plain text and Elisp, independent of any host language. A parser written in Rust, Go, or
anything else can read the same `input.org`/`expected.json` pairs, round-trip the same
real-world files, and shell out to the same oracle script. `ADAPTER.md` is the step-by-step
guide for doing exactly that. That portability is the point: org-mode has never had an
independent conformance suite before, and this one is not meant to stay tied to one
implementation.
