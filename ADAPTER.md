# Adapting your own parser to this conformance suite

This guide is for anyone writing an org-mode parser in a language other than Swift (Rust, Go,
Python, JavaScript, anything) who wants to check it against this suite. Nothing here needs
Swift or this repo's own `OrgSwift` package. The test material - `conformance/`, `real/`,
`harness/oracle-dump.el` - is plain text, JSON, and Elisp, independent of any host language. If
you already read `SCHEMA.md` and `README.md`, this document adds the practical side: what trips
people up, how to run each layer with your own tools, and the honest limits of the whole
project.

## The contract, in one sentence

Your parser must turn an org-mode source string into a tree matching
`schema/org-node.schema.json` (the machine-readable version of `SCHEMA.md`), and, if you also
write a renderer, turn that tree back into the exact source bytes except for a documented set of
unavoidable losses, enumerated authoritatively in `SCHEMA.md` section 10 (see "Honest limits"
below for a summary, not a substitute). Read `SCHEMA.md` in full before writing code against it.
It is the real spec here, not this document.

## What you are building

Two functions, matching the seam `SCHEMA.md` section 2 defines for `OrgSwift`:

```
parseOrg(source: string) -> tree      # required for Layer 1 and Layer 3
renderOrg(tree) -> string             # required for Layer 2 only
```

You do not need `renderOrg` to run Layer 1 or Layer 3. Build `parseOrg` first.

## Normalization rules that bite

These are the rules most likely to cost you a debugging session, because they are easy to miss
on a first reading of `SCHEMA.md` or easy to get backwards.

1. **`postBlank` is on every node except the bare `text` leaf, always, even when 0.**
   Do not omit it when it is zero, and do not add it to a `text` node. This single field is also
   the only way to recover a space between an inline object and the text right after it on the
   same line (`*bold* text`): the space is not in either string, it lives only in the bold node's
   `postBlank`.
2. **Trailing newlines inside a node's own text are content, not whitespace to trim.** If
   `org-element` includes a `"\n"` inside a paragraph's last text node, or inside a block's
   `value`, keep it exactly. Do not strip trailing newlines "to be clean" - a stripped one is a
   silent, wrong diff against `expected.json`.
3. **A literal block's `value` includes the trailing newline after the last content line, but
   not the `#+end_TYPE` line itself.** A one-line `src-block` body is `"let x = 1\n"`, not
   `"let x = 1"`. This applies to `src-block`, `example-block`, `export-block`, and
   `comment-block` alike.
4. **The `date` and `rep` objects nested inside a `timestamp` are not schema nodes.** They have
   no `"type"` key of their own (except `rep`, where `"type"` is data - the repeater/delay kind,
   like `"+"` or `"--"` - not a node discriminant) and no `postBlank`. Do not treat them like
   every other node in the tree; they are plain nested values describing part of the enclosing
   `timestamp`'s own data.
5. **A link's `description` is `null`, not `[]`, when the link has no description.** This is the
   one field in the schema where `null` and empty-array are meaningfully different - `[[url]]`
   gets `null`; `[[url][]]` (an empty but present description) would get `[]`.
6. **`footnote-reference.children` is absent entirely, not `[]`, when `inline` is `false`.** Only
   an inline footnote reference carries its own object-node children; a labeled reference to a
   separate `footnote-definition` has no `children` key at all.
7. **Section omission is structural, not optional.** A headline immediately followed by a
   sub-headline, with no planning line, no property drawer, and no body text, has NO `section`
   child at all - go straight to the sub-headline. Do not emit an empty `section` node; SCHEMA.md
   section 3 is explicit that it is omitted, not empty.
8. **Runtime `#+TODO:` keywords need a two-pass read.** Scan the whole file for `#+TODO:` lines
   first, build the active keyword set (default `TODO`/`DONE` if none exist), THEN parse
   headlines against that set. A headline's leading word is `todo` only when it is currently a
   member of that set; otherwise it is plain title text, even if it looks like a keyword.
9. **The emphasis border rule is one rule for all six markers** (`*` bold, `/` italic, `_`
   underline, `+` strikethrough, `=` verbatim, `~` code): `PRE MARKER CONTENTS MARKER POST`, no
   internal whitespace touching either marker, `PRE` restricted to whitespace/`-`/`(`/`{`/`'`/`"`/
   line-start, `POST` restricted to whitespace/punctuation/line-end, and `CONTENTS` may not
   itself start or end with whitespace. Get this wrong and `a*b*c` parses as bold when it must
   stay literal.
10. **Block content mode is fixed per block type, decided before consuming contents.** `src` and
    `example` are always literal, never re-parsed. `quote` and `center` hold parsed elements
    (paragraphs, lists, and so on). `verse` holds parsed OBJECTS directly (text markup, links,
    timestamps), not elements - the one block type whose children skip the element layer
    entirely.
11. **Affiliated keywords attach to the very next element with no blank line between them**, and
    become an extra `"affiliated"` key on that element instead of their own standalone `keyword`
    node. A keyword whose name is not a recognized affiliated-keyword name (`TITLE`, `TODO`,
    `AUTHOR`, and so on) never attaches, no matter how close it sits to the next element.
12. **List item boundaries are indentation-relative, not blank-line-relative alone.** A new item
    starts at the same-or-lesser indentation as an existing item's bullet; the item ends at a
    less-indented non-continuation line, two consecutive blank lines, a heading, or end of file.

## Running each layer without Swift

### Layer 1: spec conformance

For each `conformance/<case>/{input.org,expected.json}` pair: read `input.org`, run it through
your `parseOrg`, and compare the result to `expected.json` structurally - object key order does
not matter, array order and every value does. Validate your output against
`schema/org-node.schema.json` first (see `schema/README.md` for commands in Node and Python); a
schema failure means your tree has the wrong shape, which is a faster bug to find than a
structural mismatch against one specific fixture.

You do not need to write any of this yourself to see the loop working today.
`harness/verify-corpus.sh` already runs the identical loop - parse, normalize, diff - using real
Emacs (`harness/oracle-dump.el`) as the stand-in "parser", since this repo's own `OrgSwift`
parser does not exist yet either:

```bash
bash harness/verify-corpus.sh
```

Run against this corpus, it reports `71/71 passed`. That is the exact shape your own parser's
Layer 1 test loop should have once you point it at your `parseOrg` instead of at Emacs.

### Layer 2: round-trip fidelity (only if you also write a renderer)

For every `.org` file under `real/` (and `real-fetched/`, if you ran `harness/fetch-corpus.sh`),
assert `renderOrg(parseOrg(text)) == text`, byte-for-byte, with the exceptions `SCHEMA.md` section
10 documents (summarized, not repeated in full, under "Honest limits" below). `NOTICE.md` records
provenance for every vendored file, including known byte-level oddities (embedded NUL bytes in
`org-mode-samples/`) that are genuine features of the source, not fetch artifacts - your
round-trip needs to survive those too.

### Layer 3: oracle diff against real Emacs

For the same real-world files, run `harness/oracle-dump.el` to get Emacs's own normalized parse,
and compare it structurally against your `parseOrg`'s output on the same file:

```bash
emacs --batch -Q -l harness/oracle-dump.el --eval '(org-swift-dump "real/org-mode-samples/blocks.org")'
```

This is the layer that catches a case where your reading of the spec is subtly wrong on real,
messy input that nobody hand-wrote a fixture for. See `harness/README.md` for the full command
reference for every script in `harness/`, including what each script's stdout shape means and
what to do if `oracle-dump.el` disagrees with a checked-in `expected.json`.

## How to interpret a diff

Two different failures look similar but mean different things:

- **A schema validation failure** (your tree does not match `schema/org-node.schema.json`) means
  your tree has the wrong SHAPE: a missing field, a wrong type, an extra key, a `postBlank` on a
  `text` node, a `children` array where SCHEMA.md wants `null`. Fix the shape first.
- **A structural mismatch against `expected.json`** (right shape, wrong content) means your
  parser read the source correctly enough to produce a valid tree, but got some VALUE wrong: a
  missed `postBlank`, a `todo` keyword that should have been plain text, a `link` `description`
  that should have been `null`.

For a quick, tool-based diff without writing any comparison code yourself, canonicalize both
sides with `jq -S` (recursively sorts object keys so key order never causes a false mismatch)
and diff the canonicalized text - this is exactly what `harness/verify-corpus.sh` does
internally:

```bash
jq -S . your-output.json > /tmp/actual.json
jq -S . conformance/some-case/expected.json > /tmp/expected.json
diff -u /tmp/expected.json /tmp/actual.json
```

## Honest limits

### Layer 1 gaps: see README.md for the full, maintained list

Root `README.md`'s "Type coverage: what the oracle maps today" and "What protects each claim"
sections are the single maintained account of what `harness/oracle-dump.el` maps, what carries a
regression fixture, and what rests only on a one-time audit against `org-element`'s own source.
This document does not repeat that list - an earlier draft did, naming roughly six gaps while
README's grew to cover far more, and the two drifted. Read README directly before assuming a type
or field is safe to skip.

In short, so you know the SHAPE of the gap before reading further: 15 `org-element` types are not
mapped at all yet (`clock`, `entity`, and `special-block` are the three most likely to show up in
an ordinary file - README ranks all 15 by how likely your own files contain one). Of the types
that ARE mapped, 14 carry no conformance fixture at all and rest solely on the one-time audit
(`footnote-reference` and `footnote-definition` among them), and 6 further gaps sit inside
otherwise-fixtured types - a variant or property the 71 fixtures never happen to exercise, such
as `table.el`-flavour tables or the `diary` timestamp kind. None of this shows up as a Layer 1
failure today, because nothing in this corpus asserts it either way - treat every item on
README's list as "not yet checked," not "confirmed correct."

One SCHEMA.md-specific gap is not about type coverage at all, so it is not in README's list
either: property continuation (`:NAME+: value`, the spec's append-to-previous-value form,
SCHEMA.md section 9). The same-day time-range form of a timestamp is NOT a Layer 1 gap at all -
an earlier draft of this document wrongly filed it here; see "The same-day time-range gap,
precisely stated" below for what it actually is (a Layer 2 round-trip loss, not a missing tree
field).

### Layer 2's unavoidable round-trip losses (Rule D)

`SCHEMA.md` section 10 is the single authoritative, maintained list of every confirmed byte that
`renderOrg(parseOrg(source))` cannot reproduce. Treat what follows as a description of the SHAPE
of that list, not a copy of it - section 10 has already grown once, from 6 entries to 15, when an
audit went back and checked areas nobody had looked at yet. A list like this grows whenever
someone actually checks, so do not memorize a count from this document; read section 10 itself.

**Reason A - unrecoverable from any string property.** Either a pure buffer-position loss (this
schema strips `:begin`/`:end` per `SCHEMA.md` section 1, and no other property carries the byte),
or a normalization `org-element` itself performs before this schema ever sees the tree. Two
examples out of section 10's current set: keyword name case (`org-element` upcases it, so the
source's original case is gone), and an affiliated-keyword alias (`#+TBLNAME:` normalizes to
`NAME` before the tree is built, so which spelling the author typed is gone too).

**Reason B - a chosen non-capture.** The byte IS present somewhere in `org-element`'s own parse
tree, just not in a property this schema's curated field set reads. Two examples: a malformed
lowercase checkbox `- [x]` (org-element only recognizes uppercase `X`, a space, or `-` as valid
checkbox states - the raw `"[x]"` text survives only in the list's own `:structure` vector, which
this schema's `item` node does not read), and a `src-block`'s `:switches` flag string (the `-n -r`
after the language on a `#+begin_src elisp -n -r` line, folded into the element but never
surfaced as a schema field).

`renderOrg` must be byte-exact on everything else, including block content indent, headline body
indent, list numbering, multi-blank lines, inline spacing (via `postBlank`), and NUL bytes -
these are retained as literal string content, so nothing prevents exact reproduction.

**If your renderer diverges from source bytes anywhere, check `SCHEMA.md` section 10 by name
before assuming it is your bug.** A divergence not named there might genuinely be a defect in
your own renderer - but it might just as easily be a loss nobody has documented yet, which is
exactly how most of section 10's current entries were found: someone compared bytes, hit a
difference, and went and checked. If you find a real divergence that section 10 does not name,
that is a genuine finding worth reporting, not something to quietly work around in your own code.

### The same-day time-range gap, precisely stated (an earlier draft of this got it wrong)

This schema's `timestamp` node DOES represent a same-day time range fine: `start` and `end` are
both full dates, and a range where they share the same year/month/day but differ in `hour`/
`minute` is an ordinary, already-representable case. An earlier draft of this document claimed
otherwise - that the schema "has no field for one date, two times" - and that claim was wrong;
`schema/org-node.schema.json` needs no new field for this, and if you extended your own tree
shape to add one, you would be solving a problem this schema does not actually have.

The REAL gap is narrower and different in kind: which SOURCE FORM produced that range. `org-mode`
has two ways to write it - a single timestamp with an internal time-time contraction,
`<2026-01-01 Thu 10:00-12:00>`, and a genuine two-full-timestamp range,
`<2026-01-01 Thu 10:00>--<2026-01-01 Thu 12:00>` - and `org-element` tracks which one via its own
`:range-type` property. This schema does not read `:range-type`, so both source forms normalize
to the identical `active-range`/`inactive-range` tree; a renderer cannot tell them apart and so
cannot reproduce the source form byte-for-byte. This is not a missing field in the parsed tree -
it is a Layer 2 round-trip loss, tracked as such in `SCHEMA.md` section 10, Reason B, item 12. If
your own parser needs to preserve which form the author wrote, you will need to add a field for
`:range-type` yourself; this schema does not carry one today.

## Worked example: `keyword-name-attaches-to-table`

`conformance/keyword-name-attaches-to-table/input.org` is two lines:

```
#+NAME: mytable
| a | b |
```

Walking `SCHEMA.md`'s rules against this input:

- The file has no headline, so the whole thing is the document's zeroth `section` (section 3).
- `#+NAME: mytable` immediately precedes the table with no blank line between them, and `NAME` is
  a recognized affiliated keyword, so it does NOT become its own standalone `keyword` node. It
  attaches to the table as an `"affiliated"` key instead (section 5). Since `NAME` is outside
  `org-element-parsed-keywords`, its value is a plain string, `"mytable"`, not a parsed
  object-node array.
- `| a | b |` is one `table` containing one `standard` `table-row`, containing two `table-cell`
  nodes, each with one `text` child (`"a"` and `"b"`) - the `|` padding spaces are a
  corpus-authoring convention, not part of either cell's text (section 4, Tables).
- Every node, from the `document` root down to each `text` leaf, gets a `postBlank` (rule 1
  above) - all `0` here, since nothing in this input has trailing blank lines or inter-object
  gaps to record.

The full expected tree, matching `conformance/keyword-name-attaches-to-table/expected.json`
exactly:

```json
{
  "type": "document",
  "children": [
    {
      "type": "section",
      "children": [
        {
          "type": "table",
          "children": [
            {
              "type": "table-row",
              "kind": "standard",
              "children": [
                { "type": "table-cell", "children": [{ "type": "text", "value": "a" }], "postBlank": 0 },
                { "type": "table-cell", "children": [{ "type": "text", "value": "b" }], "postBlank": 0 }
              ],
              "postBlank": 0
            }
          ],
          "postBlank": 0,
          "affiliated": { "NAME": "mytable" }
        }
      ],
      "postBlank": 0
    }
  ],
  "postBlank": 0
}
```

If your parser's output for this file differs from the above only in the `"affiliated"` key,
re-read rule 11 above and `SCHEMA.md` section 5 - this is the single case in the whole corpus
that exercises affiliated-keyword attachment, so it is worth getting exactly right before moving
on to the rest of the corpus.
