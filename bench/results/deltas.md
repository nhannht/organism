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
