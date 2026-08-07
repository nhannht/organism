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
textual. When an order IS part of the contract, it rides an array -- section 5's `affiliated`
is the example: it was an object until its cross-key source order proved to be real data.

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

Both functions are real implementations today, grown case-by-case against the corpus (this
paragraph originally said both threw `OrgError.notImplemented`; the package was built
test-first, with the corpus and schema locked in before either existed). A construct outside
the implemented subset still throws -- `OrgError.notImplemented` from the parser,
`OrgError.malformedTree` from the renderer -- rather than producing bytes or trees it is not
confident about. `Tests/OrgSwiftTests/ConformanceTests.swift` and
`RendererConformanceTests.swift` wrap exactly the not-yet-implemented cases in
`withKnownIssue` -- see section 8.

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
  written `*** B` then reports `level: 2`, not 3, confirmed live against Emacs 30.2),
  `trueLevel` (int, `org-element`'s `:true-level` - the RAW leading-star count, always present,
  always an integer. Equal to `level` in ordinary files; the two diverge only under odd-levels
  mode. Both are carried because `level` alone is genuinely ambiguous there: with odd-levels
  active, `** B` reports `level: 2, trueLevel: 2` and `*** B` reports `level: 2, trueLevel: 3`,
  so two different star counts collapse onto one `level` and the source cannot be reconstructed
  from it),
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
- `clock` -- `value`: a `timestamp` node or `null`, `duration`: string or `null`. The line
  grammar is `org-element-clock-line-re`: `CLOCK:` (case-folded, measured) then either an
  inactive timestamp (optionally `--` timestamp ` => H:MM` -- a duration REQUIRES the range
  form; a single timestamp plus duration is a paragraph, measured) or a bare ` => H:MM`
  duration with no timestamp at all (then `value` is `null`, measured). `status` is
  deliberately NOT stored: org derives it as `closed` exactly when `:duration` is non-nil,
  so `duration` alone carries it (same derivability rule as the entity renderings and the
  macro key). Clock lines separate paragraphs unconditionally and never take affiliated
  keywords (`#+NAME:` before a clock stands alone, measured). Byte losses on this line shape
  are section 10 item 12.
- `node-property` -- leaf-ish: `key` (string, the `:NAME:` without colons), `value` (string).
- `drawer` -- `name` (string, e.g. `"LOGBOOK"`), `children`: element nodes.
- `quote-block` -- `children`: element nodes (a quote block is a *greater element*: it holds
  other elements like `paragraph`, not raw objects).
- `center-block` -- `children`: element nodes.
- `special-block` -- the catch-all for any `#+begin_X` whose `X` is not one of the seven
  recognized block types: a greater element with `children` element nodes, exactly like
  quote/center. `blockType` (string): the name token with its SOURCE case intact
  (`#+begin_Warning` carries `"Warning"`, measured -- pairing with `#+end_` stays
  case-folded). `parameters` (string or `null`): the rest of the opener line trimmed of
  surrounding whitespace, `null` when nothing (or only whitespace) follows the name --
  `#+begin_note` gives `null`, `#+begin_aside extra  ` gives `"extra"`, both probed live.
- `latex-environment` -- leaf. `value` (string): the RAW byte run from the `\begin{NAME}`
  opener line through the closer line, indentation and trailing whitespace intact, re-emitted
  verbatim by org's interpreter. NAME is `[A-Za-z0-9*]+`; the `begin`/`end` keywords AND the
  name pair case-folded (`\Begin{x}`, `\END{X}`, both probed live); the closer is the first
  line at or after the opener whose trailing-trimmed text ENDS with `\end{NAME}` (org searches
  `\\end{NAME}[ \t]*$` character-forward, so `body \end{x}` closes and the opener line may
  close itself). No closer means no element: the opener falls through to the paragraph path,
  where `\begin{x}` lexes as a command-form latex fragment (all measured,
  `latex-environment-forms`).
- `verse-block` -- `children`: **object** nodes directly (not elements). Verse is unique among
  blocks: its contents are parsed as objects (text markup, links, timestamps, ...), matching the
  spec's "CONTENTS will contain Org objects" for verse blocks specifically. Note the two kinds of
  line break inside a verse block are represented differently, and the distinction is the whole
  point: an ORDINARY line boundary is preserved as a literal `"\n"` character inside whatever
  `text` node value spans it, while a FORCED break (a line ending in `\\`) is its own
  `line-break` node. The same split applies inside an ordinary multi-line `paragraph`. An earlier
  version of this schema had no `line-break` node and flattened forced breaks into a `"\n"` text
  node, which made the two indistinguishable; that was section 10's old item 15 and is now closed.

### Text-level container objects

- `paragraph` -- `children`: object nodes (see section 6 for what may appear).
- `text` -- leaf. `value`: string. Plain, unmarked-up text.
- `bold`, `italic`, `underline`, `strikethrough` -- `children`: object nodes (may nest each
  other, links, code/verbatim, entities, sub/superscript -- the "standard set"; see section 6).
- `code`, `verbatim` -- leaf. `value`: string, **always literal** -- never further parsed for
  emphasis or links, regardless of what contains them (see section 7, emphasis nesting).
- `export-snippet` -- leaf. `@@backend:value@@`. `backEnd` (string): `[-A-Za-z0-9]+`, source
  case kept. `value` (string): runs to the FIRST later `@@` with no other condition -- may be
  empty, may cross newlines (both measured). No closing `@@`, no colon, or an empty backend
  means no snippet: the bytes stay plain text (all measured, `export-snippet-forms`).

### Links

- `link` -- `linkType`: `"regular"` (`[[path][description]]` or `[[path]]`), `"angle"`
  (`<https://...>`), or `"plain"` (bare `https://...` with no brackets). `pathType`: string,
  always present, `org-element`'s own `:type` - how the PATH is to be read: `"https"`,
  `"mailto"`, `"file"`, `"id"`, `"custom-id"`, `"fuzzy"`, `"coderef"`, `"radio"`, or any other
  registered link type. `path`: string (the
  raw link target, without brackets/protocol wrapper stripped further). `description`:
  [object-nodes] or `null` when there is no description (angle links never have one; `[[path]]`
  without a second bracket pair also has `null`). A bare `plain` link is usually description-less
  too, but NOT always: a radio link - plain text that later matches an earlier `<<<target>>>` -
  DOES carry a description. That is exactly what `pathType` disambiguates: a radio link is
  `linkType: "plain"` with `pathType: "radio"`, so it stays distinguishable from an ordinary
  plain link instead of being folded into it.

  **Naming wart, stated rather than hidden.** `org-element` calls `:type` the link type and
  `:format` the bracket form; this schema's `linkType` carries `:format`, so it is named after
  the wrong property, and the reference-faithful names would have been `linkType` for `:type` and
  `format` for `:format`. Renaming was rejected deliberately: silently changing what an
  already-published field name MEANS is worse for every consumer than adding one imperfectly
  named field. `pathType` is that field.
- `radio-target` -- `<<<target>>>`, the anchor a radio link matches against. `children`: object
  nodes. Carries `children` only and never `value`, although `org-element` gives a radio-target
  BOTH at once (a `:value` holding the raw text, and parsed contents): section 1 forbids one node
  having both, and `children` is the lossless choice, since the children re-emit to exactly the
  `:value` text and nested markup inside the target survives, which `:value` would flatten.

### Lists

- `list` -- `kind`: `"ordered"` | `"unordered"` | `"descriptive"`. `children`: `[item*]`.
- `item` -- `bullet` (string, the literal bullet text actually used, TRAILING WHITESPACE
  INCLUDED, e.g. `"- "`, `"+ "`, `"1. "`, `"a) "`. The whitespace is part of the value, not
  formatting noise: `org-element` records `- one` as `"- "` and `-   three` as `"-   "`, and
  Layer 2 byte-exact round-trip needs that distinction. An earlier revision trimmed it and
  these examples were written against the trimmed form, which made them the one place in this
  document disagreeing with sections 1 and 10 - see ORG-14),
  `checkbox` (`"on"` | `"off"` | `"trans"` | `null` for `[X]`/`[ ]`/`[-]`/none),
  `counter` (int or `null`, `org-element`'s `:counter` - the explicit `[@N]` override, e.g. the
  `5` in `1. [@5] five`. Always present. Set on unordered items too, so `- [@5]` reports `5`.
  Note it is an INTEGER, not the source text: `1. [@c]` reports `3`, because `org-element`
  converts a letter to its alphabet index - see section 10, item 10),
  `tag` ([object-nodes] or `null`, only meaningful for `descriptive` lists, the text before
  `" :: "`), `children`: element nodes (an item's body -- typically a `paragraph`, and may
  contain a nested `list`).

### Blocks

- `src-block` -- `language` (string or null), `switches` (string or null), `params` (string or
  null), `value` (string, **literal**, never parsed). The three head fields appear in source
  order, matching how the `#+begin_src` line is written: `#+begin_src elisp -n -r :tangle yes`
  gives `language: "elisp"`, `switches: "-n -r"`, `params: ":tangle yes"`. `switches` is
  `org-element`'s `:switches` (the flag block) and `params` is its `:parameters` (the header
  arguments); they are independent, and either can be null while the other is set.
- `example-block` -- `switches` (string or null, same meaning and convention as `src-block`'s,
  e.g. `#+begin_example -n`), `value` (string, literal). `src-block` and `example-block` are the
  only two block types `org-element` tracks `:switches` on -- quote, verse, center, comment and
  export blocks all report nil, confirmed live.
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
- `babel-call` -- leaf ELEMENT, a `#+CALL:` line. `value`: string, everything after the FIRST
  colon on the line with leading blanks skipped and the run trimmed. It is NOT a `keyword` node
  and has no `key`. Three things a "split on the colon" reading gets wrong, all measured:
  `#+CALL: a:b()` has the value `"a:b()"` (later colons are ordinary value bytes);
  `#+CALL:foo()` needs no separating space; and `#+CALL:` alone is still a babel-call, with the
  EMPTY string as its value. The name match is exact -- `#+CALLX:` and `#+CALLBACK:` are ordinary
  keywords. `org-element`'s `:call`, `:inside-header`, `:arguments` and `:end-header` are
  re-readings of the same bytes and are not duplicated, the same rule `macro` uses.

  **`renderOrg` beats `org-element-interpret-data` here, twice.** Emacs rebuilds the line from
  the four derived slots, so it emits a space that was never in the source before an end-header
  (`#+CALL: f()[:c]` becomes `#+CALL: f() [:c]`) and fabricates `()` for an empty call
  (`#+CALL:` becomes `#+call: ()`). Carrying `value` whole reproduces both byte-exact. What is
  still lost is the keyword's own CASE and any leading indentation, which are section 10 items 1
  and 2, not new losses. Pinned by `conformance/babel-call-forms`.

### Misc leaves / small containers

- `horizontal-rule` -- leaf, no `value`, no `children`. A line of 5+ consecutive `-`.
- `line-break` -- leaf, no `value`, no `children`, exactly like `horizontal-rule`: the whole
  meaning is the type. A FORCED break, i.e. a line ending in `\\`. `org-element` builds this node
  with only `:begin`, `:end` and `:post-blank` (always `0`), so there is genuinely no other
  property to carry. Distinct from an ordinary soft newline, which stays a literal `"\n"` inside
  a `text` node. Where it may appear is not universal: `org-element`'s own object restrictions
  permit it inside `bold`, `footnote-reference`, `italic`, `keyword`, `paragraph`,
  `strikethrough`, `subscript`, `superscript`, `underline` and `verse-block` -- and NOT in a
  headline title or a table cell, both confirmed live. **Renderer note:** the newline belongs to
  this node. `org-element`'s own line-break interpreter emits `\\` followed by a newline, so a
  renderer emits all three characters here and must not also emit a line ending for the line this
  node terminates.
- `fixed-width` -- `value`: string (a `: ...` line).
- `statistics-cookie` -- leaf. `value`: string, e.g. `"[1/3]"` or `"[50%]"`.
- `macro` -- leaf. `value`: string, the ENTIRE `{{{name(args)}}}` source text, case intact.
  `org-element`'s `:key` (the downcased name) and `:args` (org-macro-extract-arguments over the
  normalized group) are deterministic functions of `value` and are deliberately not duplicated,
  same rule as the entity renderings. Emacs's own interpreter REBUILDS the text from `:key` and
  loses the name's case (`{{{Title}}}` re-emits as `{{{title}}}`); `renderOrg` emits `value`
  verbatim, so its round-trip is strictly better than `interpret-data` here -- the same
  relationship as block reindentation, and NOT a section 10 loss.
- `target` -- leaf. `value`: string, the text between `<<` and `>>`; Emacs's own interpreter
  re-emits exactly `<<value>>`. The dedicated-target anchor a radio target generalizes; its
  contents are NOT lexed (unlike `radio-target`, whose contents are objects).
- `entity` -- leaf. `name`: string (`org-element`'s `:name`, the exact `org-entities` table
  key -- the 20 whitespace entities' names contain their literal spaces, e.g. `"_ "`);
  `useBrackets`: bool (`:use-brackets-p`, true when the source wrote `\name{}` and the braces
  were consumed). Those two fields fully determine the source bytes -- Emacs's own interpreter
  emits backslash, name, and `{}` when bracketed, nothing else. The six per-entity renderings
  (`:latex`, `:latex-math-p`, `:html`, `:ascii`, `:latin1`, `:utf-8`) are the table row for
  `name`, derivable by any consumer holding the same `org-entities` table, and are deliberately
  NOT duplicated onto every node.
- `subscript`, `superscript` -- `useBrackets` (bool, always present, `org-element`'s
  `:use-brackets-p`: `false` for `a_b`, `true` for `a_{b}`. Without it the braced and unbraced
  source forms produce an identical tree. The field name drops the Lisp predicate `-p`, following
  `commented` from `:commentedp` on `headline`), `children`: object nodes.
- `inline-src-block` -- object leaf, `src_LANG[PARAMS]{BODY}`. `language` (string, non-empty),
  `parameters` (string or **null**), `value` (string, the BODY ALONE, and it **may be empty** --
  `src_python{}` really is an inline-src-block). This is the one leaf here whose `value` is not
  the whole construct, which is why it needs three fields where `macro` needs one: neither the
  language nor the parameters is recoverable from the body. `parameters` is null rather than
  absent when no `[..]` was written, so the slot distinguishes "nothing was written" from "the
  producer never looked".
- `inline-babel-call` -- object leaf, `call_NAME[INSIDE](ARGS)[END]`. `value`: string, the ENTIRE
  source text. `org-element`'s `:call`, `:inside-header`, `:arguments` and `:end-header` are
  deterministic re-readings of those same bytes and are deliberately not duplicated -- same rule
  as `macro` above and the `entity` renderings.
- `citation` -- `[cite/STYLE: PREFIX; @k SUFFIX; COMMON-SUFFIX]`. A CONTAINER whose `children`
  are `citation-reference` nodes, and which ALSO carries two secondary strings of its own --
  the same two-kinds-of-field shape `headline` has with `title` beside its children. `style`
  (string or null; null for the plain `[cite:` form, and it must be NON-EMPTY when present, so
  `[cite/:@k]` is plain text). `prefix`, `suffix`: `[object-nodes]` or null.
- `citation-reference` -- one `@key` inside a citation, and the ONLY place this type appears
  (org keeps it out of the standard restriction set for exactly that reason). `key` (string,
  no leading `@`), `prefix`, `suffix` (`[object-nodes]` or null). `postBlank` is always 0 --
  org hardcodes it in the parser rather than measuring it.

  **The split into four regions is where all of a citation's difficulty is, and three of the
  four are found by searching BACKWARDS.** A common `prefix` exists only when a `;` precedes the
  FIRST key. A common `suffix` exists only when the LAST `;` is followed by no further key --
  org searches backwards for a `;`, then FORWARD from it for a key, and treats a hit as proof
  that `;` was a reference separator. Without that re-check `[cite:@a;@b]` reports ` @b` as a
  common suffix instead of a second reference: one node where org builds two, and a
  plausible-looking tree. Pinned by `i16-cite-two-keys`, `i16-cite-suffix-has-key` and
  `i16-cite-double-semi` in the sweep, with `i16-cite-all-four` as the control where the suffix
  is real.

  The key class is `@` plus one or more of `[:word:]-.:?!\`'/*@+|(){}<>&_^$#%~`. `[:word:]` is
  Unicode-aware, and unlike the four other Unicode-aware classes in this parser that costs
  nothing: every scalar the ASCII test rejects is one org would also stop the key on, and a
  non-ASCII scalar simply continues it. So this site does not throw where the dynamic-block
  name, footnote label, sub/superscript body and inline-callable boundary all do.
- `diary-sexp` -- ELEMENT leaf (so it may carry affiliated keywords; a `#+NAME:` above one really
  does attach, measured). `value`: string, the whole column-0 `%%(SEXP)` line **including** the
  `%%` marker -- unlike `comment`, whose marker is stripped. Not to be confused with a diary
  TIMESTAMP's `diarySexp` field in section 4 Timestamps: different slot, different node type. Column
  0 is required: `  %%(x)` is an ordinary PARAGRAPH, measured, and so is `%%not`. Trailing
  whitespace stays INSIDE the value -- org's regexp is `\(%%(.*\)[ \t]*$` and `.*` is greedy, so
  `%%(x)   ` has the value `%%(x)   ` even though the pattern reads at a glance like it trims.
  One line only, and it separates a paragraph unconditionally, the way a clock line does.

  **These three types carried no `$defs` entry and no oracle branch until 2026-08-07**, and the
  gap was invisible rather than open. `harness/oracle-dump.el` fell through to its unmapped-type
  fallback, which emits a bare `{"value": ...}` and warns on stderr -- and both readers of that
  oracle discarded stderr, so 11 degenerate trees were stored in `sweep/expected/` as org's own
  answer. Six were wrong: every `inline-src-block` answer had lost `language` and `parameters`.
  Both readers are gated now, and `harness/validate-schema.sh` covers the sweep corpus as well as
  `conformance/`.

### Tables

- `table` -- `tblfm` (array of strings or `null`), `children`: `[table-row*]`. `tblfm` is
  `org-element`'s `:tblfm`, one entry per `#+TBLFM:` line -- `org-element` folds those lines INTO
  the table element rather than leaving them as sibling `keyword` nodes, so no `keyword` node is
  produced for a TBLFM line at all. **The array is in REVERSE source order**, and is kept that way
  deliberately per section 1: `org-element`'s table parser builds it with `push` during a forward
  scan, and Emacs's own interpreter re-emits it through an explicit `(reverse ...)`, so a renderer
  must do the same. Trailing spaces after a formula are captured inside the string. `table.el`
  tables carry `tblfm` as well as org tables, so both table shapes require the field.
- `table-row` -- `kind`: `"standard"` | `"rule"` (a `|---+---|` separator row). `children`:
  `[table-cell*]` (empty array for a `"rule"` row).
- `table-cell` -- `children`: object nodes. Convention: the single formatting space immediately
  after `|` and immediately before the next `|` (the `| content |` padding used for column
  alignment) is trimmed and not part of any node's text -- this is a corpus-authoring
  convention, not a structural schema distinction.

### Timestamps

- `timestamp` -- `kind`: `"active"` | `"inactive"` | `"active-range"` | `"inactive-range"` |
  `"diary"`. `rangeType`: `"timerange"` | `"daterange"` | `null` (`org-element`'s `:range-type`,
  always present; which SOURCE form produced a range. `"timerange"` is one timestamp with an
  internal time-time contraction, `<2026-01-01 Thu 10:00-12:00>`; `"daterange"` is a genuine
  two-full-timestamp range, `<date>--<date>`; `null` for the non-range kinds and for `diary`).
  `start`: a `date` object. `end`: a `date` object or `null` (only non-null for the
  two `-range` kinds). `repeater`: a `rep` object or `null`. `delay`: a `rep` object or `null`.
  - **Why `end.dayname` can be `null` while `start.dayname` is set**, which used to look like an
    inconsistency (it was AUDIT.md finding 16): the two halves of a `date` have different
    provenance. `year`/`month`/`day`/`hour`/`minute` come from `org-element`'s own `:*-end`
    properties, but `dayname` alone is scraped out of `:raw-value`, which is split on `--`. A
    `"timerange"` raw value has no `--` and carries exactly one dayname token, so a null end
    dayname is the reference-faithful answer rather than a gap. A `"daterange"` written with
    daynames reports both. With `rangeType` present this is derivable instead of surprising.
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

- `"affiliated"`: an **ordered array** of `{"key", "value"}` entries -- one entry per distinct
  keyword name (`"key"`, a string, uppercase, e.g. `"NAME"`), in **source first-occurrence
  order**. Absent entirely (no `"affiliated"` key at all) when the element has none.

The order is schema data, and it is measured, not assumed (Emacs 30.2, org 9.7.11):
`org-element` retains the cross-key source order as plist key order -- the same five keys
written forward and reversed produce plists whose affiliated-key order tracks the source
exactly, both directions, and `org-element-interpret-data` re-emits both orders. A REPEATED
keyword name groups at its FIRST occurrence position with its values in source order
(`#+HEADER: a` / `#+NAME: x` / `#+HEADER: b` gives entry order `HEADER`, `NAME` with `HEADER`
value `["a", "b"]`) -- `org-element` itself cannot represent the interleaving, so that grouping
is an upstream normalization, recorded as a Reason A loss in section 10 (item 8). A last-wins
keyword (`#+NAME: a` ... `#+NAME: b`) likewise sits at its first occurrence position, carrying
the last value.

Each entry's `"value"` shape depends on the key, exactly as before the array container:
`NAME`/`PLOT` a plain **string** (last occurrence wins); `HEADER` and the open-ended `ATTR_*`
family an **array of strings**, one per line, in source order; `RESULTS` an object
`{"value", "hash"}` (`hash` null unless the `#+RESULTS[hash]:` dual form was used); `CAPTION`
an **array of `{"long", "short"}` entries**, one per line, with `long` and `short` BOTH arrays
of parsed object-nodes -- `short` null when the `#+CAPTION[short]: long` dual form was not used.

`short` was typed as a plain **string** until 2026-08-07 (ORG-16), and that was wrong in org's
own terms. CAPTION is in `org-element-parsed-keywords`, so org builds the entry as a bare
`(cons LONG DUAL)` and runs DUAL through `org-element--parse-objects` exactly as it does the
long half (`org-element.el:4885-4901`). A plain-text short hid it completely, because such a
short is a ONE-element list and reading its first element happens to give the right answer.
Two shapes it did not survive: `#+CAPTION[a *b* c]:` was silently TRUNCATED to `a `, and
`#+CAPTION[*b*]:` CRASHED the oracle outright, `json-serialize` refusing the bold node's
killed-buffer `:parent`. Pinned by `conformance/affiliated-caption-short-markup`.

An EMPTY bracket is not an empty array: `#+CAPTION[]:` gives `short` null, because parsing an
empty range yields no objects and nil is also what "no bracket" produces. Contrast
`#+RESULTS[]:`, whose `hash` is the empty STRING -- RESULTS is not a parsed keyword, so its dual
value is kept as the raw match. The two brackets look identical and follow different rules.
That collapse is section 10 item 13.

The `ATTR_*` family's key class is `ATTR_[-_A-Z0-9]+`, and both halves of that are measured
rather than assumed. org's own `org-element--affiliated-re` allows `ATTR_[-_A-Za-z0-9]+`, so a
**hyphen is legal in a backend name** and ordinary in real usage (`#+ATTR_MY-BACKEND:`). The
lowercase half of org's class is unreachable through this schema, because `org-element` upcases
affiliated keys before any tree is built: measured on Emacs 30.2, `#+attr_lower-case:` arrives as
key `ATTR_LOWER-CASE`, hyphen intact. The published JSON schema forbade the hyphen until
2026-08-07, which made an ordinary org file produce a tree correct by the oracle and invalid by
this repository's own contract; `conformance/affiliated-attr-hyphenated-backend` pins it now and
`harness/validate-schema.sh` is the gate that would have caught it.

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
   line with no blank line. For a planning line AND a property drawer to both be present as
   their own node types, planning comes first: written the other way round, `:PROPERTIES:`
   still opens a property drawer but the `SCHEDULED:` line after it is an ordinary PARAGRAPH,
   not a `planning` node (measured).
7. **Property drawers** are position-locked, and the lock has THREE conditions, all of which
   must hold or the same bytes are an ordinary `drawer` named PROPERTIES whose body is a
   paragraph rather than `node-property` rows:
   - **Name**: the drawer is called `PROPERTIES`.
   - **Position**: the first element of a section, which means immediately after the headline
     line, or after that headline's planning line. **A section here includes the document's
     own zeroth section**, so a `:PROPERTIES:` opening the buffer is org's document-wide
     property drawer - preceded only by blank lines, or by a leading comment, still counts. It
     is NOT position-locked to headlines alone, and it is never one inside an item, a
     footnote definition, a quote or center block, or after any ordinary content.
     A preceding affiliated keyword (`#+NAME:`, `#+CAPTION:`) also disqualifies it: org tests
     the position with point on the element's first line, which is then the keyword line.
   - **Block shape**: every row between the delimiters is a property line. One row that is not
     (plain text, or a blank line) makes the whole thing an ordinary drawer.

   All three are measured against Emacs 30.2 / org 9.7.11 and transcribed in
   `Sources/OrgSwift/ParserDrawers.swift`'s `PropertyDrawerMode`, which carries the full
   case table.
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

**As of 2026-08-07 the conformance suite has NO wrapped cases: all 120 assert normally, and so
do all 13 real-world files in the oracle-diff and round-trip suites.** This section is kept
because the mechanism is still wired up, still used the moment a fixture lands ahead of the
code, and -- most importantly -- because its asymmetry below is the reason a green run has never
been evidence of correctness here. Read it before adding a wrapper, not after.

`Tests/OrgSwiftTests/ConformanceTests.swift` calls `parseOrg` inside Swift Testing's
`withKnownIssue` for any case not in `implementedCases`. When `parseOrg` throws
`OrgError.notImplemented`, `withKnownIssue` catches it and reports a known (expected) issue --
the suite stays green. The moment `parseOrg`
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

- **RESOLVED: `inlinetask` is deliberately UNMAPPED, because under this oracle's configuration
  it is unreachable.** `harness/oracle-dump.el` runs Emacs with `-Q`, and `org-inlinetask` is not
  loaded there -- measured: `(featurep 'org-inlinetask)` is nil and `org-inlinetask-min-level` is
  not even bound. So `*************** Task` parses as an ordinary `headline` with `level` 15, and
  no input to this oracle can produce an `inlinetask` node at all.

  **The alternative was rejected as a configuration fork, not a verification.** Requiring
  `org-inlinetask` to "cover the type" changes the parse of the SAME bytes: the two 15-star
  headlines collapse into one `inlinetask`, the `*************** END` line is consumed rather
  than becoming a headline of its own, and every headline at or past `org-inlinetask-min-level`
  in every existing fixture and real file silently re-parses. That is a different org, and every
  answer already stored here was measured against this one.

  So the type count reads **53 of 54 mapped plus one documented-unreachable, permanently** rather
  than 54 of 54, and ORG-4's second closing condition is amended to say so rather than reported
  as a miss. Pinned by `conformance/headline-inlinetask-depth`, which asserts the `-Q` answer --
  two ordinary `level: 15` headlines around a paragraph -- so that a future change of oracle
  configuration fails a test instead of quietly rewriting the corpus.

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
  was run against all 79 conformance inputs plus the 13 vendored real-world files (92 total) -
  61/92 matched the original bytes exactly. `compare-strings` reports only the FIRST point of
  divergence, so the claim below is scoped to what was actually checked: the first divergence in
  each of the 31 non-matching files was inspected (full before/after text, not just the 20-char
  context window), and every one of those 31 first-divergences traces to a known
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
  property. That curated set has since grown: `:switches`, `:tblfm`, `:counter`,
  `:use-brackets-p`, `:range-type`, a link's `:type` and `:true-level` are all carried now, and
  what remains uncaptured is section 10's two declined `:structure` entries. The interpret-data
  check cannot catch a property dropped this way, since a property never captured in `OrgJSON`
  never passes through it either.

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
- **RESOLVED: same-day time range, source-form ambiguity.** Two corrections landed here in
  sequence, and both are worth keeping so the record shows what was actually wrong each time.
  First, an early draft claimed this schema's `timestamp` node "has no field for one date, two
  times." That was wrong: `start`/`end` as full dates already represents a same-day time range
  fine (they share year/month/day and differ only in `hour`/`minute`). Second, the replacement
  entry said the real gap was that a time-time contraction (`<2026-01-01 Thu 10:00-12:00>`) and a
  two-full-timestamp range (`<date>--<date>`) "normalize to a structurally identical tree" - true
  only in the narrower case where NO dayname is written. With a dayname the two already differed
  on `end.dayname`, for the provenance reason spelled out under `timestamp` in section 4.
  Both are now moot: this schema reads `:range-type` and carries it as `rangeType`, so the two
  source forms are explicitly distinguished in every case. `conformance/timestamp-timerange-contraction`
  pins the `"timerange"` value and `conformance/timestamp-active-range` pins `"daterange"`.

  The sharpest evidence the loss is closed: strip `rangeType` from the two NO-DAYNAME forms and
  their trees are byte-identical, keep it and they differ on exactly that one key. **That is now
  FIXTURE-PINNED rather than measured-once** (ORG-12, closed 2026-08-07). It could not be while a
  no-dayname timestamp had nowhere to live: such a timestamp triggers a separate
  `org-element-interpret-data` convention -- it INSERTS the canonical dayname, `<2026-08-07>`
  re-emitting as `<2026-08-07 Fri>` -- and any fixture carrying one failed that suite. The
  convention is now classified in `InterpretDataRoundTripTests.knownReformattingDivergences`,
  with its full before/after recorded, as a re-emit convention rather than a section 10 loss:
  interpret-data is ADDING information the source did not have. `dayname` is null in the tree for
  all four timestamps and `renderOrg` reproduces the file byte-exact, so Layer 2's bar here is
  stricter than Emacs's own output. `conformance/timestamp-no-dayname` carries all three shapes.
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
  `arguments`: the raw unparsed rest-of-line text or `null`, `children`). Both are now pinned by a
  checked-in fixture -- `conformance/latex-fragment-inline` and `conformance/dynamic-block-simple`
  -- so neither rests on one-off `emacs --batch` testing any more. (This paragraph previously said
  the opposite, that neither had a conformance case and one per type was "deferred". That was
  stale: both fixtures had already landed and the note was never struck out. It was the only text
  left in this repo disputing the count of unfixtured mapped types, which is 2 --
  `strike-through` and `underline` -- see README.md's "What protects each claim".)
- **Malformed checkbox `- [x]` (lowercase)** is a documented Layer 2 loss, but of a DIFFERENT kind
  than section 10's Reason A items: org-element does not recognize lowercase `x` as
  a checkbox state (only `X`, ` `, `-` are valid) -- `:checkbox` comes back `nil`, exactly as for
  a plain, non-checkbox item, and the literal `"[x] "` text is ALSO gone from the item's own
  paragraph content (`"not a checkbox?\n"`, not `"[x] not a checkbox?\n"`). The raw `"[x]"`
  survives ONLY in the plain-list's own `:structure` vector, in the per-item tuple's checkbox
  slot. So the byte IS present in the tree and this schema declines to read it.

  An earlier version of this entry justified the decline by saying `:structure` is "list-wide,
  position-keyed, not worth the schema surface". The first half of that is a bad argument and has
  been withdrawn: capturing this needs ONE slot of the item's own tuple and one string field, and
  emits no buffer positions at all. The decline stands on the second half alone -- value, not
  difficulty -- and section 10 item 9 now carries the measured version of that argument, together
  with the evidence that `[y]`, `[XX]` and `[]` are not losses at all. Read section 10 for the
  decision; this entry exists to record the org-element behavior that causes it.

## 10. Layer 2 round-trip contract (Rule D)

This section governs `Tests/OrgSwiftTests/RoundTripTests.swift` (Layer 2: round-trip against
real-world `.org` files), not the Layer 1 conformance corpus above -- Layer 1 compares
`parseOrg` output against a normalized tree; it makes no claim about `renderOrg` reproducing
source bytes.

**The contract:** `renderOrg(parseOrg(text)) == text` byte-exact, EXCEPT bytes recoverable only
from `org-element` bookkeeping this schema deliberately strips (buffer positions) or does not
read (per-type properties outside this schema's curated field set). 19 known instances,
confirmed either by direct `org-element` sexp inspection or by the property-mapping audit
described in section 9's first entry, not assumed -- and they split into two DIFFERENT reasons,
not one uniform "genuine loss" bucket.

**This list used to have 15 entries. Eight of them are now closed**, and the closures are the
substance of this section's current shape: `:switches`, `:tblfm`, `:counter`, `:use-brackets-p`,
`:range-type`, the radio link's `:type`, `:true-level`, and the `\\` of a hard line break are all
read now, each carried by a named schema field (`switches`, `tblfm`, `counter`, `useBrackets`,
`rangeType`, `pathType`, `trueLevel`, and a dedicated `line-break` node type respectively) and
each pinned by a conformance fixture. What remains below is 16 items that no tree built on
`org-element` can recover, plus 3 that are reachable and deliberately declined, with the reason
recorded. Closing those eight also surfaced two NEW losses that nobody had looked for -- items 7
and 10 below -- which is the ordinary result of actually checking, and they are listed here
rather than quietly omitted. (Item 8 is newer still: it surfaced when `affiliated` became an
ordered array, the change that CLOSED what used to be an unlisted cross-key ordering loss.)

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
7. Whitespace between a hard line break's `\\` and the newline -- `one\\   ` followed by a
   newline keeps its three spaces nowhere. This is NEW, surfaced by closing the old item 15
   (the `\\` itself is now carried by a dedicated `line-break` node, see section 4). It is
   distinct from item 5 above, which covers otherwise-BLANK lines; this is trailing whitespace on
   a line with content on it. Confirmed against `org-element`'s own source:
   `org-element-line-break-parser` matches `\\\\[ \t]*$` and builds the node with only `:begin`,
   `:end` and `:post-blank` (hardcoded `0`), setting `:end` to the start of the NEXT line. So the
   spaces sit inside `[begin, end)` with no property carrying them, and `[begin, end)` is exactly
   what section 1 strips. Measured: `one\\   ` + newline gives `begin 4, end 10, post-blank 0`.
8. Interleaved repeats of one affiliated keyword -- `#+HEADER: a`, `#+NAME: x`, `#+HEADER: b`
   re-emits with both `HEADER` lines grouped at the first occurrence position (`HEADER a`,
   `HEADER b`, `NAME x`). `org-element` stores each affiliated key ONCE in the element's plist,
   at its first-occurrence position, with all its values accumulated in source order -- no
   property anywhere records which other keys interrupted the run. Confirmed (Emacs 30.2):
   `org-element-interpret-data` itself re-emits the grouped form, so Emacs's own serializer
   loses the same bytes. Surfaced by `affiliated` becoming an ordered array (section 5): the
   array carries every ordering byte org-element carries -- cross-key first-occurrence order and
   per-key value order -- and the interleaving is the one ordering fact org-element itself never
   had. Pinned by `conformance/affiliated-interleaved-repeat`, the permanent resident of
   `RendererConformanceTests.schemaLossCases`.
14. Table ALIGNMENT -- `| a  | bb |` re-emits with the padding recomputed rather than preserved.
   Measured: that first cell's text is `a` with `postBlank` 0, so the extra space survives in no
   property. This looked like a blocker for rendering a RULE row, whose dash runs are likewise
   absent from the tree, and it is not, because org's own interpreter does not preserve alignment
   either -- it recomputes it, padding every cell to its column width and emitting a rule run of
   that width plus 2. `renderOrg` adopts org's convention rather than inventing one, so an
   ALIGNED table (what org-mode writes, and what every real file here contains) round-trips
   byte-exact and an unaligned one normalizes to aligned. Pinned by `conformance/table-rule-widths`.
15. Block DELIMITER case, both families -- `#+BEGIN_SRC` re-emits as `#+begin_src`, and the
   dynamic block's `#+BEGIN:` as written by this renderer. org-element keeps a block's
   `:language`, `:switches` and `:parameters` but not the case of the delimiter words themselves.
   Distinct from item 1, which is `#+KEY:` keyword lines. Annotated on
   `real/doomemacs-docs/getting_started.org` (126 lines) and `real/org-mode-samples/blocks.org`.
16. A newline inside a bracket link's PATH -- `[[https://x/y<newline>][d]]` re-emits with a single
   space where the newline was. Reason A of the upstream-normalization kind: org replaces the
   newline and any following indentation before this schema sees anything, measured as
   `:raw-link "https://x/y "`, and its own interpreter emits the space too. One occurrence in
   `getting_started.org`.
17. Leading indentation on a greater block's DELIMITER lines at top level -- `  #+begin_quote`
   re-emits flush left. org-element records no column for it. `renderOrg` is already strictly
   better than Emacs here: it keeps the BODY's indentation, which rides the child paragraph's own
   text, and loses only the two delimiter lines, where org's interpreter drops both. Three
   occurrences in `blocks.org`.
19. A top-level fixed-width area's indentation -- `  : x` re-emits as `: x`. Measured to be
   Reason A rather than B, unlike item 18 below: `:value` is `"x"` and `:structure` is NIL, so no
   property carries the two spaces.

**Reason B -- a CHOSEN non-capture (the byte IS present in the tree, just not in a property this
schema reads). Both remaining entries are the same family: the plain-list `:structure` vector.**

9. Malformed lowercase checkbox `- [x]`. `org-element` does not accept lowercase `x` as a
   checkbox state -- its item parser compares the bracket text with a case-sensitive `equal`
   against `"[X]"`, `"[ ]"` and `"[-]"` -- so `:checkbox` comes back `nil`, exactly as for a
   plain non-checkbox item. But `org-list`'s own structure scan DOES capture it, case-insensitively,
   into the per-item tuple's CHECKBOX slot, and the literal `"[x] "` is stripped out of the item's
   paragraph content. So the bytes exist in the tree and this schema declines to read them.

   **The decision, and the design that was rejected.** Capturing this is FEASIBLE and cheap: the
   raw `"[x]"` is reachable in the item's own `:structure` tuple, and surfacing it would need one
   string field on `item` (call it `rawCheckbox`) and would emit no buffer positions whatsoever.
   An earlier draft of this schema argued the opposite -- that capturing it "would mean modeling
   `:structure`", i.e. the whole list-wide, position-keyed vector. That argument was wrong and is
   withdrawn; only one slot of one tuple is needed.

   It is declined on VALUE, not on difficulty. The entire closable surface is ONE input form.
   Measured across all seven bracket shapes: `[X]`, `[ ]` and `[-]` are valid and already fully
   carried by `checkbox`; `[x]` is the only malformed form org's list scan consumes, so it is the
   only one whose bytes go missing; and `[y]`, `[XX]` and `[]` are not consumed at all -- their
   bytes survive verbatim in the item's paragraph text (`"[y] text\n"`), so they were never losses
   to begin with. A `rawCheckbox` field would therefore sit on every `item` node in every
   conformant tree, be 100% redundant with `checkbox` on every well-formed input, and exist for a
   single malformed spelling that the all-files oracle sweep finds in zero of the corpus files.
   That trade is not worth a permanent field in a schema other implementations must satisfy.

   Confirmed against the one authority not consulted until after the decision was drafted:
   `org-element-interpret-data` itself re-emits `- [x] text` as `- text`, discarding the
   malformed bracket bytes -- Emacs's own serializer does not preserve them either. Capturing
   them would therefore make this schema stricter than Emacs on a MALFORMED input, unlike the
   two deliberate interpret-data beats named earlier in this section (block reindentation,
   counter renumbering), both of which are well-formed, common cases.
10. Alphabetic list counters -- `1. [@c]`. NEW, surfaced by closing the old item 10 (`:counter` is
   now carried by the `counter` field, see section 4). `:counter` is an INTEGER, and
   `org-element`'s item parser converts a letter to its alphabet index, so `1. [@c]` and
   `1. [@C]` both report `3`, indistinguishable from `1. [@3]`. The raw `"c"`/`"C"` survives only
   in the same `:structure` tuple as item 9, in its COUNTER slot, and is declined for the same
   reason: a second permanently-redundant field for a second single input form. (Note the example
   deliberately uses a NUMERIC bullet. `a. [@c]` produces no `item` node at all, because
   alphabetical bullets require `org-list-allow-alphabetical`, which is `nil` by default.)
18. A top-level list's own BULLET-LINE indentation -- `  - a` re-emits as `- a`. THIRD member of
   the `:structure` family, and it is Reason B rather than A for a measured reason: `  - a` keeps
   the column in org-element's structure vector, `((1 2 "- " nil nil nil 7))`, so the byte is in
   org's tree and this schema declines to read it. Declined on the same ground as items 9 and 10
   -- a permanent field for one input form -- and org's own interpreter drops it too. Nesting
   indentation IS reconstructible and is emitted (parent bullet width per level, pinned by
   `conformance/list-nested-by-indent`); only the OUTERMOST list's own indent is lost.

11. Headline-line trailing whitespace, the NO-tags case -- `**  ` re-emits as `** `, and
   `* x  ` as `* x`. Reason A, numbered after the Reason-B block only because it surfaced
   later (2026-08-07, while `conformance/headline-empty-title` was being built): the title
   region is trimmed into `:raw-value`/`:title` and the trailing run survives in NO property.
   `org-element-interpret-data` itself emits the single-separator form -- measured on that
   fixture, 12 bytes in, 11 out, the one divergence exactly at the empty-title line. The
   WITH-tags sibling of this byte class is item 3 (tag-column padding); this is what is lost
   when there is no tag group for item 3 to blame. Pinned by `conformance/headline-empty-title`
   in `RendererConformanceTests.schemaLossCases`.
12. Inline-src-block header normalization -- `src_py[  p  ]{x}` re-emits as `src_py[p]{x}`, and
   `src_py[]{x}` as `src_py{x}`. Reason A, and an unusually clean example of the "upstream
   normalization" half of that definition: `org-element-inline-src-block-parser` stores
   `(and (org-string-nw-p p) (replace-regexp-in-string "\n[ \t]*" " " (org-trim p)))`, so the
   trim, the newline collapse, and the empty-to-nil conversion all happen inside org before this
   schema sees anything. `:parameters` is the ONLY property carrying those bytes and it carries
   the normalized form. Emacs's own interpreter emits exactly what `renderOrg` emits here, so
   there is nothing to beat and nothing to recover. Note the asymmetry with the BODY, which is
   not normalized at all: `src_py{ }` keeps its space. Pinned in the sweep by
   `i30-param-spacing`, `i30-param-empty`, `i30-param-newline` and `i30-body-space`.

   The sibling `inline-babel-call` has NO such loss, and the difference is which property org
   chose to keep. Its `:value` is the whole source text, so `renderOrg` emits it verbatim and
   round-trips byte-exact even where org's own interpreter -- which rebuilds from
   `:call`/`:inside-header`/`:arguments`/`:end-header` -- would apply the identical
   normalization and lose the bytes. Same relationship as `macro`, and for the same reason.
13. Empty caption bracket -- `#+CAPTION[]: x` re-emits as `#+CAPTION: x`. Reason A, and the
   same upstream-normalization shape as item 12: CAPTION is a parsed keyword, so org runs its
   dual value through `org-element--parse-objects`, and an empty range yields no objects. The
   resulting nil is the identical value "no bracket was written" produces, so the two inputs are
   the SAME tree and no renderer can tell them apart. `org-element-interpret-data` drops the
   bracket too, measured (51 bytes in, 49 out). Not shared by `#+RESULTS[]:`, which keeps the
   empty string because RESULTS is not parsed. Pinned by
   `conformance/affiliated-caption-short-empty`, a permanent resident of
   `RendererConformanceTests.schemaLossCases`.


12. Clock-line normalization, Reason A, four byte classes in one line shape (all probed live
   on Emacs 30.2, pinned by `conformance/clock-normalization` in
   `RendererConformanceTests.schemaLossCases`): the keyword's source case (`clock:` matches
   case-folded, the tree holds no case, org's interpreter re-emits `CLOCK:`); internal and
   trailing whitespace (`CLOCK:  [ts]`, `CLOCK: [ts]   ` -- spacing lives in no property);
   duration spacing/format (` => 1:07` re-emits through org's `%2s:%02s` as ` =>  1:07`,
   single-digit hours padded); and the dropped tab-duration (`=>\t1:07` passes the clock LINE
   regexp but fails the parser's literal `"=> "` search, so `:duration` is nil and the bytes
   after the range are in NO property -- org's own interpreter re-emits the line without
   them, status running).

`renderOrg` MUST be byte-exact on everything else -- including block content indent, headline
body indent, list numbering, multi-blank lines, inline spacing (`postBlank`), all text, and NUL
bytes. These are retained in the tree as literal string content (`:value`, `:bullet`, `postBlank`
counts), so nothing prevents exact reproduction, and Layer 2 requires it. (The "multi-blank
lines" claim specifically depends on `preBlank`, now emitted on `headline`, `item`, and
`footnote-definition` -- the only three types `org-element` itself tracks `:pre-blank` on. Blank
lines immediately before one of those three node types were not recoverable before that field
was added, so this claim did not hold then; it holds now.)

**Two renderer obligations the newly-closed fields create.** Both are places where carrying
`org-element`'s own representation faithfully means the renderer must do something specific, and
getting either wrong produces output that looks plausible and is wrong:

- **`tblfm` is stored in REVERSE source order**, so a renderer emits the formula lines in reverse
  of the array. This is not a quirk of this schema: `org-element`'s table parser builds the list
  with `push` during a forward scan, and Emacs's own table interpreter re-emits it through an
  explicit `(reverse ...)`. Emit the array in order and every multi-formula table comes out
  backwards.
- **A `line-break` node owns its newline.** The renderer emits `\\` plus the newline FROM that
  node, and must not also emit a line ending for the line it terminates, or the newline is
  doubled. Again this is `org-element`'s own convention, not an invention here: its line-break
  interpreter returns the literal three-character string `\\` followed by a newline.

**Byte-exactness is now asserted by two suites, read as a pair.**
`Tests/OrgSwiftTests/RendererConformanceTests.swift` renders every checked-in `expected.json`
and compares RAW bytes against `input.org` (no normalizer -- measured: the one conformance case
exercising a Reason-A loss, item 8's pin, sits in that suite's permanent `schemaLossCases`
bucket rather than behind a normalizer), and `RoundTripTests.swift` asserts the full
`renderOrg(parseOrg(text))` loop on the real-world files, byte-exact for files hitting no loss
and normalized per-file for exactly the losses a file demonstrably hits (its
`lossAnnotatedFiles` documents which, with a vacuity guard on every annotation). Items 1, 2, 3
and 5 of the list above all have real vendored customers exercising them. A paragraph in this
spot used to say no test asserted this contract; that stopped being true when the renderer
landed.

**Why this is not "parity with `org-element-interpret-data`'s output".** `InterpretDataRoundTripTests`
(see that suite's docstring) characterizes `org-element`'s OWN serializer, `org-element-interpret-data`
-- it is evidence about Emacs's unparser, not a definition of what `renderOrg` must produce. Its
divergence set mixes two different things: Reason A items above (genuinely
unrecoverable from any tree built on `org-element`, this schema included) AND re-emit
conventions that are
NOT information loss -- block/property-drawer reindentation and ordered-list counter renumbering.
This schema's tree retains both of those as literal string content, so `renderOrg` both can and
must reproduce them exactly. Beating `interpret-data` on block indent and list renumbering is
intentional -- this project's round-trip is stricter than Emacs's own serializer on those two
dimensions, not a bug to "fix" toward interpret-data parity.
