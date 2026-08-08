# Third-party corpus notice

This conformance suite uses real-world `.org` files as a smoke-test corpus (Layer 2, round-trip
fidelity, and Layer 3, oracle-diff against Emacs). This file records exactly where each file
came from, so provenance and licensing stay auditable.

Two kinds of corpus:

- **Vendored** (`real/`) - permissively licensed (MIT), copied into this repo
  byte-for-byte, each source's own `LICENSE` file copied alongside it. Safe to commit.
- **Fetch-only** (`real-fetched/`, gitignored) - copyleft licensed (GNU FDL,
  GPLv3), downloaded on demand by `harness/fetch-corpus.sh`, never committed to this repo.

All files were fetched with `curl`/`git clone` against a specific commit, not through a tool
that reflows or re-encodes text, because Layer 2's entire premise is exact, byte-for-byte
round-trip fidelity - a re-encoded or reformatted copy would defeat the test it is used in.

## Vendored (MIT) - `real/`

### `org-mode-samples/`

- Source: https://github.com/gitonthescene/org-mode-samples
- Commit: `778c091072b83e012ae966ea7c68f94be5279514`
- License: MIT, copyright (c) 2021 gitonthescene (see `LICENSE` in this directory)
- Files (copied from the repo's `v0.0/` directory, whole files, unmodified):
  `blocks.org`, `headings.org`, `keywords.org`, `lists.org`, `pathological.org`, `tags.org`,
  `text.org`
- **Known quirk**: every file in this set contains embedded NUL (`0x00`) bytes - 45 in
  `blocks.org`, 26 in `headings.org`, 16 in `keywords.org`, 5 in `lists.org`, 2 in
  `pathological.org`, 23 in `tags.org`, 49 in `text.org`. This was verified byte-identical via
  two independent fetch paths (`raw.githubusercontent.com` and the GitHub contents API's
  base64 payload), so it is a genuine feature of the upstream repository, not a fetch or
  encoding artifact introduced here. It is left untouched because "vendor exactly what
  upstream has" is the point of this corpus; a parser/renderer that cannot round-trip a stray
  NUL byte has found a real bug, not a corpus bug. No other whitespace anomaly (no CRLF, no
  BOM) was found in this source; a single trailing-whitespace line each in `blocks.org` and
  `headings.org` is likewise preserved as-is.

### `go-org-testdata/`

- Source: https://github.com/niklasfasching/go-org
- Commit: `2f088a12697ba4dad46c2c2084db3ae1707830fb`
- License: MIT, copyright (c) 2018 Niklas Fasching (see `LICENSE` in this directory)
- Files (copied from the repo's `org/testdata/` directory, whole files, unmodified):
  `blocks.org`, `captions.org`, `east_asian_line_breaks.org`, `footnotes.org`,
  `footnotes_in_headline.org`, `headlines.org`, `hl-lines.org`, `inline.org`,
  `keywords.org`, `latex.org`, `lists.org`, `misc.org`, `options.org`, `paragraphs.org`,
  `tables.org`
- No embedded NUL bytes, no CRLF, no BOM; every file ends with a trailing LF.
- These are the test corpus of go-org, one of the parsers this project benchmarks against
  (`bench/competitors/go-org/`). Vendoring a competitor's own test corpus and grading this
  parser node-for-node against `org-element` on it is deliberate: it exercises exactly the
  grammar corners another implementer considered worth testing, with no selection bias from
  this project. `inline.org` is the file that forced `#+LINK:` abbreviation expansion to be
  implemented (see `expandingLinkAbbrev` and the sweep's `lab-*` cases).

### `doomemacs-docs/`

- Source: https://github.com/doomemacs/core (repository was renamed from
  `doomemacs/doomemacs`; `doomemacs/core` is the canonical name as of this fetch)
- Commit: `8a301d98d0d6d1aa7c54a8f8df48de7b2c886b2e`
- License: MIT, copyright (c) 2014-2026 Henrik Lissner (see `LICENSE` in this directory)
- Files (copied from the repo's `docs/` directory, whole files, unmodified): `appendix.org`,
  `contributing.org`, `examples.org`, `faq.org`, `getting_started.org`, `index.org`
- No embedded NUL bytes, no CRLF, no BOM. One trailing-whitespace line each in `appendix.org`
  and `contributing.org`, preserved as-is. These are real user-facing documentation files, so
  they exercise headings, source blocks, links, tables, lists, and footnotes at a scale and
  style the small synthetic `org-mode-samples` files do not.
- **Known quirk**: `examples.org` lines 182-184, inside a `#+begin_src emacs-lisp` block, contain
  the literal text `Copyright © 2022 Free Software Foundation, Inc.` and
  `License GPLv3+: GNU GPL version 3 or later`. This is not a license grant on this file or this
  repository - it is the quoted `mkdir --help` banner text, sitting inside a Lisp docstring for a
  Doomscript reimplementation of GNU coreutils `mkdir` that Doom's own documentation uses as a
  worked example of its CLI framework. It is byte-identical to the upstream file, and upstream
  (`doomemacs/core`) is MIT-licensed, same as the rest of this directory (see above). Preserved
  as-is because vendoring exactly what upstream has is the point of this corpus. Noted here so an
  automated license scanner that greps this string and flags GPLv3 text inside an MIT repository
  has a documented, already-checked answer instead of a fresh investigation.

## Sources considered and rejected

Two of the four MIT candidates named in the original corpus plan turned out not to qualify on
inspection - noted here so the decision is not silently repeated or silently forgotten:

- **`daviwil/emacs-from-scratch`** - has no `LICENSE` file at all, in any form, anywhere in the
  repository. Its `README.org` says the config is meant to be an example "you can copy from
  directly," which is informal permission for personal use, not a license grant that permits
  redistribution inside another project's repository. Not vendored.
- **`PoiScript/orgize`** (`tests/`) - contains no standalone `.org` fixture files anywhere in
  the repository; its org-mode test content lives as inline string literals inside `tests/*.rs`
  and `examples/*.rs`. There was nothing to vendor as a "whole file."

## Fetch-only (GPL/GFDL) - `real-fetched/` (gitignored, not in this repo)

Populated on demand by `harness/fetch-corpus.sh`. Never vendored here because both licenses are
copyleft in a way MIT is not; keeping them fetch-only avoids any question about this repository's
own (permissive) license applying to their content.

### `worg/`

- Source: https://git.sr.ht/~bzg/worg (the org-mode community manual/wiki)
- License: GNU Free Documentation License v1.3 or later (prose), GNU GPLv3 or later (code
  examples and stylesheets) - see the repository's own `LICENSE.org`
- Files fetched: `index.org`, `agenda-optimization.org`, `gtd-software-comparison.org`,
  `contributors.org`, `org-8.0.org`
- The exact commit fetched is recorded in `PROVENANCE.txt`, written by the fetch script at
  fetch time (a shallow clone tracks the `master` branch, not a pinned commit, so provenance is
  captured dynamically rather than hardcoded here).

### `org-mode-testing/`

- Source: https://github.com/bzg/org-mode.git (mirror of the official GNU Savannah `org-mode`
  repository; `bzg` is a former org-mode maintainer and this mirror tracks upstream closely)
- License: GPLv3 (org-mode is part of GNU Emacs) - see the repository's own `COPYING`
- Files fetched: `testing/examples/babel.org`, `testing/examples/links.org`,
  `testing/examples/agenda-file.org`, `testing/examples/include.org`,
  `testing/examples/no-heading.org`, `testing/examples/macro-templates.org`
- Same provenance note as above: exact commit recorded in `PROVENANCE.txt` at fetch time.

## Ideas vs. code

Everything above governs the test corpus. This section governs `Sources/OrgSwift`, and records
one fact that matters for the MIT license on this repository: no code from any copyleft org-mode
parser was copied into it.

`org-element.el` (GPLv3+, part of GNU Emacs) is the reference this suite grades against, and
`harness/oracle-dump.el` calls it as an external program via Emacs itself - it is never vendored,
linked, or transcribed. Other GPL and AGPL parsers in other languages were read only to
understand behaviour that the written spec leaves ambiguous, never copied. Where prior art
influenced this parser it was at the level of design ideas, from MIT and BSD-3 licensed projects
whose licenses permit reuse of the source itself.

The practical consequence: the MIT grant in `LICENSE` covers everything in this repository
without a copyleft obligation riding along underneath it.
