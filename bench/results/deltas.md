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
