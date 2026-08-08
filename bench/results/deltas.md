# Per-step deltas (median MiB/s, min-time 0.5)

## 1f43e11 perf: skip pass 2 when no radio target (2026-08-08)

| file | before | after | ratio |
|---|---|---|---|
| syn-prose.org | 2.43 | 4.40 | 1.81x |
| syn-tables.org | 2.52 | 4.52 | 1.79x |
| getting_started.org | 2.66 | 4.75 | 1.79x |
| syn-radio.org | 2.50 | 2.52 | 1.01x (has radio targets - two passes stay, by design) |

## bfbe89c + 0bddac9 accuracy fixes (unescape + boundary table), 2026-08-08

Measured under background load (mediaanalysisd at 86%), so medians are noisy; the minimums
track the earlier clean run. No regression: syn-prose min ~4.9-5.4 MiB/s, org-manual.org now
PARSES at ~6.3 MiB/s clean (was: refused entirely). Re-measure on a quiet machine before
publishing any number.

| file | after 1.1 (clean) | after fixes (noisy median / min-derived) |
|---|---|---|
| syn-prose.org | 4.40 | 3.99-4.70 / ~5.4 |
| org-manual.org | refused | 3.87-4.74 / ~6.4 |
| getting_started.org | 4.75 | 5.25 |

## ASCII lanes in the four ICU predicates, 2026-08-08 (quiet machine)

| file | before | after | ratio |
|---|---|---|---|
| syn-prose.org | 4.40 | 7.07 | 1.61x |
| getting_started.org | 4.75 | 7.05 | 1.48x |
| org-manual.org | ~6.3 | 6.77 | ~1.07x |
| syn-emphasis.org | ~3.4 (est) | 4.22 | ~1.2x |

Post-change profile: getBinaryProperties is gone from the flat view. New ranking:
allocation churn ~30%, hashing ~11% (Set<Unicode.Scalar> predicates), iterator ~7%.

Cumulative since session baseline: syn-prose 2.43 -> 7.07 (2.9x), manual refused -> 6.77.

## Border-predicate switches (isPreChar/isPostChar Set -> switch), 2026-08-08

No measurable change: syn-prose 7.07 -> 6.96, manual 6.77 -> 6.86, emphasis 4.22 -> 4.16,
all within run-to-run noise. The Set.contains profile samples evidently come from other
sets (todoSet, object-kind sets). Kept: gated by the same full-scalar equivalence test,
and a switch is the cheaper form even below the noise floor.

## Span strip measured (Phase 1.2 gate), 2026-08-08

Bypassing strippingSpans: syn-prose 141.7 -> 134.4 ms, manual 123.9 -> 116.5 ms - the strip
costs 5-6% of a parse. DEFERRED: whether spans stay in nodes, move to a side table, or
become conditional is exactly the ORG-32 representation decision, and a flag now would
answer that spike by default. Reclaim the 5-6% when ORG-32 settles.

## Phase 2 representation overhaul, 2026-08-08 (five commits)

Per-commit medians, quiet machine unless noted. Cumulative on syn-prose: 7.07 -> 16.4
(2.3x this phase; 6.7x since the campaign baseline of 2.43). org-manual: 6.87 -> ~13.

| commit | syn-prose | syn-emphasis | syn-lists | syn-tables | manual |
|---|---|---|---|---|---|
| flat buffer, Line as view | 7.72 | 4.68 | 7.31 | 4.77 | 6.87 |
| object layer on slices | 11.46 | 6.92 | 10.23 | 7.06 | 10.27 |
| permission bitmasks | 16.37 | 7.98 | 13.45 | 9.02 | 13.35 |
| link-type first-scalar buckets | 16.46 | 7.98 | 13.79 | noise | noise |
| block values as one slice | within noise, structural |

Two regressions caught by measuring, not shipped:

- The first cut of the slice object layer DROPPED syn-prose 7.7 -> 5.9. Profile: the generic
  String(scalars:) over Slice<ScalarSlice> ran unspecialized - protocol-witness next() per
  scalar, Slice.subscript through the stdlib dylib, runtime metadata cache lookups. Fixed with
  two CONCRETE String(scalars:) overloads every existing call site binds to at compile time.
- Replacing the view-append String materialization with a UTF-8-transcode-then-decode buffer
  REGRESSED prose 15-16.6 -> 13.5-14.8 in a paired A/B (the intermediate [UInt8] costs more
  than the appends). Dropped.

The String-backed enums were the hashing share: Set<ObjectKind>.contains hashes the raw
STRING, and permits() runs per scanned position. Now a derived bitmask + bit test, gated by
ObjectRestrictionMaskTests over the full 19x24 cross product.

Post-phase profile (syn-prose): ARC + malloc/free from OrgJSON tree construction is now the
clear top block (~2,200 of ~10k samples: swift_release/retain, DictionaryStorage.deinit,
RawDictionaryStorage.find on node-field inserts), then String building (_StringGuts.append,
UnicodeScalarView.distance, _allASCII), then plainLinkEnd probing. **Phase 3 (native typed
tree construction) is now earned by the numbers**, exactly as the plan gated it.

## Phase 3 native typed-tree construction, 2026-08-08 (three commits)

The parser now builds the generated typed AST (`OrgNode` / `OrgDocument`) natively;
`parseOrg` is that parse re-emitted once through the generated `toJSON()`, and the
`strippingSpans` full-tree rebuild is deleted (spans ride the typed nodes' `span` slot and
the JSON emitter has no code that could write one). `OrgDocument(parsing:)` is the
zero-JSON path and carries ORG-32 spans.

Two numbers per file now exist, and the bench protocol's own rule ("every runner parses to
its NATIVE tree") makes the typed one the headline: before Phase 3 the JSON tree WAS the
native tree, so the historical numbers stay comparable to `--tree json`.

Medians, min-time 0.5, load avg ~4-5 (moderate; re-confirm on a quiet machine):

| file | pre-phase (json) | json after | NATIVE after | native/pre |
|---|---|---|---|---|
| syn-prose.org | 16.4 | 19.5 | 24.5 | 1.5x |
| syn-emphasis.org | 8.0 | 12.1 | 27.5 | 3.4x |
| syn-lists.org | 13.8 | 16.2 | 21.6 | 1.6x |
| syn-tables.org | ~9 | 11.9 | 30.9 | 3.4x |
| syn-links.org | - | - | 26.2 | - |
| syn-outline.org | - | - | 26.9 | - |
| syn-radio.org | - | - | 10.5 | (two real passes, by design) |
| org-manual.org | ~13 | 15.4 | 17.9 | 1.4x |
| org-guide.org | - | - | 22.5 | - |

The node-DENSE files gained the most, which is the diagnosis confirmed: emphasis and tables
are many small nodes, so they were paying the most dictionary storage + boxed-field cost per
byte. Even the JSON path got faster everywhere (typed construction + one flat emission beats
incremental dict building + patch-time copying + the strip pass).

Cumulative on syn-prose since the campaign baseline of 2.43: **10.1x** (native), 8.0x (json).

Post-phase profile (native syn-prose, flat): the dictionary block is GONE
(RawDictionaryStorage.find / DictionaryStorage.deinit no longer appear). Remaining top
costs: node-box ARC (indirect-enum allocation + release), per-iteration tree TEARDOWN
(_ContiguousArrayStorage deinit, swift_arrayDestroy - partly the benchmark consumer's own
cost, every tree must be freed), and leaf String materialization (String.init(scalars:)).
No single dominant block remains; further wins are likely smaller and spread out.
