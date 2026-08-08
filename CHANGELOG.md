# Changelog

Notable changes to the `OrgSwift` Swift package. The conformance corpus, the schema and the
harness are versioned by the repository rather than by these tags, and change far more often
than the library's API does.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versioning is
[semantic](https://semver.org/), with the pre-1.0 caveat that the API is still being shaped: a
breaking change moves the MINOR number while the major is 0.

## [0.4.0] - 2026-08-09

### Added

- **Zero construct refusals.** The last nine refusals - a non-ASCII scalar at a
  subscript/superscript body or footnote-label boundary - existed because org's answer there
  depends on Emacs's `[:alnum:]` and `[:word:]` character classes, and the parser refused rather
  than guess. Those classes are now enumerated over the full Unicode scalar space in a live
  org-mode buffer (`UnicodeClasses.generated.swift`, drift-gated like every pinned Emacs table),
  the boundaries became decidable everywhere, and the throwing guards came out entirely - the
  functions that carried them are no longer `throws` at all. `SweepTests.knownRefusals` is the
  empty set, re-counted on every run. The depth limit (`OrgError.nestingTooDeep`) remains; it
  refuses pathological nesting, not a construct.
- **`#+LINK:` abbreviation expansion.** Link abbreviations defined in the buffer are collected
  in pass 1 and expanded the way org expands them, including the `%s`/`%h` placeholder forms.
- **Spans on the typed tree.** `OrgSpan` (begin/end plus optional contents range), a `span` slot
  on every generated node, and the patch helpers `settingSpan`/`settingPostBlank`/
  `settingAffiliated`. Span RECORDING is landed for 6 of the 55 construction sites (ORG-32, in
  progress); the type and the slot are stable API.
- **A published benchmark** (repo-level, not API): `bench/` measures parse throughput for
  organism and for orgize, go-org, uniorg and org-element on identical bytes, under a written
  protocol; `bench/accuracy/` grades all five against org-element's own answers on the three
  corpora, through per-competitor adapters bound by written fairness rules. Results and
  interpretation: `BENCHMARKS.md`. Receipts: `bench/results/`.

### Changed

- **Roughly an order of magnitude faster.** One campaign, landed as per-commit measured steps
  (each with its before/after in `bench/results/deltas.md`): the second parse pass is skipped
  when a document defines no radio target; the document is tokenized once into a flat scalar
  buffer and every line is a zero-copy view into it; the object layer parses slices of that
  buffer instead of detached `String`s; the four ICU-backed scalar predicates got ASCII lanes;
  container permission checks test a derived bitmask instead of hashing a `Set`; and the parser
  now builds the generated typed AST natively - `parseOrg` is that parse emitted once through
  `toJSON()`, and the old full-tree span-stripping rebuild is deleted. `OrgDocument(parsing:)`
  is the zero-JSON path. Absolute numbers and the competitor context are in `BENCHMARKS.md`.
- Two optimization attempts were measured as regressions and NOT shipped (a generic
  `String(scalars:)` that ran unspecialized, a UTF-8 transcode buffer that cost more than the
  appends it replaced); they are recorded in `bench/results/deltas.md` so the negative results
  are receipts too.

### Fixed

- **A silent wrong tree.** `blockValue` appended `"\n"` after every line unconditionally, so
  whenever its range reached a final line that has none, the emitted `value` carried a byte that
  is not in the document. Measured against the oracle: `\begin{equation}` / `x` /
  `\end{equation}` with no trailing newline produced
  `"\begin{equation}\nx\n\end{equation}\n"` where org produces the same string without the
  trailing newline.

  Reachable through one of the three callers. The two body callers stop their range before the
  closing line, so a body line always has a line after it and therefore always has a newline -
  which is why this survived. The latex-environment caller includes the closer, and that range
  can end at the last line of the file.

  Both other value builders in the parser already read `hasNewline` per line; this was the lone
  divergence from an idiom the codebase had settled. Five `w4-*` sweep cases cover it, shown able
  to fail rather than merely added: with the old line restored the sweep goes red on
  `w4-latexenv-eof-nonl` and on nothing else.

- The plain-link word boundary is a measured table rather than a heuristic: for every valid
  scalar, does `org-link-plain-re` match right after it in a live org buffer - 3,559 suppressing
  scalars in 366 ranges. The old ASCII-only test linked after dollar, percent and apostrophe
  where org does not, and a guard that predated the real predicate invented refusals on
  org-manual.org's own prose; both are gone.
- Literal block values (`example`, `export`, `src`) comma-unescape their `,#+` and `,*` lines
  the way org does, and the renderer restores the escape exactly.
- An item's extent no longer leaks into a paired block, dynamic-block or drawer body that opens
  inside the item and closes outside it.
- Three class predicates that silently approximated Emacs behaviour with Swift Unicode
  predicates - headline tags, drawer names, citation keys - now consult the measured tables; the
  enumeration showed all three wrong, drawer names on ~960,000 scalars.
- The timestamp matcher transcribes org's actual algorithm - a lax envelope plus independent
  field scrapes - instead of validating a stricter token grammar of its own. A `]` in free text
  closes an active timestamp, junk is tolerated rather than parsed, and repeater/delay are
  scraped from the whole raw value, because that is what org does.

### Notes for consumers

- API is additive only: `OrgSpan`, the `span` slot and the patch helpers are new; nothing
  published in 0.3.1 changed shape. Inputs that used to throw the nine class refusals now return
  org's tree. Minor bump for the API addition, as with 0.2.0.
- `parseOrg` still throws: a CR byte, nesting past the depth limit, and any future guard all
  surface through `OrgError` exactly as before.

## [0.3.1] - 2026-08-08

### Fixed

- A half-typed org document no longer fails to parse. Ten of the parser's eighteen refusals were
  not constructs it could not read: org had an ordinary answer for every one of them, and they
  were held up by two predicates that tested a line's PREFIX where org consults a grammar.

  - **Nine `#+BEGIN` shapes.** A predicate listed three literal spellings - `#+begin:`,
    `#+begin ` and `#+begin` - and was wrong in both directions. `#+BEGIN:` and `#+BEGIN: ` are
    ordinary keywords to org (key `BEGIN`, value `""`); `#+BEGIN` and `#+BEGIN foo` carry no
    colon, so they were never keywords to be confused with, only paragraph text; and an UNPAIRED
    `#+BEGIN: name` is a paragraph exactly as an unterminated `#+begin_example` already was.
    `dynamicBlockBeginLine` already transcribes `org-element-dynamic-block-open-re`, whose
    `[[:word:]]` name requirement is the real discriminator, so the dispatch now asks it and the
    list is deleted.
  - **`#` followed by a TAB.** Refused as "a comment per spec" whose value the schema could not
    carry. Org builds no comment there at all, just a paragraph - `org-element-comment-parser`
    wants a space or end of line after the `#`.

  This is what an editor needs, and it is why it was worth doing: the parser runs after every
  keystroke, and a refusal is not scoped to the offending line - pass 1 reads the whole document,
  so one half-typed block left the entire file with no tree. Measured with 26 org constructs
  typed one character at a time, 455 buffer states: **throws fell from 30 to 1**. The one that
  remains is a deliberate plain-link over-throw, one keystroke wide, that heals on the next
  character. The 26 that previously threw for the whole time it takes to type a dynamic block are
  gone.

- `isUnimplementedElementStart` is deleted. `#\t` was its last branch, and nothing refuses at
  element start any more. Two doc comments it left behind were asserting behaviour that had been
  false for some time - that an indented `: a` or an indented table START throws - and both parse.

### Changed

- `SweepTests.knownRefusals` drops from 18 names to 9, in two groups rather than three. Both
  remaining groups are the same deliberate policy: a non-ASCII scalar at a subscript/superscript
  body boundary (8) or a footnote-label boundary (1), where org's answer depends on character
  classes this project has not measured.
- The sweep corpus gains 5 cases (1,312 to 1,317), pinning `#` against space, TAB, TAB-TAB, bare,
  and after text. The `# ` control is included deliberately: it builds a `comment` where the
  others build paragraphs, so the group can fail rather than merely agree.
- `PublicAPITests` demonstrated a catchable refusal using `#+BEGIN: myblock`, which now parses, so
  it caught its own obsolescence. It uses a non-ASCII footnote label instead - one of the nine
  policy refusals, and `i4-label-uni` in the sweep, so the day it parses two tests go red in the
  same run. Its assertion no longer pins a filename; the contract is that the payload names its
  throw site, not which file that is.

### Notes for consumers

- No API change and no new error case, and nothing that parsed before parses differently. Inputs
  that used to throw now return org's tree. Hence a patch release: this repo moves the MINOR for
  a breaking change while the major is 0.
- Two README figures were stale before this release and are corrected rather than carried
  forward: `swift test` read 57 tests / 14 suites against an actual 60 / 15, and the depth
  bullet's "1,427 inputs" matched neither the corpus (1,445 then, 1,450 now) nor anything else
  derivable. The v0.3.0 entry below repeats that 1,427 and is left as written, since a changelog
  records what was believed at the time.

## [0.3.0] - 2026-08-08

### Added

- `OrgError.nestingTooDeep`, and the depth limit behind it. Input nesting past
  `OrgParser.nestingLimit` is now refused instead of overflowing the stack. This replaces a
  crash, measured rather than theorised: a 250-level nested list killed the process with SIGBUS
  on a 512 KB stack, which is what a non-main `Thread` and a libdispatch worker get, and a
  document 618 headline levels deep died while its tree was being RELEASED - in the caller,
  after `parseOrg` had already returned successfully. A crash is the one outcome a `throws`
  signature cannot express and a caller cannot catch.
- `DepthLimitTests`, which runs its parses on a 512 KB thread it creates itself, because a test
  on the main thread has sixteen times the stack a background parse does and would have passed
  throughout the period the bug was live.
- Continuous integration (`.github/workflows/ci.yml`), covering macOS with the Emacs oracle and
  Linux without it. Both jobs fail if a gate would silently skip.

  The workflow was not green at the v0.3.0 tag itself - three fixes landed after it, none of
  them touching the library: bash instead of the container's dash, and `macos-26` rather than
  `macos-15`, because `PinnedTableDriftTests` compares against Swift's Unicode case data and on
  Apple platforms that data ships with the OS rather than the toolchain. The tag's library code
  is the code CI now passes on.

### Changed

- `parseOrg`'s documentation no longer enumerates the implemented subset. The enumeration had
  gone stale by months - it described a parser that refused priority cookies, tags, links,
  timestamps and every `#+` line, all of which had long since landed - and Swift Package Index
  publishes these comments as the package's hosted API documentation. It now points at the
  answers a test re-derives on every run instead.

### Notes for consumers

- `OrgError` gains a case, so an exhaustive `switch` over it needs a new branch. That is the
  whole of the breaking change, and the reason this is 0.3.0 rather than 0.2.1.
- No parse that succeeded before fails now. The limit sits at 24; the deepest of the 1,427
  inputs in `conformance/`, `real/` and `sweep/` needs 9.

## [0.2.0] - 2026-08-08

### Added

- A typed AST: `OrgDocument`, `OrgNode` and 55 node types, GENERATED from
  `schema/org-node.schema.json` by `harness/regen-ast.py` rather than hand-written, so the types
  cannot drift from the published contract. Required schema fields are non-optional, the eight
  enumerated fields are real enums, and a `switch` over `OrgNode` is exhaustive.
- `OrgDocument(parsing:)` and a `renderOrg(_:)` overload taking the typed tree. The layer is
  purely additive - `parseOrg` and `OrgJSON` are unchanged, and the typed entry points are sugar
  over them, so there is one parser and one renderer rather than two of each.
- Traversal conveniences in the hand-written `OrgAST+Support.swift`, which the generator never
  touches: `walk()`, `allHeadlines`, `allLinks`, `plainText`.
- A drift gate: `swift test` regenerates the AST from the schema and fails on any difference,
  and every one of the 1,432 stored trees is round-tripped through the typed layer.

## [0.1.1] - 2026-08-08

### Fixed

- `OrgJSON` had no integer accessor at all, so a headline's `level`, every `postBlank` and every
  date component were unreachable through the published API - ten schema fields typed as
  `integer`, none of them readable. Added `intValue`, `boolValue`, `doubleValue` and `isNull`.

  Nothing inside the package reads a tree through its own public accessors, so 34 green tests
  could not see it. It surfaced the moment the tagged package was installed into a fresh project,
  where the README's own example failed to compile. `PublicAPITests` now consumes the library the
  way a consumer does, through `import OrgSwift` and nothing else.

## [0.1.0] - 2026-08-08

First tagged release. The package had been public since 2026-07-25; this is the point it became
installable by version.

### Added

- `parseOrg(_:todoKeywords:)`, matching `org-element`'s own tree on all 120 conformance cases
  and all 13 vendored real-world files.
- `renderOrg(_:)`, re-emitting `input.org` byte-for-byte from the stored tree on 115 of 120
  cases. The other five are permanent by measurement: each pins bytes no tree built on
  `org-element` can carry.
- `OrgJSON`, the `Codable` value type carrying the schema's shape, and `OrgError`.
- Declared platform minimums. The library itself imports nothing - not Foundation, not Darwin -
  so it is portable everywhere Swift runs; the minimums come from the test target's
  swift-testing floor.

[0.4.0]: https://github.com/nhannht/organism/releases/tag/v0.4.0
[0.3.1]: https://github.com/nhannht/organism/releases/tag/v0.3.1
[0.3.0]: https://github.com/nhannht/organism/releases/tag/v0.3.0
[0.2.0]: https://github.com/nhannht/organism/releases/tag/v0.2.0
[0.1.1]: https://github.com/nhannht/organism/releases/tag/v0.1.1
[0.1.0]: https://github.com/nhannht/organism/releases/tag/v0.1.0
