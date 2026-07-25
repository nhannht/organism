# Oracle audit

This file is the receipt behind the claims in README.md's "The oracle's answer key" section:
that a focused human review of `harness/oracle-dump.el`'s per-type property mappings against
`org-element`'s own source has been carried out, and what it found. Every finding below cites a
file, a line, or a command a reader can run to check it. This document exists because a bare
claim like "22 findings, 3 critical" is not something a reader can verify on its own - the
findings themselves are.

Status of this document: complete. All 22 findings (3 critical, 6 high, 7 medium, 6 low) are
listed below, transcribed from the auditor's final report. The 3 critical findings, findings
4-5, and finding 20 were independently re-verified against the live code or a live Emacs run as
part of writing this document (each says so in its own entry); the rest carry the auditor's own
assessment of current status, not a second independent check by whoever wrote this file.

## Method

The review read `harness/oracle-dump.el`'s per-type property mappings against `org-element`'s
own source (the installed Emacs 30.2 / org-mode 9.7.11), checking each mapped type's fields
against what `org-element` actually tracks for that type, and testing the unmapped-type fallback
against constructed inputs designed to break it. Three findings were reproduced live before
being fixed. All fixes landed in commit `36c7f1d`, which also regenerated the 52 conformance
fixtures affected by the `preBlank` addition (18 of 52 changed, 28 insertions, 0 deletions,
every added line a `preBlank` key).

**Provenance of this document, stated plainly.** The property-mapping review itself was not
done by whoever wrote this file. It was carried out separately and relayed for publication here.
This file's own author independently re-verified the 3 critical findings, findings 4 and 5, and
finding 20 directly - against the live code in this repository and against a live Emacs 30.2
run, each entry below says which - before writing them down. The remaining 16 findings are
recorded as reported, with the reporter's own assessment of current status (fixed, remains, or
open), and were not independently re-derived by whoever compiled this document. That distinction
is stated once here rather than repeated in every entry, so a reader knows exactly which claims
in this file carry a second, independent check and which do not.

## Critical findings (3 of 3 fixed)

### 1. Any file containing a `CLOCK:` line crashed the dump entirely

The generic fallback for an unmapped `org-element` type assumed the type's `:value` property was
always a string or `nil`. A `clock` element's own `:value` is neither - it is a whole nested
`timestamp` node (a cons structure). Handing that structure to `json-serialize` crashed the
script outright, with the Emacs backtrace going to stdout itself, making the redirected output
file unparseable.

The first fix attempt tried recursing into `:value` whenever `(org-element-type value)` returned
non-nil, reasoning that a non-nil result meant `:value` was itself a proper node. That reasoning
was tested against 9 synthetic `:value` shapes and disproved: `org-element-type` is a weak
heuristic (in practice, just "is the car of this a symbol") that returns non-nil for things that
are not real nodes at all - a dotted cons `(a . b)` or a plain list of symbols `(a b)` both
satisfy it - so the "recurse" branch still crashed on those, one level deeper.

Fix: the fallback now performs a positive `(stringp value)` test rather than guessing at the
shape. A string value is kept; a `nil` value dumps children as a container; anything else is
omitted entirely, with its own stderr warning. All 9 hostile shapes now survive without a crash.

Status: FIXED, commit `36c7f1d`. Verified independently, twice: the stress test of 9 shapes
described above, and (separately, in this documentation pass) a direct run of
`harness/oracle-dump.el` against a synthetic file containing a `CLOCK:` line, confirming exit
code 0, valid JSON (`{"type":"clock","postBlank":0}`), and two stderr warnings (the standard
unmapped-type warning, plus a second warning specific to a non-string, non-nil `:value`).
`clock` remains an unmapped type on purpose - this fix repairs the crash, not the coverage gap;
see README.md's "Type coverage" section.

### 2. `entity` fabricated an affiliated keyword out of thin air

`\alpha` (an `entity` node) emitted `"affiliated":{"NAME":"alpha"}` in the JSON output - a
keyword-attachment field that has no business existing on a bare entity. Root cause: the
affiliated-keyword logic read a node's `:name` property whenever present, on the (previously
untested) assumption that `:name` only ever appears as an affiliated `#+NAME:` keyword. An
`entity` node's own `:name` property is the entity's own name (e.g. `"alpha"`), not an
affiliated keyword - the two meanings collided under one property name.

Fix: the affiliated-keyword read is now guarded on `(memq type org-element-all-elements)` - the
invariant the surrounding code comment already claimed to rely on, but did not actually enforce.
`:name` is set by exactly one org-element parser (the affiliated-keyword one) and `:caption` by
none, so `entity` was the only type this collision could happen to.

Status: FIXED, commit `36c7f1d`. Verified independently in this documentation pass: a direct run
of `harness/oracle-dump.el` against a synthetic file containing `\alpha` confirms
`{"type":"entity","children":[],"postBlank":1}` - no `affiliated` key - and exactly one stderr
warning (the standard unmapped-type warning, nothing extra). `entity` still loses its own
content (no field carries the entity's name or Unicode value); that is a documented coverage
gap, not a bug - see README.md's "Type coverage" section.

### 3. `table.el` tables silently lost every byte

A `table.el`-style ASCII table (`+---+` grid) and an ordinary org pipe table both fell into the
same code branch, which never checked `org-element`'s own `:type` property. The result for a
`table.el` table: `{"type":"table","children":[]}` - valid JSON, exit code 0, no warning, and it
passed schema validation, while every byte of the table's actual content was gone. This was the
single most dangerous finding of the review: nothing downstream (not the JSON parser, not the
schema, not a stderr scan) would have caught it.

Fix: the `table` branch now checks `:type`. An ordinary org table is unchanged. A `table.el`
table now fires a loud stderr warning and emits its raw text verbatim under `value` instead of
silently emitting empty `children`.

Status: FIXED, commit `36c7f1d`. Verified independently in this documentation pass by reading
the current branch directly (`harness/oracle-dump.el` lines 706-738): the `:type` check, the
warning message, and the raw-`:value` fallback are all present and match the fix description.
`table.el` content is still not parsed into `table-row`/`table-cell` nodes - `org-element`
itself never decomposes a `table.el` table that way either, and this is a deliberate scope
limit, not a defect. See README.md's `table.el` note under "Type coverage".

## Non-critical findings

### High (6)

4. **Most affiliated keywords were dropped.** Only `NAME` and `CAPTION` were implemented, while
   SCHEMA.md section 5 documents `HEADER`, `PLOT`, `RESULTS`, and `ATTR_BACKEND` as part of the
   same affiliated-keyword contract. Status: FIXED. All five families are now implemented -
   confirmed directly in the current source (`harness/oracle-dump.el`, the comment at the
   affiliated-keyword handling: "All five affiliated keyword families org-element recognizes are
   implemented: NAME, CAPTION, HEADER, PLOT, RESULTS, plus the open-ended ATTR_BACKEND family").
5. **Multiple `#+CAPTION:` lines on one element - only the last one survived.** `CAPTION` is one
   of the keywords `org-element` collects as a list (`org-element-multiple-keywords`), not a
   single value, so a table with two caption lines was silently losing the first. Status: FIXED.
   All entries are now kept, including the long/short dual form (`#+CAPTION[short]: long`).
6. **`table`'s `:tblfm` property was dropped** - the whole `#+TBLFM:` formula line, which
   `org-element` folds into the table element itself rather than exposing as a sibling keyword.
   Status: REMAINS. Documented as a Rule D loss - SCHEMA.md section 10, Reason B, item 9.
7. **`src-block` and `example-block`'s `:switches` property was dropped**, and this directly
   contradicted section 10's own completeness claim ("`renderOrg` MUST be byte-exact on
   everything else") before this audit. Status: REMAINS. Documented as a Rule D loss - SCHEMA.md
   section 10, Reason B, item 8.
8. **`:pre-blank` was dropped on `headline` and `item`**, and the corpus's own shipped files
   exercise it (blank lines before a headline's body, or before a list item). Status: FIXED. Now
   emitted as `preBlank` on all three types `org-element` tracks `:pre-blank` on
   (`headline`, `item`, `footnote-definition`) - commit `36c7f1d`, 18 of 52 fixtures regenerated
   to add the field.
9. **Line-break flattening emitted a `text` node carrying a `postBlank` field**, violating
   section 1's own rule that a bare `text` leaf never carries `postBlank` (only proper
   element/object nodes do). Status: FIXED.

### Medium (7)

10. **`item`'s `:counter` property was dropped** - an explicit ordered-list counter override, the
    `[@5]` in `2. [@5] five`. Status: REMAINS. Documented as a Rule D loss - SCHEMA.md section 10,
    Reason B, item 10.
11. **`subscript`/`superscript`'s `:use-brackets-p` property was dropped** - `a_b` and `a_{b}`
    normalize to the same tree, so which source form used braces is gone. Status: REMAINS.
    Documented as a Rule D loss - SCHEMA.md section 10, Reason B, item 11.
12. **`timestamp`'s `:range-type` property was dropped** - a single timestamp with an internal
    time-time contraction and a genuine two-full-timestamp range become indistinguishable. Status:
    REMAINS. Documented as a Rule D loss - SCHEMA.md section 10, Reason B, item 12. This finding
    also corrected SCHEMA.md section 9, which had wrongly claimed the schema "has no field for
    one date, two times" - the real gap is the source-form ambiguity, not a missing date/time
    field (`start`/`end` already represents a same-day time range fine).
13. **Radio links are reported as `linkType: "plain"` while still carrying a description**,
    contradicting section 4's claim that a plain link never has one. Status: REMAINS. Documented
    as a Rule D loss - SCHEMA.md section 10, Reason B, item 13 - and section 4's link description
    rule is corrected to name the exception.
14. **Diary timestamps: `start` reported `null` and `:diary-sexp` was dropped entirely.** Status:
    PARTLY FIXED. `diarySexp` (the raw `"(SEXP ...)"` text) is now emitted for `kind: "diary"`
    timestamps. The `null` `start` is kept deliberately, confirmed correct: a diary timestamp has
    no `:year-start` at all in `org-element`'s own tree, so `null` is the accurate value, not a
    gap.
15. **`special-block`'s `:type` property was dropped** - `#+begin_note` and `#+begin_warning`
    collapse into the same generic node, with nothing recording which block it was. Status:
    REMAINS, and out of this audit's fix scope for a structural reason: `special-block` is one of
    the 15 unmapped `org-element` types (see README.md's "Type coverage" section), so it goes
    through the generic unmapped-type fallback, not a dedicated branch this audit could patch.
16. **Timerange end-dayname inconsistency** - for a two-full-timestamp range on the same calendar
    day, the start half reports a `dayname` (e.g. `"Thu"`) while the end half reports `null`, even
    though both halves fall on the same day. Status: REMAINS.

### Low (6)

17. **Headline `level` is `org-element`'s own REDUCED level, not the raw star count** - under
    `#+STARTUP: odd` (`org-odd-levels-only`), `*** B` reports `level: 2`, not 3. `:true-level`
    (the raw count) is dropped. Status: REMAINS. Documented as a Rule D loss and a corrected
    section 4 field definition - confirmed live against Emacs 30.2 in this documentation pass
    (`*** B` under `org-odd-levels-only` gives `level=2`, `true-level=3`) - SCHEMA.md section 10,
    Reason B, item 14.
18. **`CAPTION`'s short form was dropped** - part of finding 5's under-implementation. Status:
    FIXED as part of finding 5.
19. **Affiliated keyword aliases are normalized away by `org-element` itself** before this schema
    ever sees the keyword - `#+TBLNAME:` becomes `NAME`, `#+RESULT:` becomes `RESULTS`,
    `#+HEADERS:` becomes `HEADER`, via `org-element-keyword-translation-alist`. Status: REMAINS,
    and unrecoverable in principle - the original spelling never reaches the tree at all.
    Documented as a Rule D loss - SCHEMA.md section 10, Reason A, item 6.
20. **`org-swift--timestamp-date`'s own docstring is factually wrong.** It claims `:null` is
    returned "when the year... is absent - i.e. WHICH = `end` on a non-range timestamp." That is
    false: confirmed live against Emacs 30.2 in this documentation pass, a plain (non-range)
    timestamp `<2026-01-15 Thu 10:00>` carries `:year-end 2026`, identical to `:year-start` - the
    year is never actually absent on the end half of a non-range timestamp. Status: **FIXED**,
    docstring only, no behavior change. Output was always correct, because the CALLER
    (`org-swift--dump-timestamp`) guards the `end` field on `is-range` and hardcodes `:null` for
    a non-range timestamp without ever calling `org-swift--timestamp-date` for that case. The
    function's wrong internal reasoning was never exercised.

    The risk was latent and specific: a maintainer who trusted the docstring would read the
    `is-range` guard as redundant and remove it, which would populate `end` with a real duplicate
    date on every ordinary timestamp, change every timestamp fixture in the corpus, and corrupt
    the published answer key. The corrected docstring now states that org-element populates the
    full `:*-end` set on non-range timestamps too, names the call-site guard as the thing that
    actually keeps `end` null, and says explicitly not to remove it.

    This finding is the same defect class as finding 1: a comment asserting an invariant that
    nothing enforces. There, the unenforced assumption crashed the dump on every `CLOCK:` line.
    Here it was caught before anyone acted on it.
21. **The file's own top-of-file `STATUS: UNTESTED` header was stale**, written before a local
    Emacs install was available to run the script against. Status: FIXED.
22. **Two unreachable branches**: the `link` node's `:format` fallback (only ever `plain`,
    `bracket`, or `angle` occur in practice) and `org-swift--dump-secondary`'s raw-string
    fallback. Status: INFORMATIONAL - both are harmless dead code, noted here so a future reader
    does not mistake either for a live safety net that is actually exercised.

## Clean verdicts

The review returned no findings - the mapping was checked against `org-element`'s own source and
confirmed correct - in these areas:

- Timestamps, including the historically buggy date/rep nesting that the original two-bug find
  (documented in SCHEMA.md section 9) already touched.
- Emphasis (bold, italic, underline, strikethrough, code, verbatim) and the shared border rule.
- Tables (the org-style pipe-table branch, as distinct from the `table.el` finding above).
- Lists, including checkboxes and nested items.
- Planning lines and property drawers.
- Links, across all `linkType` values the schema defines.
- Footnotes.
- UTF-8 handling.
- Headline priority.
- Comment marker stripping (the `#` and one following space, on both `comment` leaves and
  `#+KEY:`-style keywords).
- Literal-block trailing newlines (`src-block`, `example-block`, `export-block`,
  `comment-block` all keep the trailing `"\n"` after the last content line, per SCHEMA.md
  section 4).
- The `nil`/`false`/empty-array ambiguity `oracle-dump.el`'s own header describes as a risk for a
  native JSON encoder to get wrong. This one never actually fires in the corpus: `org-element`
  returns an empty string `""`, not `nil`, at every site this schema reads, so the ambiguity is a
  real risk in principle but not one this corpus has ever exercised in practice.

## Coverage statement

Org-mode defines 54 distinct `org-element` node types (30 elements, 24 objects).
`harness/oracle-dump.el` maps 39 of those 54, plus `org-data` (the parse-tree root) and
`plain-text` (the bare-string branch), which sit outside either official list. 15 types remain
unmapped and fall to the fallback described in finding 1 above. Full detail, including a
risk-ranked breakdown of the 15 and what the oracle actually emits for each, is in README.md's
"Type coverage" section.

Of the 39 mapped types, evidence splits into two different kinds, and they protect against
different failure modes - see README.md's "What protects each claim" section for the full
explanation:

- **25 mapped types carry regression-fixture coverage**: `bold`, `code`, `comment`,
  `example-block`, `export-block`, `headline`, `horizontal-rule`, `italic`, `item`, `keyword`,
  `link`, `node-property`, `paragraph`, `plain-list`, `planning`, `property-drawer`,
  `quote-block`, `section`, `src-block`, `table` (org-style pipe tables only), `table-cell`,
  `table-row`, `timestamp` (`active`, `active-range`, `inactive` kinds only), `verbatim`,
  `verse-block` - plus `org-data` and `plain-text` themselves. A drift in any of these is caught
  by `swift test` and `harness/verify-corpus.sh` on the next run.
- **14 mapped types carried no fixture** at the time of this audit and rested solely on it. That
  is no longer the current state and the list is deliberately NOT repeated here - README.md's
  "What protects each claim" is the single owner of the fixture-coverage contract, and a second
  copy in this file is exactly how the round-trip loss list drifted into four stale copies before.
  Current state, for orientation only: 12 of those 14 gained a fixture in the corpus expansion
  that took the corpus from 52 to 71 cases; the 2 that remain are `strike-through` and
  `underline`, which are a documented decision rather than an oversight (SCHEMA.md section 7).
- **6 further gaps** sat inside otherwise-fixtured types - a variant or a property the 52 fixtures
  of the time never happened to exercise. Five are now closed by fixtures; the sixth, fallback
  behavior for the unmapped types, stays open by design. README.md's "What protects each claim"
  holds the current statement.

One gap is worse than the rest, and is stated here plainly rather than left silent: `inlinetask`
is not merely unfixtured, it is the one mapping this audit could not verify AT ALL. No
constructed input actually produced an `inlinetask` node during the review, because doing so
requires the `org-inlinetask` package loaded and a minimum level configured, and nothing in this
pass set that up. Its mapping in `oracle-dump.el` has never been checked against a real parse,
by fixture or by audit.
