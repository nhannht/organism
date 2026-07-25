# OrgSwift normalized JSON tree schema

This is the shared contract between the parser (`Sources/OrgSwift`), the renderer, and the
spec-conformance corpus (`conformance/*/expected.json`). It is authoritative:
`parseOrg(source)` must produce a tree that structurally equals `expected.json` for every
conformance case (see `Tests/OrgSwiftTests/ConformanceTests.swift`). This schema is not scoped
to `OrgSwift` alone: any conformant parser, in any language, must produce a tree matching this
shape for every `conformance/*/expected.json` case. `Sources/OrgSwift` is this repository's one
reference implementation of the contract, not the definition of it.

Ground truth for org-mode syntax is Nicolas Goaziou's spec: https://orgmode.org/worg/org-syntax.html
Where this schema makes a normalization or representation choice the spec leaves open, that
choice is called out explicitly below, under "Schema decisions and open questions".

## 1. Shape

Every node is a JSON object with a string `"type"` key. Two node shapes exist:

- **Container**: has a `"children"` key, an array of child nodes (which may be empty).
- **Leaf**: has a `"value"` key, a literal (usually string) payload, and no `"children"`.

A node never has both `"value"` and `"children"`. Some node types (e.g. `horizontal-rule`) have
neither, because their entire meaning is carried by `"type"` and their other fields.

Normalization is **reference-faithful**: the tree is `org-element`'s own parse tree with ONLY
buffer positions stripped (`:begin`, `:end`, `:contents-begin`, `:contents-end`). Everything else
`org-element` tracks is kept, including two properties that early drafts of this schema folded
away and later had to restore, once a real Emacs run showed the folding lost information:

- **Trailing newlines are content, not whitespace to trim.** A `"\n"` that `org-element` includes
  inside a node's own text/value span (e.g. the last line of a paragraph, or a block's `value`)
  stays in that string exactly as `org-element` produced it. Nothing strips it.
- **`:post-blank` is kept as an explicit `"postBlank"` integer field, always present (never
  omitted, including when `0`), on every node built from a real `org-element` element or object.**
  Not folded into any neighboring text. This is not a buffer position - it is a semantic count
  `org-element` tracks separately from content - and it is the ONLY way some information survives
  at all: an inline object followed immediately by more text on the same line (`*bold* text`) has
  the space between them consumed as the bold node's `post-blank`, never as a leading space in the
  following text node. Drop `postBlank` and that space is gone with no way back. Confirmed live
  against Emacs 30.2: a `bold` node before `" text."` on the same source line parses with
  `post-blank = 1` and the following text node's value starting directly at `"text."`, no leading
  space anywhere in its own string.

  Exception: a bare `text` leaf node (a `plain-text` span - just a Lisp string in `org-element`,
  not a node with its own properties) has no `"postBlank"` key at all. `org-element` tracks
  `post-blank` only on proper element/object nodes; raw text content carries none of its own -
  any inter-object space adjacent to a text run belongs to the object beside it, never to the text
  run itself.

Positions (`:begin`, `:end`, `:contents-begin`, `:contents-end`) are the only things normalized
out. Conformance comparison is purely structural.

`OrgJSON` (`Sources/OrgSwift/OrgJSON.swift`) is the Swift value type that carries this shape:
an `indirect enum` over `.object([String: OrgJSON])`, `.array([OrgJSON])`, `.string`, `.int`,
`.double`, `.bool`, `.null`, `Codable` via a single-value container that tries each case in turn.
Object key order is not part of the contract; comparisons are structural (`Equatable`), not
textual.

## 2. The seam

```swift
public indirect enum OrgJSON: Codable, Equatable, Sendable {
    case object([String: OrgJSON]); case array([OrgJSON])
    case string(String); case int(Int); case double(Double); case bool(Bool); case null
}

public enum OrgError: Error, Sendable { case notImplemented }

public func parseOrg(_ source: String, todoKeywords: [String]? = nil) throws -> OrgJSON
public func renderOrg(_ tree: OrgJSON) throws -> String
```

Both functions currently `throw OrgError.notImplemented` (see `Sources/OrgSwift/Parser.swift`,
`Renderer.swift`). This package is built test-first: the corpus and schema are locked in before
the parser exists. `Tests/OrgSwiftTests/ConformanceTests.swift` wraps each comparison in
`withKnownIssue` for exactly this reason -- see section 8.

## 3. The outer skeleton (pin this down first -- it repeats in every fixture)

Org's own element model (`org-element`) is: a document is a `zeroth section` (everything before
the first headline, if any) followed by a flat list of top-level headlines; each headline may
itself contain an optional `section` (its own body, before any sub-headline) followed by
sub-headlines, recursively.

```
document
├── section                      (ZEROTH section: pre-headline content. OMITTED if none.)
│   └── children: [paragraph, keyword, table, ...]
├── headline (level 1)
│   └── children:
│       ├── section              (this headline's OWN body. OMITTED if none.)
│       │   └── children: [planning?, property-drawer?, paragraph, list, ...]
│       └── headline (level 2)   (zero or more sub-headlines, siblings of the section)
│           └── children: [...]  (same shape, recursively)
└── headline (level 1)
    └── children: [...]
```

Rules:

- `document.children` is `[section?, headline, headline, ...]` -- at most one `section` (the
  zeroth section), always first if present, then zero or more top-level `headline` nodes.
- A `headline`'s `children` is `[section?, headline, headline, ...]` -- same shape, one level
  down: at most one `section` (this headline's own body), then zero or more direct
  sub-headlines (any level greater than the parent's).
- A `section` node is **omitted entirely** when it would be empty. A headline immediately
  followed by a sub-headline (no planning, no property drawer, no body text) has no `section`
  child at all -- go straight to the sub-headline. `* Empty` alone (no body, no children) has
  `children: []`.
- `planning` and `property-drawer`, when present, are always the first children of a `section`,
  in that order (planning before property-drawer), per the org-syntax spec's ordering rule.
  They are ordinary elements in the JSON tree -- nothing marks them as special except position.

## 4. Node types

### Structural

- `document` -- root. `children`: `[section?, headline*]` (see section 3).
- `headline` -- `level` (int, `org-element`'s own `:level` value - normally the number of leading
  `*`, but `org-element` REDUCES it under `#+STARTUP: odd` / `org-odd-levels-only`: a headline
  written `*** B` then reports `level: 2`, not 3, confirmed live against Emacs 30.2. `org-element`
  keeps the raw star count separately as `:true-level`; this schema does not carry a matching
  field, so the raw count is lost whenever odd-levels mode is active - see section 10, Reason B),
  `todo` (string or null), `priority`
  (string or null, e.g. `"A"`), `commented` (bool, true if the `COMMENT` keyword is present
  right after TODO/priority -- `COMMENT` itself is stripped and does NOT appear in `title`),
  `tags` ([string], from trailing `:tag:tag2:`), `title` ([object-nodes], the parsed title --
  see section 6, "Object containment"), `children`: `[section?, headline*]`.
- `section` -- a headline's (or the document's) body before the next same-or-shallower
  headline. `children`: any element nodes (planning, property-drawer, paragraph, list,
  table, blocks, keyword, etc).
- `planning` -- `scheduled`, `deadline`, `closed`: each a `timestamp` node or `null`. Present
  only for keywords that actually occur on the planning line; absent keywords are `null`, not
  omitted (all three keys are always present).
- `property-drawer` -- `children`: `[node-property*]`.
- `node-property` -- leaf-ish: `key` (string, the `:NAME:` without colons), `value` (string).
- `drawer` -- `name` (string, e.g. `"LOGBOOK"`), `children`: element nodes.
- `quote-block` -- `children`: element nodes (a quote block is a *greater element*: it holds
  other elements like `paragraph`, not raw objects).
- `center-block` -- `children`: element nodes.
- `verse-block` -- `children`: **object** nodes directly (not elements). Verse is unique among
  blocks: its contents are parsed as objects (text markup, links, timestamps, ...), matching the
  spec's "CONTENTS will contain Org objects" for verse blocks specifically. Line breaks between
  verse lines are **not** a separate node type in Layer 1 -- there is no dedicated `line-break`
  node (the `\\` hard-line-break object is out of scope for Layer 1). A verse line boundary is
  preserved as a literal `"\n"` character inside whatever `text` node value spans it. The same
  convention applies to a soft line break inside an ordinary multi-line `paragraph` (a plain
  newline with no blank line and no trailing `\\` is just part of the text content, not a node).

### Text-level container objects

- `paragraph` -- `children`: object nodes (see section 6 for what may appear).
- `text` -- leaf. `value`: string. Plain, unmarked-up text.
- `bold`, `italic`, `underline`, `strikethrough` -- `children`: object nodes (may nest each
  other, links, code/verbatim, entities, sub/superscript -- the "standard set"; see section 6).
- `code`, `verbatim` -- leaf. `value`: string, **always literal** -- never further parsed for
  emphasis or links, regardless of what contains them (see section 7, emphasis nesting).

### Links

- `link` -- `linkType`: `"regular"` (`[[path][description]]` or `[[path]]`), `"angle"`
  (`<https://...>`), or `"plain"` (bare `https://...` with no brackets). `path`: string (the
  raw link target, without brackets/protocol wrapper stripped further). `description`:
  [object-nodes] or `null` when there is no description (angle links never have one; `[[path]]`
  without a second bracket pair also has `null`). A bare `plain` link is usually description-less
  too, but NOT always: a radio link - plain text that later matches an earlier `<<<target>>>` - is
  `org-element`'s own `:type "radio"`, folded into this schema's `"plain"` `linkType` for lack of
  a dedicated category, and it DOES carry a description. See section 10, Reason B, for the
  round-trip consequence of collapsing that distinction.

### Lists

- `list` -- `kind`: `"ordered"` | `"unordered"` | `"descriptive"`. `children`: `[item*]`.
- `item` -- `bullet` (string, the literal bullet text actually used, e.g. `"-"`, `"+"`, `"1."`,
  `"a)"`), `checkbox` (`"on"` | `"off"` | `"trans"` | `null` for `[X]`/`[ ]`/`[-]`/none),
  `tag` ([object-nodes] or `null`, only meaningful for `descriptive` lists, the text before
  `" :: "`), `children`: element nodes (an item's body -- typically a `paragraph`, and may
  contain a nested `list`).

### Blocks

- `src-block` -- `language` (string or null), `params` (string or null, the rest of the
  `#+begin_src` line after the language), `value` (string, **literal**, never parsed).
- `example-block` -- `value` (string, literal).
- `export-block` -- `backend` (string or null), `value` (string, literal).
- `comment-block` -- `value` (string, literal).

  Convention for every literal block `value` (`src-block`, `example-block`, `export-block`,
  `comment-block`): `org-element`'s own `:value` property, unmodified - the exact text between the
  `#+begin_TYPE`/`#+end_TYPE` lines, content lines joined by `"\n"`, **including the trailing
  `"\n"`** after the last content line (reference-faithful: see section 1). A one-line body is
  that line's text plus one trailing `"\n"`, e.g. `"let x = 1\n"`, not `"let x = 1"`. Confirmed
  live against Emacs 30.2 on both one-line and multi-line bodies. (An earlier draft of this
  convention said "no trailing newline" - that assumed a normalization this schema no longer
  performs; regenerated fixtures reflect the corrected convention above.)
- `comment` -- leaf. `value`: string (a `# ...` line, literal, not part of the document's
  rendered content). The marker `#` and exactly one following space (if present) are stripped
  from `value`; same convention as `keyword`'s `#+KEY: VALUE` below.

### Keywords

- `keyword` -- `key` (string, **UPPERCASE**, e.g. `"TITLE"`, `"TODO"`), `value` (string,
  verbatim, unless the key is in the parsed-keyword set -- none of the Layer 1 corpus cases
  exercise a parsed keyword value, so `value` is always a plain string in this corpus).

### Misc leaves / small containers

- `horizontal-rule` -- leaf, no `value`, no `children`. A line of 5+ consecutive `-`.
- `fixed-width` -- `value`: string (a `: ...` line).
- `statistics-cookie` -- leaf. `value`: string, e.g. `"[1/3]"` or `"[50%]"`.
- `subscript`, `superscript` -- `children`: object nodes (`a_{b}`, `a^{b}`).

### Tables

- `table` -- `children`: `[table-row*]`.
- `table-row` -- `kind`: `"standard"` | `"rule"` (a `|---+---|` separator row). `children`:
  `[table-cell*]` (empty array for a `"rule"` row).
- `table-cell` -- `children`: object nodes. Convention: the single formatting space immediately
  after `|` and immediately before the next `|` (the `| content |` padding used for column
  alignment) is trimmed and not part of any node's text -- this is a corpus-authoring
  convention, not a structural schema distinction.

### Timestamps

- `timestamp` -- `kind`: `"active"` | `"inactive"` | `"active-range"` | `"inactive-range"` |
  `"diary"`. `start`: a `date` object. `end`: a `date` object or `null` (only non-null for the
  two `-range` kinds). `repeater`: a `rep` object or `null`. `delay`: a `rep` object or `null`.
  - `date` = `{ "year": int, "month": int, "day": int, "dayname": string|null, "hour":
    int|null, "minute": int|null }`.
  - `rep` = `{ "type": string, "value": int, "unit": string }`. `type` is one of `"+"`
    (cumulative), `"++"` (catch-up), `".+"` (restart) for `repeater`; `"-"` (all-type) or
    `"--"` (first-type) for `delay`. `unit` is one of `"h"`, `"d"`, `"w"`, `"m"`, `"y"`.
  - Neither `date` nor `rep` carries `"postBlank"`. Both are plain nested values describing
    part of the *same* `timestamp` node's own data (`org-element`'s `:year-start` etc. properties),
    not independent `org-element` nodes in their own right - only the enclosing `timestamp` has a
    `post-blank` of its own.
  - `diary` timestamps (`<%%(SEXP)>`) are part of this schema for completeness but are **not**
    exercised by the Layer 1 corpus -- see "Schema decisions and open questions".

### Footnotes (documented, not yet in the Layer 1 corpus -- see section 9)

- `footnote-reference` -- `label` (string or null; null only for an anonymous inline
  footnote), `inline` (bool), `children`: object nodes, present only when `inline` is true.
- `footnote-definition` -- `label` (string), `children`: element nodes.

## 5. Affiliated keywords

Per spec, an affiliated keyword (`#+NAME:`, `#+CAPTION:`, `#+DATA:`, `#+HEADER:`, `#+PLOT:`,
`#+RESULTS:`, or `#+ATTR_BACKEND:`) immediately preceding an element (no blank line between)
**attaches** to that element instead of becoming its own standalone `keyword` node. Any element
node MAY carry an extra top-level key:

- `"affiliated"`: an object mapping the keyword name (string, uppercase, e.g. `"NAME"`) to its
  value. The value is a plain **string** for keywords outside `org-element-parsed-keywords`
  (e.g. `NAME`), or an **array of object-nodes** for keywords inside it (e.g. `CAPTION`). Absent
  entirely (no `"affiliated"` key at all) when the element has none.

A keyword whose name is **not** one of the recognized affiliated-keyword names (e.g. `TITLE`,
`TODO`, `STARTUP`, `AUTHOR`, ...) never attaches, even when immediately followed by an element --
it is always its own standalone `keyword` node.

This `"affiliated"` key is a schema addition beyond the seam's original per-type key list
(flagged to reviewer/main): it is the only way to represent case 4 of the mandatory Layer 1
coverage (`#+NAME:` attaching to a table) without conflating it with a standalone keyword node.

## 6. Object containment (what can appear inside what)

- **Headline title**: standard set of objects, excluding line breaks. Always an array, even for
  a plain-text title (`title: [{"type": "text", "value": "Buy milk"}]`).
- **Paragraph, table-cell, subscript/superscript, footnote-reference (inline), link
  description**: object nodes (paragraph and link description get the full standard set;
  table-cell is restricted to the "minimal set" plus links/timestamps/footnotes per spec, but
  the JSON *shape* is identical -- `children` of object nodes -- so this restriction is a parser
  concern, not a schema concern).
- **Bold / italic / underline / strikethrough**: `children` is either further object nodes (the
  standard set -- these four **can nest each other and can contain `code`/`verbatim`**), full
  stop. There is no "string mode" in the JSON: even when the spec describes contents as "a
  string, when MARKER represents code or verbatim", that only applies to `code`/`verbatim`
  themselves, which are leaves in this schema (`value`, not `children`). See section 7.
- **Code / verbatim**: `value`, a literal string. Never parsed further, never contains nested
  nodes, no matter what element or object contains the code/verbatim span.
- **Verse block**: `children` is object nodes directly (see section 4). Distinct from quote
  block / center block, whose `children` are elements (paragraphs etc).
- **Quote block / center block / item / section**: `children` is element nodes (paragraph,
  list, table, nested blocks, ...), not raw objects.

## 7. Key rules the parser must encode

1. **Emphasis border rule** (applies identically to bold `*`, italic `/`, underline `_`,
   strikethrough `+`, verbatim `=`, code `~` -- all six markers share one rule, so the Layer 1
   corpus tests it representatively via bold/italic/verbatim/code; underline and strikethrough
   get the same mechanism and are documented here but not given dedicated fixtures).
   Structure: `PRE MARKER CONTENTS MARKER POST`,
   no whitespace between the four parts.
   - `PRE` must be whitespace, `-`, `(`, `{`, `'`, `"`, or beginning of line.
   - `POST` must be whitespace, `-`, `.`, `,`, `;`, `:`, `!`, `?`, `'`, `)`, `}`, `[`, `"`, `\`,
     or end of line.
   - `CONTENTS` may not begin or end with whitespace.
   - Consequence: `*bold*` is bold (line start / line end satisfy PRE/POST). `a*b*c` is **not**
     bold -- `a` is not in the PRE class, so the leading `*` is plain text, and the whole thing
     is literal `a*b*c`. `* bold*` and `*bold *` are **not** bold either (CONTENTS border).
   - This is the SAME rule for `=`/`~` (verbatim/code): `*before=x=after*` -- inside the bold
     span, `e` immediately precedes `=`, `e` is not a valid PRE char, so `=x=` does **not**
     become verbatim; it stays literal text `before=x=after` inside the bold span.
2. **Runtime TODO keywords**. `#+TODO: ` lines define the recognized keyword set for the rest of
   the file (two-pass: read `#+TODO:` settings first, then parse headlines). If no `#+TODO:`
   line exists anywhere in the file, the default set is exactly `TODO` and `DONE`. A headline's
   leading word is only ever treated as `todo` when it is a member of the currently-active set
   (file-defined, or default); otherwise it is plain title text.
3. **Block content mode is fixed per block type, decided before consuming contents**: `src` and
   `example` are always literal (`value`, unparsed, whatever text appears verbatim). `quote` and
   `center` hold parsed elements. `verse` holds parsed objects (not elements). This must be
   decided from the `#+begin_TYPE` line alone, before scanning contents.
4. **Affiliated keywords** attach to the very next element with no blank line between; see
   section 5.
5. **List item boundaries** are indentation-relative (see section 4, `item`): a new item starts
   at the same-or-lesser indentation as an existing item's bullet; the item ends at a
   less-indented non-continuation line, two consecutive blank lines, a heading, or EOF.
6. **Planning lines** (`SCHEDULED:`/`DEADLINE:`/`CLOSED:`) must directly follow the headline
   line with no blank line, and precede the property drawer if both are present.
7. **Property drawers** are position-locked: immediately after the headline line (or after
   planning, if present), before any other content.
8. **Links and word boundaries**: `[[path][description]]`, `[[path]]` (no description), angle
   `<https://...>`, and bare/plain `https://...` are all distinct `linkType`s; plain links are
   recognized by their own (Unicode-aware) terminator rules, not brackets.
9. **Timestamps**: active `<...>` vs inactive `[...]`; ranges via `--` between two full
   timestamps become `active-range`/`inactive-range` with both `start` and `end` populated;
   repeaters (`+1d`, `++1d`, `.+1d`) and delays (`-3d`, `--3d`) are optional, mutually
   independent, and attach to a single timestamp (not to a range as a whole).
10. **Emphasis nesting**: bold may contain italic (and vice versa) as ordinary nested object
    nodes. Bold may contain code/verbatim as a child node, but that child's own `value` stays
    completely literal -- nesting placement never causes code/verbatim contents to be
    re-parsed.

## 8. `withKnownIssue` and the pending parser

`Tests/OrgSwiftTests/ConformanceTests.swift` calls `parseOrg` inside Swift Testing's
`withKnownIssue`. Today `parseOrg` throws `OrgError.notImplemented`, which `withKnownIssue`
catches and reports as a known (expected) issue -- the suite stays green. The moment `parseOrg`
is implemented and a case's tree actually matches, `withKnownIssue` will itself start **failing**
that case, because it expects an issue that no longer occurs. That failure is the intended
signal: removing the `withKnownIssue` wrapper (nothing else) is the correct fix once the parser
lands for that case. Do not "fix" it by loosening the assertion or re-adding the wrapper.

**Important asymmetry, so "green" is never mistaken for "correct" even after the parser exists.**
`withKnownIssue` only turns red when the wrapped code produces **no** issue at all -- i.e. when
`parseOrg` succeeds AND the `#expect` comparison PASSES. If the parser is implemented but a
given case's tree is subtly wrong (parses without throwing, but doesn't match `expected.json`),
the failed `#expect` is itself an issue, `withKnownIssue` swallows it as "known," and the suite
**stays green**. In other words: match -> wrapper turns red (the forcing function above).
Mismatch -> wrapper stays green (silently). A case whose `expected.json` is simply wrong will
never turn red on its own to warn anyone -- someone has to manually unwrap a case and look, or
cross-check the fixture against an independent oracle (real Emacs org-element, see section 9).
Do not read a green `ConformanceTests` run, at any point in this project's life, as evidence that
the corpus itself is correct -- only that it is pending, or that a specific unwrapped case
matches.

## 9. Schema decisions and open questions (flagged to reviewer / main)

- **RESOLVED: reference-faithful normalization, not fold-into-text.** The first live oracle run
  against 51 hand-authored `expected.json` fixtures surfaced two mismatches with no easy
  parser-side explanation: (A) some conformance fixtures assumed a node's own trailing `"\n"` was
  trimmed, when `org-element` actually keeps it as content; (B) a space between an inline object
  and immediately-following text on the same line (`*bold* text`) was silently absent from every
  text value on either side, because `org-element` tracks it as the object's own `:post-blank`,
  never as literal text. An initial instinct was to fold both into adjacent text values during
  normalization. Decision: do not fold - go reference-faithful instead (section 1): keep
  `org-element`'s own tree with ONLY buffer positions stripped, which means trailing newlines stay
  as-is (free, no schema change) and `:post-blank` becomes an explicit `"postBlank"` field on every
  node (the actual schema change). All 52 `expected.json` fixtures (the original 51, plus one new
  `export-block` case added in the same pass -- see below) were generated from the oracle under
  this rule; `OracleConformanceCrossCheckTests` is a regression guard on `oracle-dump.el` from this
  point on, not a correctness proof, since the fixtures are now generated FROM the same oracle they
  are compared against (see that test's own docstring). This is a real gap, not just a formality:
  regenerating the answer key from the oracle removes the one independent signal that originally
  caught two real `oracle-dump.el` bugs (the spurious `date`/`rep` "type" key, the UTF-8
  double-encode), since a hand-authored fixture disagreeing with the oracle was that signal. A
  third bug of the same shape -- a mistyped property name, a mis-mapped field -- would now produce
  a self-consistent but wrong fixture, and neither this cross-check nor the interpret-data check
  below would catch it. The compensating control is a focused human review pass over
  `oracle-dump.el`'s per-type property mappings against `org-element`'s own source, not a test.

  Independent, non-circular support: `org-element-interpret-data(org-element-parse-buffer(file))`
  was run against all 52 conformance inputs plus the 13 vendored real-world files (65 total) -
  41/65 matched the original bytes exactly. `compare-strings` reports only the FIRST point of
  divergence, so the claim below is scoped to what was actually checked: the first divergence in
  each of the 24 non-matching files was inspected (full before/after text, not just the 20-char
  context window), and every one of those 24 first-divergences traces to a known
  `org-element-interpret-data` re-emit convention (keyword-name case-folding, block/property-drawer
  reindentation, headline-tag column alignment, planning-line keyword reordering, list-counter
  renumbering) -- terminology note: "keyword-name case-folding" here and "keyword/property value
  alignment whitespace" in section 10's loss list are the SAME underlying files
  (`InterpretDataRoundTripTests.knownReformattingDivergences`'s "case-folding PLUS extra
  keyword-value whitespace collapse" comment covers both in one observation); not two unwritten,
  independently-discovered patterns. The small files (most conformance cases) were verified in full; for the large
  real-world files (`faq.org` at 47KB, etc.) only the first divergence was inspected, so a second,
  independent divergence later in one of those files - a genuine information loss - would not have
  been surfaced by this pass. None of this touches the schema either way, since `OrgJSON` never
  round-trips through `org-element-interpret-data` at all. Scope note: this schema keeps a curated
  per-type field set plus `postBlank` and, on `headline`/`item`/`footnote-definition`, `preBlank`
  (the only three types `org-element` tracks `:pre-blank` on) - not literally every `org-element`
  property (`src-block`'s `:switches` and the rest of section 10's Reason B list are still not
  carried); the interpret-data check cannot catch a property dropped this way, since a property
  never captured in `OrgJSON` never passes through it either.

  This resolution is about the Layer 1 tree shape only. The related question of what `renderOrg`
  is held to -- whether reference-faithful (this section) also means byte-exact round-trip is
  achievable -- is answered separately in **section 10, "Layer 2 round-trip contract (Rule D)"**.
  Keep both in sync: a change to what this schema's tree retains changes what section 10's loss
  list can claim.

  Update: the compensating control named above - a focused human review of `oracle-dump.el`'s
  per-type property mappings against `org-element`'s own source - has since been carried out (22
  findings, 3 critical, all fixed; see the project README's circularity section for the full
  writeup). The circularity itself still stands - every `expected.json` fixture is still
  generated by the same oracle it is checked against - but the generator has now been checked
  against `org-element`'s source directly, which the circular cross-check alone could never
  supply. The Rule D losses that review surfaced are folded into section 10's loss list below.
- **Same-day time range, source-form ambiguity (corrected)**: an earlier draft of this entry
  claimed this schema's `timestamp` node "has no field for one date, two times." That was wrong:
  `start`/`end` as full dates already represents a same-day time range fine (`start` and `end`
  share the same year/month/day, differing only in `hour`/`minute`). The actual gap is different.
  `org-element` distinguishes a single timestamp with an internal time-time contraction
  (`<2026-01-01 Thu 10:00-12:00>`) from a genuine two-full-timestamp range (`<date>--<date>`) via
  its own `:range-type` property, and this schema does not read that property, so both source
  forms normalize to a structurally identical `active-range`/`inactive-range` tree. This is now
  tracked as a Rule D loss - see section 10, Reason B, `:range-type`. The Layer 1 corpus's
  mandatory "range" case uses the unambiguous two-full-timestamp form, so it does not exercise
  this ambiguity.
- **Diary timestamps** (`<%%(SEXP)>`) are documented in section 4 but not exercised by any
  Layer 1 corpus case -- no `start` date exists for a diary sexp, and the org-syntax spec
  itself gives this form minimal treatment. Deferred.
- **Footnotes** are documented (section 4) but not covered by Layer 1 corpus cases -- not in
  the mandatory hard-case list. Candidate for Layer 2.
- **Property continuation** (`:NAME+: value`, spec's append-to-previous-value form) is
  documented informally but not exercised -- the one property-drawer corpus case uses a single
  non-continued `:ID:` property. Deferred.
- **`#+TODO:` line syntax itself** (the `TODO NEXT | DONE` pipe separator, multiple keyword
  faces, etc.) is explicitly out of scope for `org-syntax.html` per the spec's own text ("belongs
  to Org's manual, not this syntax specification"). The Layer 1 corpus's runtime-TODO case
  follows the mission brief's literal example (`#+TODO: TODO NEXT DONE`, no pipe) and treats the
  last keyword as the done-state by Org-manual convention; this is a parser-configuration detail
  external to the JSON tree shape itself (a `todo` value is just a string or null either way).
- **`latex-fragment` and `dynamic-block`** (from reviewer's compensating-control audit of
  `oracle-dump.el`'s per-type mappings, task #23): both are now MAPPED in `oracle-dump.el` --
  `latex-fragment` as a leaf (`value`: the fragment's literal text, delimiters included, e.g.
  `"$x^2$"`); `dynamic-block` as a container (`blockName`: the `#+BEGIN:` name token,
  `arguments`: the raw unparsed rest-of-line text or `null`, `children`). Neither has a Layer 1
  conformance case yet -- no fixture in this corpus exercises either type, so the mapping is
  verified only by direct `emacs --batch` testing at the time it was written, not by a checked-in
  answer key. Deferred: add one conformance case per type once Layer 1 picks this back up.
- **Malformed checkbox `- [x]` (lowercase)** is a documented Layer 2 loss, but of a DIFFERENT kind
  than section 10's Reason A items -- reviewer's exact wording, adopted verbatim rather than
  lumped in as a "genuine loss" of the same kind: org-element does not recognize lowercase `x` as
  a checkbox state (only `X`, ` `, `-` are valid) -- `:checkbox` comes back `nil`, exactly as for
  a plain, non-checkbox item, and the literal `"[x] "` text is ALSO gone from the item's own
  paragraph content (`"not a checkbox?\n"`, not `"[x] not a checkbox?\n"`). The raw `"[x]"`
  survives ONLY as literal content in the plain-list's own `:structure` vector (the per-item
  tuple's checkbox slot, positional bookkeeping shared across the whole list, redundant with
  `:checkbox` for every VALID checkbox). This is a CHOSEN non-capture, not a pure-position loss
  like section 10's Reason A items: the byte IS present in the tree, in `:structure`, and this
  schema's `item` node deliberately does not read `:structure` (list-wide, position-keyed, not
  worth the schema surface for one malformed-input edge case that the all-files oracle sweep
  found in zero Layer 1 fixtures). See section 10 for the full framing of both categories
  together (Reason A: pure buffer-position losses vs. Reason B: this one, a design choice not to
  read available bookkeeping).

## 10. Layer 2 round-trip contract (Rule D)

This section governs `Tests/OrgSwiftTests/RoundTripTests.swift` (Layer 2: round-trip against
real-world `.org` files), not the Layer 1 conformance corpus above -- Layer 1 compares
`parseOrg` output against a normalized tree; it makes no claim about `renderOrg` reproducing
source bytes.

**The contract:** `renderOrg(parseOrg(text)) == text` byte-exact, EXCEPT bytes recoverable only
from `org-element` bookkeeping this schema deliberately strips (buffer positions) or does not
read (per-type properties outside this schema's curated field set). 15 known instances,
confirmed either by direct `org-element` sexp inspection or by the property-mapping audit
described in section 9's first entry, not assumed -- and they split into two DIFFERENT reasons,
not one uniform "genuine loss" bucket:

**Reason A -- unrecoverable from ANY string property (a pure buffer-position loss, or an
upstream normalization that happens before this schema ever sees the buffer; nothing else in the
tree carries the byte):**

1. Keyword name case (`org-element` upcases it; original case is gone from the tree).
2. Keyword/property value alignment and leading whitespace.
3. Headline tag-column padding -- confirmed: `"* Foo :bar:"` and `"* Foo    :bar:"` parse to
   byte-identical `:raw-value` ("Foo") and `:tags` ("bar"); the only difference anywhere in the
   plist is `:end` (a buffer offset this schema strips per section 1). No string property
   carries the padding, so a stripped-position tree cannot recover it.
4. Planning-keyword source order (`SCHEDULED`/`DEADLINE`/`CLOSED` written in a non-canonical
   order) -- confirmed: `:scheduled` and `:deadline` are fixed-name plist keys on the `planning`
   node in every source order; the only signal of which came first in the buffer is comparing
   the two timestamps' own `:begin` values, both stripped by this schema.
5. Trailing spaces on otherwise-blank lines.
6. Affiliated keyword aliases -- `org-element` itself normalizes some affiliated-keyword
   spellings before this schema ever sees them, via its own `org-element-keyword-translation-alist`:
   `#+TBLNAME:` becomes `NAME`, `#+RESULT:` becomes `RESULTS`, `#+HEADERS:` becomes `HEADER`. The
   spelling the author actually typed is gone before the tree is built -- the same kind of pure,
   upstream loss as item 1's keyword-name case-folding.

**Reason B -- a CHOSEN non-capture (the byte IS present in the tree, just not in a property this
schema reads):**

7. Malformed lowercase checkbox `- [x]` (see section 9 for the full writeup) -- the raw `"[x]"`
   survives in the plain-list's own `:structure` vector, which this schema's `item` node does
   not read. Unlike the Reason A items, this one is not a pure-position loss: the information
   exists in the tree, reachable, just deliberately not captured, because capturing it would mean
   modeling `:structure` (list-wide, position-keyed bookkeeping) for one malformed-input edge
   case that the all-files oracle sweep found in zero Layer 1 fixtures.
8. `:switches` on `src-block` and `example-block` -- the flag string after the language on a
   `#+begin_src` line, e.g. `#+begin_src elisp -n -r` loses the `-n -r`.
9. `:tblfm` on `table` -- the whole `#+TBLFM:` formula line, which `org-element` folds into the
   table element itself rather than keeping as a sibling keyword.
10. `:counter` on `item` -- an explicit ordered-list counter override, the `[@5]` in
    `2. [@5] five`.
11. `:use-brackets-p` on `subscript`/`superscript` -- `a_b` and `a_{b}` normalize to the same
    tree; which source form used braces is gone.
12. `:range-type` on `timestamp` -- a single timestamp with an internal time-time contraction
    (`<2026-01-01 Thu 10:00-12:00>`) and a genuine two-full-timestamp range (`<date>--<date>`)
    normalize to the same `active-range`/`inactive-range` shape. See section 9's corrected
    "same-day time range" entry.
13. Radio link `:type` -- a link matching an earlier `<<<target>>>` is `org-element`'s own
    `:type "radio"`, folded into this schema's `"plain"` `linkType` for lack of a dedicated
    category. Unlike an ordinary plain link, a radio link DOES carry a description; section 4's
    link description rule is corrected to name this exception.
14. Headline `:true-level` -- this schema's `level` field is `org-element`'s own `:level`, which
    is already REDUCED under `#+STARTUP: odd` (`org-odd-levels-only`), confirmed live against
    Emacs 30.2: a headline written with three stars, `*** B`, reports `level: 2`, not 3. The raw
    star count, `:true-level`, is gone; section 4's `level` definition is corrected to say so.
15. The `\\` of a hard line break -- a line explicitly ended with `\\` (a forced break, distinct
    from an ordinary soft newline) renders identically to a plain newline in this schema's `text`
    handling; which lines were forced breaks is gone. Consistent with Layer 1's own scoping
    decision to leave the dedicated `line-break` object out (see section 4, verse-block entry) --
    this is that same decision showing up as a Layer 2 consequence, not a new gap it introduces.

`renderOrg` MUST be byte-exact on everything else -- including block content indent, headline
body indent, list numbering, multi-blank lines, inline spacing (`postBlank`), all text, and NUL
bytes. These are retained in the tree as literal string content (`:value`, `:bullet`, `postBlank`
counts), so nothing prevents exact reproduction, and Layer 2 requires it. (The "multi-blank
lines" claim specifically depends on `preBlank`, now emitted on `headline`, `item`, and
`footnote-definition` -- the only three types `org-element` itself tracks `:pre-blank` on. Blank
lines immediately before one of those three node types were not recoverable before that field
was added, so this claim did not hold then; it holds now.)

**Why this is not "parity with `org-element-interpret-data`'s output".** `InterpretDataRoundTripTests`
(see that suite's docstring) characterizes `org-element`'s OWN serializer, `org-element-interpret-data`
-- it is evidence about Emacs's unparser, not a definition of what `renderOrg` must produce. Its
24-file divergence set mixes two different things: items 1 through 5 above (genuinely
unrecoverable from any tree built on `org-element`, this schema included) AND two re-emit
conventions that are
NOT information loss -- block/property-drawer reindentation and ordered-list counter renumbering.
This schema's tree retains both of those as literal string content, so `renderOrg` both can and
must reproduce them exactly. Beating `interpret-data` on block indent and list renumbering is
intentional -- this project's round-trip is stricter than Emacs's own serializer on those two
dimensions, not a bug to "fix" toward interpret-data parity.
