# The org-node JSON Schema

`org-node.schema.json` is a formal JSON Schema (draft 2020-12) for the normalized tree that
`parseOrg` must produce. It is the machine-readable version of the prose contract in
`SCHEMA.md` at the repo root. Read `SCHEMA.md` first - it explains WHY the tree looks this way.
This file is the exact shape a program can check automatically.

Every `conformance/<case>/expected.json` file in this repo is meant to validate against this
schema, and so should your own parser's output, once you have one: run it through `parseOrg`,
dump the result as JSON, and validate that JSON against this schema before you even compare it to
`expected.json`. A schema failure tells you your tree has the wrong SHAPE (a missing field, a
wrong type, an extra key). A structural mismatch against `expected.json` tells you the shape is
right but the CONTENT is wrong. Those are two different bugs, and the schema catches the first
kind faster.

## Note: this file below is a historical record, and the corpus has since grown

Everything from "Corpus regeneration complete" down describes ONE past event - the `preBlank` bug
fix and the corpus regeneration that followed it - and its numbers are the numbers of that moment:
52 fixtures. They are left at 52 deliberately, because rewriting them to today's count would make
a true historical record into a false one.

The corpus is now **71 fixtures**, all still **71/71 valid, 0 invalid** against this schema. The
19 cases added since exercise several things the text below correctly reported as unexercised AT
THE TIME. Four statements no longer describe the current corpus:

| Statement below | Still true? |
|---|---|
| "none of the 52 exercise `table.el`" | No - `conformance/table-el-flavour` does |
| "None of the corpus's 52 fixtures use any keyword besides `NAME`" | No - `conformance/affiliated-caption-forms` and `conformance/affiliated-header-results-attr-plot` use `CAPTION`, `HEADER`, `PLOT`, `ATTR_HTML`, `ATTR_LATEX`, and `RESULTS` |
| "`footnote-definition` does not appear in any of the 52 fixtures" | No - `conformance/footnote-definition-simple` and `conformance/footnote-definition-preblank` do |
| "changes zero of the 52 fixtures, since none contain a diary timestamp" | No - `conformance/timestamp-diary-sexp` does |

Each of those four was a genuine coverage gap that the text below named honestly. They are now
closed by fixtures, which is the point: the schema features they describe are no longer supported
only by constructed one-off test files, they are pinned by the checked-in corpus.

**Corpus regeneration complete.** A confirmed bug fix in `harness/oracle-dump.el` changed what a
correct tree looks like: `headline`, `item`, and `footnote-definition` now carry a required
`"preBlank"` field (see "`preBlank`" below). All 52 `conformance/*/expected.json` fixtures were
regenerated from the (by then frozen and auditor-certified) oracle to match - every byte from the
generator, none hand-edited. The regeneration touched exactly 18 files, every change an added
`"preBlank"` key on a `headline` or `item` node, confirmed three independent ways before and after:
see "How this was verified" below.

Several OTHER bugs were fixed in the same pass (a crash on `CLOCK:` lines, a fabricated
`affiliated` key on `entity`, a silently emptied `table.el` table, under-implemented affiliated
keywords, a dropped diary-timestamp payload, an inconsistent `text` node) but were scoped
deliberately narrow: fix what is broken, complete what this schema already claims, add no new
type claims. None of the corpus's 52 fixtures exercise any of these cases, so none of them change
a single existing fixture - see each section below for what actually changed and why.

## How to validate a file

Any draft 2020-12 capable validator works. Two are used throughout this document:

Node, via `ajv-cli` (no local install needed, `bunx` fetches it once):

```bash
bunx ajv-cli@5 validate -s schema/org-node.schema.json --spec=draft2020 -d your-output.json
```

Python, via `jsonschema` (no local install needed, `uv run --with` fetches it once):

```bash
uv run --with jsonschema python3 - <<'EOF'
import json, glob
from jsonschema import Draft202012Validator

schema = json.load(open("schema/org-node.schema.json"))
validator = Draft202012Validator(schema)

for f in sorted(glob.glob("conformance/*/expected.json")):
    data = json.load(open(f))
    errors = list(validator.iter_errors(data))
    print(f, "OK" if not errors else f"FAIL: {errors[0].message}")
EOF
```

## How this was verified

Before the pending `preBlank` fix (see above), both validators ran clean against all 52
`conformance/*/expected.json` fixtures: 52/52 pass on both, and `ajv-cli@5 compile` confirmed the
schema file itself is a valid draft 2020-12 schema.

After the fix, re-verified three independent ways, all agreeing exactly:

1. **`harness/verify-corpus.sh`** (runs the live oracle against every fixture): **18/52 fail, 34
   pass.** Every failing case is named `easy-commented-headline`, `easy-heading-levels`, and 16
   others - all fixtures containing at least one `headline` or `item` node.
2. **Schema validation of the old (unregenerated) fixtures against the updated schema:** exactly
   the same 18 fail, by name, not just by count.
3. **An exhaustive, non-truncated structural diff** (every key path compared, not just the first
   20 lines of a unified diff) between fresh oracle output and each of the 18 old fixtures: every
   single difference across all 18 is an ADDED `"preBlank"` key on a `headline` or `item` node -
   zero removals, zero value changes, zero differences anywhere else in any of the 18 trees.

This matches a falsifiable prediction made before the fix was verified: exactly 18 of 52 change,
every change is a `preBlank` addition, nothing else changes. It held.

After an independent audit certified the frozen generator, regeneration was approved and carried
out: all 52 `expected.json` files were rewritten from fresh oracle output (`emacs --batch -Q -l
harness/oracle-dump.el --eval '(org-swift-dump "input.org")' | jq .`, the same recipe every other
fixture in this corpus was generated with - confirmed byte-identical against an unaffected
fixture before trusting it on all 52). Post-regeneration: `harness/verify-corpus.sh` reports
**52/52 passed, 0 failed**; schema validation of all 52 regenerated fixtures reports **52 valid, 0
invalid**; `git diff --stat conformance/` shows exactly 18 files changed with 28 insertions and 0
deletions, every added line a `"preBlank": 0`; and `swift test` passes with 11 tests in 6 suites,
0 real failures, 102 known issues - `OracleConformanceCrossCheckTests` (oracle vs. its own
regenerated fixtures) and `CorpusIntegrityTests` both report green, not "known issue", confirming
the regenerated corpus is internally consistent with the generator that made it.

A comprehensive regression suite (20 constructed cases) was also run against the schema at that
point, covering: the carried-over cases from earlier rounds (missing `postBlank`, unknown `type`,
`text` with a forbidden `postBlank`, `footnote-reference` with `children` when not inline,
`table-cell` correctly rejecting `affiliated`, `keyword` correctly accepting it, every
affiliated-keyword shape); and the cases specific to this round (`clock` correctly rejected -
see "Why `clock` stays unmapped (and why `table.el` no longer does)" below - `table` with a `table.el`-shaped `value`
correctly rejected AT THAT POINT (see below - this was fixed one round later), an ordinary
`table` unaffected, `headline`/`footnote-definition` correctly requiring `preBlank`, and
`timestamp.diarySexp` correctly present only for `kind: "diary"` and forbidden otherwise). All 20
as expected.

### After regeneration: the `table` fix

Once regeneration was reviewed and approved, one more schema defect surfaced: `table` was a
MAPPED type and the `table.el` shape above (`value` instead of `children`) was a deliberate,
approved generator behavior (see "Why `clock` stays unmapped (and why `table.el` no longer does)" below) - so a schema
that rejected it was failing to describe its own generator, the same class of bug the
`keyword`/`affiliated` fix corrected earlier. `table` is now a two-branch `oneOf` keyed on
which of `children`/`value` is present (not a `kind` field - that was tried and reverted, see
below), mirroring exactly what the generator emits. Verified:

- All 52 regenerated fixtures still validate: **52/52 valid, 0 invalid** (every one uses the
  `children` branch; none of the 52 exercise `table.el`).
- A constructed `table.el` output (`{"type":"table","value":"...","postBlank":...}`) now
  validates correctly - this same instance was confirmed REJECTED one round earlier, now
  confirmed ACCEPTED, on the same two validators.
- A table with BOTH `children` and `value` present, and one with NEITHER, are both correctly
  rejected (`oneOf` requires exactly one branch to match - a hybrid or an empty shape matches
  zero or two, either way invalid).
- `affiliated` still works on both branches.

## Why if/then, not oneOf

The node union (`$defs/node`) is written as a chain of `if`/`then`/`else` blocks dispatching on
the `"type"` field, not as a `oneOf` array of all alternatives. This is not a style preference -
an earlier `oneOf` draft of this same union was measured to take 30+ seconds to validate a single
small, six-level-deep fixture (`easy-table-simple`), because `oneOf` must fully validate every
NON-matching branch too (to confirm exactly one branch matches), and every branch shares keys
like `children` - so a non-matching branch still recursively re-validates the whole child subtree
against the same wide union again. That cost compounds with tree depth. `if`/`then` dispatches on
the `"type"` tag directly: the `if` check is cheap (one property, one const comparison) and only
the single matching branch's full schema ever runs. Same per-type schemas, same flat union
SCHEMA.md section 6 asks for (object-vs-element placement is a parser concern, not a JSON-shape
one) - only the mechanism combining them changed. After the fix, the full 52-file sweep validates
in under 0.03 seconds total.

## Why `affiliated` is element-only, not uniform (final answer, after two reversals)

This section changed twice before landing, and the history matters more than the conclusion -
each earlier version was disproved by a constructed test file, not by opinion.

**Attempt 1 - a hand-picked allowlist.** SCHEMA.md section 5 says an affiliated-keyword-bearing
element "MAY carry an extra top-level key", `"affiliated"`, without listing every eligible node
type. The first version of this schema guessed at a list of node types that looked like real,
standalone elements a `#+NAME:`/`#+CAPTION:` line could plausibly precede, and explicitly
excluded `keyword` on the reasoning that a keyword line is what attaches, not something else that
gets attached to. That reasoning was disproved: a constructed file with `#+NAME: t4` immediately
before `#+SUBTITLE: value` produces a real `keyword` node with `"affiliated": {"NAME": "t4"}` on
a live Emacs 30.2 run - exactly the type the allowlist excluded, and `harness/oracle-dump.el`
confirmed it emits this for real.

**Attempt 2 - uniform on every node type.** The lesson taken from attempt 1 was that a hand-picked
allowlist is a guess that must be exactly right, and `keyword` proved a careful guess can still
miss. So the schema moved to the opposite extreme: `"affiliated"` optional on every node type
except `text`, matching `oracle-dump.el`'s OWN behavior at the time, which attempted
affiliated-keyword extraction unconditionally on every node with no type check at all. This was
also disproved, by a different constructed file: a bare `\alpha` (an `entity` OBJECT, not an
element) has its own `:name` property - the entity's own identifying name, set by
`org-element-entity-parser`, nothing to do with any `#+NAME:` line - and the ungated code
fabricated `"affiliated": {"NAME": "alpha"}` for it. Uniform permission on the schema side meant
this fabricated shape validated cleanly, silently hiding a real generator bug instead of
flagging it.

**Final answer - gate on `org-element-all-elements`, not either extreme.** A full sweep of
`org-element.el`'s own parser functions confirmed `:name` is set by exactly ONE parser in the
whole file (`org-element-entity-parser`), outside the genuine affiliated-keyword mechanism, and
`:caption` by none - so `entity` was the only collision, not one of an unknown number waiting to
be found. `oracle-dump.el` now gates affiliated-keyword extraction on
`(memq type org-element-all-elements)` - a live check against org-element's own disjoint
element/object type constants, not a hand-maintained list that can drift. This is neither attempt
1 nor attempt 2: it correctly re-admits `keyword` (a genuine element, disproving attempt 1) AND
correctly excludes `entity` (a genuine object, disproving attempt 2), because it asks
org-element's own type system the question directly instead of guessing at either an allowlist or
a blanket permission.

This schema now matches that gate exactly: `"affiliated"` is optional on every node type that is
a genuine `org-element` element (`center-block`, `comment`, `comment-block`, `drawer`,
`dynamic-block`, `example-block`, `export-block`, `fixed-width`, `footnote-definition`,
`headline`, `horizontal-rule`, `item`, `keyword`, `node-property`, `paragraph`, `list`,
`planning`, `property-drawer`, `quote-block`, `section`, `src-block`, `table`, `table-row`,
`verse-block`), and REMOVED from every genuine object type (`bold`, `italic`, `underline`,
`strikethrough`, `code`, `verbatim`, `link`, `subscript`, `superscript`, `table-cell`,
`timestamp`, `footnote-reference`, `latex-fragment`) and from `document` (the root `org-data`
type, which is in neither `org-element-all-elements` nor `org-element-all-objects`). `text`
remains excluded on the same structural ground as before - not a judgment call, `text` nodes are
built by a separate code path in `oracle-dump.el` that never runs the affiliated-attachment step
at all (see SCHEMA.md section 1). `clock` is a genuine `org-element` element too (confirmed via
`org-element-all-elements`) but is not one of this schema's node types at all right now - see
"Why `clock` stays unmapped (and why `table.el` no longer does)" below - so the question of whether it can carry
`affiliated` does not arise here yet.

`entity` itself stays out of scope for this schema: it is not documented anywhere in `SCHEMA.md`'s
node catalog, and it is not exercised by any of the 52 conformance fixtures or the vendored `real/`
corpus (checked directly - no `\alpha`-style entity appears in either), so it remains an unmapped
type in `oracle-dump.el` (it still warns to stderr, it just no longer fabricates an `affiliated`
key while doing so). Adding a real `entity` node type is a `SCHEMA.md` addition for later, parallel
to how `latex-fragment` and `dynamic-block` were each added incrementally.

The `$defs/affiliated` key-name pattern (`^[A-Z][A-Z0-9_]*$` for the base shape, tightened further
to the actual key set below) was never derived from observing which keys `oracle-dump.el` happens
to emit - `entity`'s fabricated `"NAME": "alpha"` would have matched an uppercase-shape pattern
too, and matching it was never an endorsement of that value being real. The pattern comes from
SCHEMA.md's own prose (affiliated keyword names are uppercase by convention, and `org-element`
upcases them regardless of source case - SCHEMA.md section 10, item 1) and from the known, closed
set of canonical affiliated keyword names `org-element` itself recognizes, not from any single
node's output.

## Affiliated keyword shapes, fully implemented

Every affiliated-keyword family `org-element` recognizes is now implemented and typed
precisely, not just `NAME` and `CAPTION`'s long form. Each shape below was confirmed live against
Emacs 30.2 with constructed test files - see `harness/oracle-dump.el`'s own comments for the exact
probes.

- `NAME`, `PLOT` - plain strings.
- `HEADER` - an array of strings, one per `#+HEADER:` line, in source order (`HEADER` is a
  "multiple" keyword - it can repeat - but not a "dual" one, so there is no short/long split).
- `CAPTION` - an array of `{"long": [object-nodes], "short": string|null}` entries, one per
  `#+CAPTION:` line, in source order. `CAPTION` is BOTH multiple (it can repeat - an earlier
  version of the oracle kept only the LAST occurrence, `(caar (last caption))`, silently dropping
  every earlier `#+CAPTION:` line) and dual (`#+CAPTION[short]: long` populates `short`; a plain
  `#+CAPTION: long` leaves it `null`).
- `RESULTS` - always `{"value": string, "hash": string|null}`. `RESULTS` is a dual keyword too,
  but its dual form is a genuine dotted pair in `org-element` (`(VALUE . HASH)`), not a proper
  list the way `CAPTION`'s is - confirmed live, `#+RESULTS: name` produces `(VALUE . nil)` and
  `#+RESULTS[hash]: name` produces `(VALUE . HASH)` with an explicit Lisp dot. One consistent
  object shape is used here regardless of whether a hash was written, rather than a
  string-or-object union.
- `ATTR_<BACKEND>` (e.g. `ATTR_HTML`, `ATTR_LATEX`, any user-chosen backend name) - an array of
  strings, one per repeated `#+ATTR_<BACKEND>:` line for that specific backend, matched by
  `patternProperties: "^ATTR_[A-Z0-9_]+$"` since the backend name is open-ended and cannot be
  enumerated as a closed set of `properties` keys.

`additionalProperties` on `$defs/affiliated` is `false`: any other key is a bug in the generator
to fix, not a schema gap to widen. None of the corpus's 52 fixtures use any keyword besides `NAME`
(on one `table`), so this is untested by the checked-in corpus - confirmed instead with
constructed test files, as noted above.

## Why `clock` stays unmapped (and why `table.el` no longer does)

Two node shapes were investigated together in one round, deliberately NOT added to this schema at
first, after an earlier draft of the same fix DID add both and that was retracted as scope creep:
adding a new node type, or a new field distinguishing two sub-kinds of an existing type, is a
coverage-claim expansion - it says this project now claims to represent something it did not claim
before - and that was not approved at the time. The scope for that round was: fix what is broken
(a crash, a fabrication, a silent loss), complete what this schema already claims (`preBlank`, the
affiliated keyword families, `diarySexp`), add no new type claims. One round later, `table.el`'s
situation turned out to be a different case than `clock`'s - see below.

**`clock`** - a `CLOCK:` line inside a `LOGBOOK` drawer - used to CRASH `oracle-dump.el` entirely
(see "Why the fallback tests `stringp`, not `org-element-type`" below). That crash is fixed. But
`clock` itself is STILL not one of this schema's node types: it falls to the generic unmapped-type
fallback like any other type this project has not mapped yet, which now warns to stderr and omits
its `:value` rather than guessing at a shape. A constructed `CLOCK:` line produces
`{"type":"clock","postBlank":0}` - valid JSON, no crash, but genuinely lossy (the clock's own
timestamp and duration are not represented) and correctly REJECTED by this schema (there is no
`$defs/clock` for it to match) - every unmapped type being schema-rejected is the backstop working
as designed, not a defect. A live mapping for `clock` WAS built and ground-truthed against
`org-element` during the investigation (both the running and closed forms came back correct), so
it is not wasted work, but it shipped with zero conformance-fixture coverage - an untested mapping
is exactly the pattern that produced the original C1/C2/C3 bugs, so it was deferred rather than
shipped without a fixture to pin it. Giving `clock` a real, named shape is a `SCHEMA.md` addition
for later, the same as `entity` above.

**`table.el`** (an ASCII-bordered table, distinct from an ordinary org pipe table) is a different
case, and ended up with a different answer. It used to be silently and completely lost:
`oracle-dump.el`'s `table` branch never checked `org-element`'s own `:type` property, so a
table.el table produced `{"type":"table","children":[]}` - valid JSON, exit 0, no warning, and
schema-valid against the OLD schema. Nothing anywhere caught it; the single most dangerous gap
found in this whole investigation, because every other confirmed bug was at least loud (a crash)
or bounded (a wrong value on one known field). `oracle-dump.el` was fixed to check `:type`, and
for `table.el` specifically, warn to stderr and emit the raw table text under `value` instead of
silently emitting empty `children`. At that point this schema's `table` definition was
deliberately NOT changed to accept `value` - `table` is a MAPPED type (unlike `clock`, which stays
unmapped), and the reasoning at the time was the same coverage-claim-expansion concern as
`clock`'s. That reasoning did not survive scrutiny: `table` already claims to describe every
table `oracle-dump.el` produces, and `table.el` output is a real, approved, non-crashing thing the
generator now emits for that type - a schema that rejects its own mapped generator's honest output
is not avoiding a coverage-claim expansion, it is failing the coverage claim it already made. That
is the same class of bug the `keyword`/`affiliated` fix corrected earlier: an adopter who
implements `table.el` correctly and faithfully would fail validation for being right. So `table`
is now a two-branch `oneOf`, keyed on which of `children`/`value` is present (not a `kind` field -
that was tried and reverted once already, and stays reverted): the `org` branch is unchanged from
before, the `table.el` branch requires `value` and forbids `children`. Both branches accept the
existing `affiliated` key, since `table` is a genuine `org-element` element either way.

## `preBlank` on `headline`, `item`, and `footnote-definition` - exactly these three, nowhere else

All three now carry a required `"preBlank"` integer. `org-element`'s `:pre-blank` holds a
blank-line count that exists nowhere else in the tree (the blank lines between a headline's own
line and its first child, between an item's bullet and its first line of content, or between a
footnote definition's label and its first line of content) - dropping it made those bytes
permanently unrecoverable.

This is deliberately NOT modeled the way `postBlank` is (always present, defaulting to `0` when
absent) - an earlier draft of this fix did exactly that, mirroring `postBlank`'s convention, and
that was corrected. `org-element` tracks `:pre-blank` on FOUR types in total, confirmed against
its own source (`org-element.el`): `headline`, `item`, `footnote-definition`, and `inlinetask`.
Of those, `inlinetask` is not one of this schema's mapped types at all (out of scope, the same as
`entity` and `special-block` - see README.md's "Type coverage" section), so it never reaches this
schema either way. `paragraph` and `plain-list` (constructed test cases with no reason to carry
`:pre-blank`) both return `nil` live, i.e. do not track it at all, not "track it as zero." A
blanket `(or (property...) 0)` default would fabricate a field on types `org-element` never
tracks it on - the exact same class of error the `affiliated`-gating fix above corrects. So
`preBlank` is required on exactly the three of THIS SCHEMA's mapped types that carry it -
`headline`, `item`, and `footnote-definition` - and nowhere else.

Exercised in the shipped corpus: `headline` and `item` both appear in the 52 conformance fixtures
(the pending regeneration above is exactly this). `footnote-definition` does not appear in any of
the 52 fixtures or in the vendored `real/` corpus, so its `preBlank` requirement changes zero
existing fixtures - confirmed as part of the exhaustive diff in "How this was verified" above.

## `diarySexp` on `timestamp` - present only for `kind: "diary"`, not always-present

`timestamp` now carries an optional `"diarySexp"` field: required (a string) when `kind` is
`"diary"`, FORBIDDEN (not merely absent - the schema actively rejects the key being present at
all) for every other kind. Enforced with the same `if`/`then`/`else` conditional-shape pattern
`footnote-reference` already uses for its `inline`-gated `children`.

This went through the same correction `preBlank` did, for the same reason. An earlier draft made
`diarySexp` always-present, `null` for the five non-diary kinds - mirroring `postBlank` again, and
wrong again for the same reason: confirmed live, `org-element` does not track `:diary-sexp` at all
on a non-diary timestamp (genuinely absent, not present-as-nil-meaning-something), the same kind
of absence `:pre-blank` has on `paragraph`. Fabricating `"diarySexp": null` everywhere would have
touched every timestamp-bearing fixture in the corpus for no reason connected to any real bug (and
did, in the retracted draft - 26 fixtures failed instead of the correct 18, until this was
caught). The omit-pattern version changes zero of the 52 fixtures, since none contain a diary
timestamp - confirmed as part of the exhaustive diff above.

A diary timestamp (`<%%(SEXP)>`) has no `start`/`end`/`repeater`/`delay` at all - every one of
those stays `null` for `kind: "diary"`, per SCHEMA.md section 9 - so `diarySexp` (the raw
`"(SEXP ...)"` text, e.g. `"(diary-float 1 3 2)"`) is the only field that carries any payload for
that kind. An earlier version of the oracle (before either draft of this fix) read every other
diary-relevant property but never this one, so a diary timestamp's entire content was silently
dropped.

**`timestamp.start` stays nullable, decided, not reopened.** A diary timestamp genuinely has no
start date - this is a real shape, not a bug - so `start` keeps its `oneOf: [null, date]` typing.
SCHEMA.md's own section 9 already documents this exception to section 4's general case; no
SCHEMA.md edit was needed here, and none was made.

## Why the fallback tests `stringp`, not `org-element-type`

`oracle-dump.el`'s generic fallback for an unmapped `org-element` type used to assume any non-nil
`:value` was a string - `clock`'s `:value` is a whole timestamp NODE, and handing that to
`json-serialize` as if it were a scalar crashed the ENTIRE dump with `Wrong type argument:
json-value-p` on the first bare symbol `json-serialize` hit while trying to encode it. Any file
with a `CLOCK:` line failed completely, not just that one node.

An earlier draft of this fix checked `(org-element-type value)` and recursed into `value` as a
node whenever that returned non-nil, reasoning that a non-nil result meant `value` was a real
node. That was tested against nine synthetic `:value` shapes and disproved: `org-element-type` is
a weak heuristic - in practice it just checks whether `value`'s `car` is a symbol - so it returns
non-nil for things that are NOT real nodes at all: a dotted cons `(a . b)` (returns `'a`) or a
plain list of symbols `(a b)` (also returns `'a`) both satisfy it. The "recurse" branch still
crashed on those, one level deeper, the first time the recursive machinery tried to read a
property (e.g. `:post-blank`) off data that was never really a node to begin with. Confirmed
live: `org-element-type` itself never errors on any of the nine shapes tested (`nil`, a string, an
integer, a vector, a bare symbol, a dotted cons, a list of strings, a real node, a list of nodes),
but `json-serialize` crashes directly on a bare symbol, a dotted cons, or a plain (non-vector)
Lisp list handed to it as a value - exactly the shapes the top-of-file ambiguity note in
`oracle-dump.el` already warns never to hand `json-serialize` directly.

The fix is a POSITIVE test, not a "does this look like a node" guess: `:value` is handed to the
JSON layer only when `(stringp value)`. Every other case - `nil`, or ANYTHING non-string and
non-nil, including a real node - falls to the container shape (if `nil`) or is omitted with its
own diagnostic warning (everything else), never recursed into. Verified against all nine synthetic
shapes directly (bypassing real org files for the ones no real syntax can construct, like a bare
Lisp symbol): all nine now produce valid, non-crashing JSON. This schema does not need a
type-level change for this fix - it is purely about `oracle-dump.el` never crashing or silently
mis-shaping data for a type nobody has written a dedicated mapping for yet.

## `text` never carries `postBlank`, enforced both ways now

`SCHEMA.md` section 1 says a bare `text` leaf has no `postBlank` key, and this schema has always
forbidden one (`text`'s `additionalProperties: false` with no `postBlank` in its `properties`).
`oracle-dump.el` itself used to violate this for one specific case: an explicit hard line break
(`\\` at end of line) is flattened into a `text` node, but that flattening used to be routed
through the same code path as every other node type, which unconditionally stamps `postBlank`
(and attempts `affiliated`) onto whatever hashtable comes out - producing a `text` node that DID
carry `postBlank`, sitting next to ordinary `text` nodes (built via a different, bare-string code
path) that never carry one. Two different shapes for the same node type, something this schema's
`additionalProperties: false` was already positioned to catch the moment a real fixture exercised
it. `oracle-dump.el` is now fixed to build the flattened line-break node the same way ordinary
`text` nodes are built, bypassing the shared per-node tail entirely - no schema change was needed
here, since the schema's existing constraint was already correct; the generator was the thing
that had drifted from it.

## Recursive definitions the schema keeps separate from the generic node union

Where SCHEMA.md pins a field to one exact node type rather than "any node", the schema does the
same, instead of routing through the generic node union (`$defs/node`):

- `list.children` -> array of `$defs/item` only.
- `table.children` -> array of `$defs/table-row` only; `table-row.children` -> array of
  `$defs/table-cell` only.
- `property-drawer.children` -> array of `$defs/node-property` only.
- `planning.scheduled` / `.deadline` / `.closed` -> `$defs/timestamp` or `null`.

Everywhere else SCHEMA.md documents a field as "element nodes" or "object nodes" without pinning
one specific type (`section.children`, `paragraph.children`, `headline.title`, a link's
`description`, and so on), the schema uses the generic node union, matching section 6's own
framing that this is a parser-level restriction the JSON shape does not need to encode.
