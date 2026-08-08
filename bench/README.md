# bench - the organism benchmark harness

Measures `parseOrg` throughput, and (under `competitors/`) the same measurement for other
org-mode parsers, on identical bytes. The published results and their interpretation live in
`../BENCHMARKS.md`; this directory is the machinery that produces them.

This is a separate Swift package from the parser on purpose: the published `OrgSwift` library
imports nothing and ships no executable, and the harness consumes it exactly the way any
consumer does - through the product.

## Layout

    bench/
      Package.swift            this harness (orgbench executable)
      Sources/orgbench/        timing runner + synthetic corpus generator
      fetch-bench-corpus.sh    fetches the large GPL real-world files (gitignored output)
      corpus/synthetic/        `orgbench gen` output (gitignored, deterministic)
      corpus/fetched/          fetch script output (gitignored, GPL - never commit)
      competitors/             one self-timing runner per rival parser
      results/                 dated TSV result files - the receipts behind BENCHMARKS.md

## Running

    cd bench
    swift build -c release
    ./.build/release/orgbench gen corpus/synthetic
    bash fetch-bench-corpus.sh
    ./.build/release/orgbench run corpus/synthetic/*.org corpus/fetched/*.org ../real/*/*.org

Output is TSV: file, bytes, scalars, iterations, median ns/parse, MAD, min, MiB/s.

## Measurement protocol (applies to every runner, ours and theirs)

1. **Parse only.** The file is read and decoded before the timed loop. No I/O, no JSON
   serialization, no rendering inside a measured iteration.
2. **Native tree.** Each parser builds its own AST, whatever that is. No adapter code runs in
   the timed loop. This measures each parser doing its own job, not our job.
3. **Self-timed.** Each runner times itself with its language's monotonic clock and prints
   per-iteration nanoseconds. Process startup, JIT warmup, and interpreter boot never enter a
   number. (`hyperfine`-style whole-process timing would hand compiled languages a startup
   penalty that has nothing to do with parsing.)
4. **Warmup, then median.** Unmeasured warmup runs first; the reported figure is the median
   over enough iterations to fill the time budget, with MAD as the noise bar. Medians because
   a laptop's background load poisons a mean.
5. **Single-threaded.** One document, one thread, for every parser.
6. **Same bytes.** Every parser gets the identical file list: the synthetic profiles, the
   fetched real-world files, and the vendored `real/` corpus.

## The corpus

- `corpus/synthetic/syn-*.org` - seven deterministic ~1 MiB profiles, each stressing one
  region of the grammar: prose, emphasis, tables, lists, links, outline, radio targets.
  Regenerate with `orgbench gen`; the same seed always produces the same bytes.
- `corpus/fetched/` - org-mode's own manual (~1.2 MB) and guide, the largest well-known real
  org documents. GPL, fetched on demand, never vendored.
- `../real/` - the 13 vendored MIT real-world files the conformance suite already grades.

## Honest limits

- Speed says nothing about correctness. The accuracy side of the story is the conformance
  suite at the repo root, and the two are published together deliberately: a fast parser that
  builds a wrong tree is fast at something else.
- All numbers are from one machine, stated in BENCHMARKS.md. Cross-machine comparisons of
  absolute MiB/s are meaningless; the ratios are the result.
