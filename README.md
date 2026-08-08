# organism

[![CI](https://github.com/nhannht/organism/actions/workflows/ci.yml/badge.svg)](https://github.com/nhannht/organism/actions/workflows/ci.yml)
[![Swift versions](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fnhannht%2Forganism%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/nhannht/organism)
[![Platforms](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fnhannht%2Forganism%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/nhannht/organism)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

An Emacs org-mode parser for Swift, and the language-agnostic conformance suite it is graded by.

Both live here on purpose. The suite grades any parser in any language against `org-element`,
org-mode's own reference parser; `OrgSwift` is one implementation that passes it. If you came for
the Swift package, jump to [Using the Swift library](#using-the-swift-library).

```swift
.package(url: "https://github.com/nhannht/organism.git", from: "0.2.0")
```

## Current state (read this first)

This suite is real and usable today. The Swift parser is real and, as of 2026-08-07, complete
over every org-element type its oracle can reach.

- `parseOrg` matches `org-element`'s own tree, node for node, on **120 of 120** conformance
  cases and **13 of 13** vendored real-world files. There are no parser-shaped `withKnownIssue`
  wrappers left anywhere in the suite.
- `renderOrg` re-emits `input.org` byte-for-byte from the checked-in tree on **115 of 120**
  cases. The other 5 are PERMANENT and measured, not pending: each pins bytes that no tree built
  on `org-element` can carry, so its render is correct AND can never equal its input
  (`RendererConformanceTests.schemaLossCases`, SCHEMA.md section 10). Full-file round-trip
  `renderOrg(parseOrg(text))` stands at **13 of 13**: 4 files byte-exact, 9 byte-exact modulo
  the section 10 losses they demonstrably hit.
- **Types:** 55 of org's 56 element and object types are mapped and every one of the 55 carries
  a conformance fixture. The single exception is `inlinetask`, which is UNREACHABLE under the
  oracle's own `emacs -Q` -- `org-inlinetask` is not loaded there, so `*************** Task`
  parses as an ordinary level-15 headline. Loading it would silently re-parse every deep
  headline in the corpus, which is a different org rather than better coverage, so it is
  documented as permanently unmapped (SCHEMA.md section 9) and pinned by
  `conformance/headline-inlinetask-depth`. Both facts are mechanised: one test reads org's live
  type list and fails if anything but `inlinetask` is unmapped, another fails if a mapped type
  has no fixture.
- **Refusals that remain are narrow and named**, not whole constructs, and that is now a counted
  claim rather than an assertion. Across the 1,312-case differential sweep, **18 cases refuse**,
  in three groups: 9 MALFORMED `#+BEGIN` shapes (unterminated, bare, or badly nested -- a
  well-formed dynamic block such as a clocktable parses), 8 an undecidable non-ASCII scalar at a
  subscript/superscript body boundary, 1 the same at a footnote-label boundary. Everything else
  parses. Each refusal throws rather than guessing.

  One refusal is about DEPTH rather than any construct, and it is the only one no corpus here
  triggers: input nesting past `OrgParser.nestingLimit` throws `OrgError.nestingTooDeep`. It
  exists because the alternative was measured and is worse. A 250-level nested list used to kill
  the process with SIGBUS on a 512 KB stack -- the stack a background thread gets, which is where
  an editor parses -- and a document 618 headline levels deep died releasing its tree, in the
  caller, after `parseOrg` had already returned successfully. A crash is the one outcome a
  `throws` signature cannot express, so it is now a refusal. In practice the limit accepts a
  nested list 22 levels deep and refuses at 23, where an unguarded debug build died at 42 - and
  the deepest of these 1,427 inputs needs a third of what it allows. `DepthLimitTests` holds
  both sides of it.

  For the throw SITES rather than the cases, read them off the source -- `grep -rn
  'OrgError.unimplemented(' Sources/OrgSwift/` -- and do not trust a number written here for
  them. A prose count of sites is exactly what went stale: this bullet claimed "four class
  boundaries" while two more had landed in the same campaign, because a site count is not
  behavioural and no gate can hold it honest.

  That second number used to be unknowable. The sweep accepts a refusal silently by design -- it
  guards against wrong trees, and from inside a `catch` an over-throw looks exactly like a case
  that was never exercised. ORG-30 is the worked example: five over-throws sat at 0 of 1,181 with
  the suite green. So the 18 are now pinned by NAME in `SweepTests.knownRefusals`, which fails in
  both directions: a nineteenth refusal is red, and a listed case that starts parsing is also
  red. Widening a refusal is real work; it is not a list edit.
- `swift test` reports green, and the reason still matters. 53 known issues remain and NONE of
  them is parser-shaped: 5 are the permanent renderer losses above, and 48 belong to the
  `org-element-interpret-data` suite, which measures org-mode's own round-trip behaviour on its
  own parser. Writing a perfect Swift parser moves neither number.
- The answer key this suite grades against has its own open risk: see "The oracle's answer key:
  the circularity remains, but it has now been audited" below before you adopt
  `conformance/*/expected.json` as ground truth.

## The numbers

Every figure below is reproducible from a clean clone. The two commands in the left column are
the whole verification story - run them yourself rather than taking this table's word for it.

| What | Result |
|---|---|
| `harness/verify-corpus.sh` | 120 of 120 cases pass, 0 fail |
| `harness/validate-schema.sh` | 1,432 of 1,432 stored answers valid against the published schema |
| `swift test` | 57 tests, 14 suites, 0 failures, 53 known issues |
| Layer 1 conformance cases | 120 pairs of `input.org` + `expected.json` |
| Layer 2 real-world files | 13 vendored MIT files, from 2 sources |
| `sweep/` differential corpus | 1,312 inputs, 0 wrong trees - see `sweep/README.md` |
| `parseOrg` matches the oracle tree, conformance | 120 of 120 |
| `parseOrg` matches the oracle tree, real-world | 13 of 13 |
| `renderOrg` re-emits `input.org` from the tree | 115 of 120, the other 5 permanent by measurement |
| `renderOrg(parseOrg(text))` round-trip | 13 of 13 (4 byte-exact, 9 modulo annotated losses) |
| `org-element` types mapped by the oracle | 55 of 56, the 56th unreachable under `-Q` |
| Mapped types that also have a fixture | 55 of 55 |
| Byte-exact round-trip through `org-element` itself | 85 of 133 files |
| Documented round-trip losses | 19 - see SCHEMA.md section 10 |
| Pinned Emacs tables re-measured by `swift test` | 5 of 5 - see ORG-17 |

Three of those numbers are easy to misread, so they are stated plainly here.

**53 known issues are not 53 passes, and NONE of them is parser-shaped any more.** A case the
parser cannot handle is wrapped in `withKnownIssue`, so a green run means those failures are
expected rather than absent. That count used to be the honest measure of how much parser was
missing; it is not any more, and the split is what says so. **5 are renderer-shaped and
permanent by measurement**: each pins bytes `org-element` itself does not store, so the render
is correct AND can never equal its input (`RendererConformanceTests.schemaLossCases`). The other
**48 belong to the `org-element-interpret-data` suite**, which measures org-mode's own
round-trip losses on its own parser -- writing a perfect Swift parser does not move that 48 at
all. **Zero are parser-shaped**, in any of the three suites that used to carry them.

The number still goes UP whenever a fixture lands ahead of the code, and that is correct. It is
how `todo-hidden-by-unterminated-example` behaved for months before unpaired block openers
parsed, and how the next such fixture will behave.

**`sweep/` is the only gate here that can fail on a WRONG TREE, and it is the one that keeps
earning its place.** 1,312 generated inputs, each with org's own answer stored beside it,
reporting four states where the rest of the repository reports two: MATCH, MISMATCH (a wrong
tree, right now), an EXPECTED throw, and an unexpected one. A MISMATCH fails the build and a
throw does not, because over-throwing costs a construct while a wrong tree costs trust in every
tree - but WHICH cases throw is pinned by name in `SweepTests.knownRefusals`, so a new refusal is
red too. That second half was missing until 2026-08-08 and is why `18 of 1,312` above is a gated
number rather than a sentence. Nine defects have been found this way, five of them live
in this repository at the time and none visible to `swift test`, `verify-corpus.sh` or the
fixtures. The most recent was found by a GENERATED group of cases on its first run, four wrong
trees in code that had landed an hour earlier and passed every other gate. Its count is NOT a
correctness proof and `sweep/README.md` says at length why.

**The 19 round-trip losses are two different things.** 16 are irreducible - the byte is not
recoverable from any tree built on `org-element`, so no parser on this foundation can fix them.
The other 3 are properties this schema declines to read, with the decision and its measured
reason recorded. SCHEMA.md section 10 splits them and says which is which. This list was 15 at its widest and has grown as measurement continued; it was 15 until
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
├── conformance/            Layer 1: 120 cases, each a pair of input.org + expected.json
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

## Using the Swift library

Add the package:

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/nhannht/organism.git", from: "0.2.0")
],
targets: [
    .target(name: "YourTarget", dependencies: [
        .product(name: "OrgSwift", package: "organism")
    ])
]
```

Parse and re-emit:

```swift
import OrgSwift

let tree = try parseOrg("* TODO Write docs :work:\nSome text.\n")
let back = try renderOrg(tree)     // byte-for-byte, modulo the Rule D losses below
```

`parseOrg` returns `OrgJSON`, a plain JSON tree matching `schema/org-node.schema.json` exactly.
Read it with the accessors on that type:

```swift
if let doc = tree.objectValue,
   let children = doc["children"]?.arrayValue,
   let first = children.first?.objectValue,
   first["type"]?.stringValue == "headline" {
    print(first["level"]?.intValue ?? 0)          // 1
    print(first["todo"]?.stringValue ?? "none")   // TODO
    print(first["commented"]?.boolValue ?? false) // false
}
```

The accessors are `objectValue`, `arrayValue`, `stringValue`, `intValue`, `doubleValue`,
`boolValue` and `isNull`. Each answers only for its own case and returns `nil` for every other -
`intValue` will not widen a `.double`, because the schema never types a field as both and a
silent truncation would hide a malformed tree. This exact example is compiled by
`PublicAPITests`, so it cannot rot.

### The typed tree

`OrgJSON` is the cross-language contract, and string-keying through it is tedious in Swift. So
there is a typed view of the same tree:

```swift
let doc = try OrgDocument(parsing: source)

for headline in doc.allHeadlines where headline.todo == "TODO" {
    print(headline.level, headline.title.plainText, headline.tags)
}

for link in doc.allLinks where link.linkType == .plain {
    print(link.path)
}
```

Required schema fields are non-optional, so `level` is `Int` rather than `Int?`. The eight
enumerated fields are real enums (`.on` / `.off` / `.trans` for a checkbox, `.regular` /
`.angle` / `.plain` for a link type, and so on), and a `switch` over `OrgNode` is exhaustive, so
a node type added upstream is a build error rather than a silently skipped branch.

`walk()` visits a node and all its descendants depth-first, including secondary strings - a
headline's `title` and a link's `description` are node arrays too, and a traversal that saw only
`children` would miss most of the objects in a real file.

The whole layer is ADDITIVE. `parseOrg` and `OrgJSON` are unchanged, `OrgDocument(parsing:)` is
sugar over them, and `renderOrg` takes either:

```swift
let doc = try OrgDocument(parsing: source)
let back = try renderOrg(doc)        // identical bytes to renderOrg(parseOrg(source))
```

**It is generated, not hand-written.** `harness/regen-ast.py` reads
`schema/org-node.schema.json` and emits `Sources/OrgSwift/OrgAST.generated.swift` - 55 node
types, 8 enums, roughly 2,600 lines. The schema stays the single source of truth and the Swift
types are a build product, so the two cannot drift:

```bash
python3 harness/regen-ast.py           # regenerate
python3 harness/regen-ast.py --check   # fail if the committed file is not what the schema produces
```

**`swift test` runs that check for you** (`ASTGeneratedDriftTests`), so drift is a red run rather
than a habit. That matters because the other AST gates cannot see it: a schema change that adds
an optional field or widens an enum stays compatible with every stored tree, so the round-trip
and coverage tests both pass while the generated Swift sits stale. Measured, by adding exactly
such a field: all 9 other AST tests stayed green and only the drift test went red. It skips
gracefully when `python3` is absent, like the Emacs-backed suites.

What says the typed layer is complete and lossless: `OrgJSON -> OrgNode -> OrgJSON` is asserted
identical for **all 1,432 stored trees**, and a companion test asserts the corpus exercises every
one of the 55 generated types, so a green run is not green because something never ran.

That is deliberately the shape of the published cross-language contract rather than a Swift-native
AST, so the tree you get in Swift is the same tree a Rust or Python adapter gets. A typed layer
over it is planned.

**`parseOrg` throws rather than guessing.** It refuses 18 of the 1,312 differential-sweep inputs
(see "Current state" for the three groups), and `SweepTests.knownRefusals` names every one. A
refusal is always `OrgError.notImplemented` carrying the construct and the throw site, so handle
it explicitly if you feed the parser files you do not control:

```swift
do { tree = try parseOrg(source) }
catch OrgError.notImplemented(let reason) { /* reason names the construct and file:line */ }
```

**Requirements.** Swift 6.0+. Zero dependencies - `Sources/OrgSwift` imports nothing at all, not
even Foundation, so it is pure standard library and compiles anywhere Swift runs. The platform
minimums in `Package.swift` (macOS 13, iOS 16, tvOS 16, watchOS 9) are the `swift-testing` floor
that the TEST target needs, not the library's own. Linux is unconstrained and should work; it is
not currently exercised in CI, so treat that as untested rather than verified.

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

- **Layer 1, spec conformance** (`conformance/`): 120 small, hand-written `.org` fixtures, each
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

- 120 Layer 1 conformance cases in `conformance/`, each a matched `input.org` + `expected.json`
  pair.
- 13 vendored real-world `.org` files in `real/`, across 2 sources
  (`org-mode-samples/`, `doomemacs-docs/`), each with its own `LICENSE` file copied alongside it.
- `swift test` on this commit: 57 tests, 14 suites, 0 real failures, 53 known issues: ZERO
  parser-shaped, 5 renderer pins that are permanent by measurement, and 48 org-mode
  `interpret-data` losses.
- 1,312 `sweep/` inputs on this commit: 0 wrong trees. `SweepTests.knownWrongTrees` is EMPTY,
  and that is a measured result rather than a starting state -- it held 30 names, all ORG-28,
  until 2026-08-07. A new entry means a wrong tree was introduced. Read `sweep/README.md` before
  quoting that zero anywhere.
- `parseOrg` on this commit: 120 of 120 conformance cases produce a tree matching the oracle's,
  and 13 of 13 real-world files. `renderOrg` on this commit: 115 of 120 conformance cases
  re-emitted byte-for-byte from the checked-in tree, and full round-trip on 13 of 13 real files
  (4 byte-exact, 9 modulo their annotated section 10 losses). Measured by reading the per-suite
  known-issue counts off the run, not inferred from the total.
- `harness/verify-corpus.sh` on this commit: 120/120 conformance cases pass (a runnable
  reference adapter that uses the Emacs oracle itself as the stand-in parser).
- Every stored answer validates against `schema/org-node.schema.json`: 1,432/1,432 valid, 0
  invalid -- 120 conformance plus all 1,312 sweep answers, which went unchecked until 2026-08-07
  and were the half holding degenerate trees (see `schema/README.md` for how to run this
  yourself). The
  rewritten `affiliated` def was also shown able to fail: the old object container, a
  wrong-typed `HEADER` value, and an unknown key are each rejected, while entry order is
  correctly shape-valid in any order (order correctness belongs to the corpus comparison).
- Emacs 30.2, org-mode 9.7.11, confirmed installed. `harness/oracle-dump.el` runs clean against
  it on all 120 conformance inputs: valid JSON, zero unmapped `org-element` node types, and
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

None of these types, and no `table.el`-style table (see below), occurs anywhere in the 120
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

Even so, do not read a passing `swift test` as proof the oracle is correct. Every one of the 120
`conformance/*/expected.json` fixtures is generated BY running `oracle-dump.el` itself, so
`OracleConformanceCrossCheckTests` compares the oracle against a snapshot of its own prior
output, not against anything independent. A green run there proves only that
`oracle-dump.el`'s output for these 120 cases has not drifted since the fixtures were minted -
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
touches `oracle-dump.el` or `expected.json` at all - against all 133 files in this corpus (the
120 conformance inputs plus the 13 real-world files). 85 of 133 matched the original bytes exactly.
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
failure modes. A regression fixture (one of the 120 `conformance/*/expected.json` files) pins a
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

This reports green with 53 known issues alongside the real passes - see "Current state" above
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
