# Changelog

Notable changes to the `OrgSwift` Swift package. The conformance corpus, the schema and the
harness are versioned by the repository rather than by these tags, and change far more often
than the library's API does.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versioning is
[semantic](https://semver.org/), with the pre-1.0 caveat that the API is still being shaped: a
breaking change moves the MINOR number while the major is 0.

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

[0.3.0]: https://github.com/nhannht/organism/releases/tag/v0.3.0
[0.2.0]: https://github.com/nhannht/organism/releases/tag/v0.2.0
[0.1.1]: https://github.com/nhannht/organism/releases/tag/v0.1.1
[0.1.0]: https://github.com/nhannht/organism/releases/tag/v0.1.0
