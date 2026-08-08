#!/usr/bin/env bash
# run-all.sh - drives every runner (organism + competitors) over the whole corpus through
# the shared sample protocol (see bench/README.md), reduces the raw samples to median/min,
# and writes one TSV under results/.
#
# Usage:
#   bash bench/run-all.sh [output.tsv]
# Environment:
#   WARMUP      unmeasured runs per file (default 3; JIT runners raise their own floor)
#   MIN_TIME    measuring budget per file per runner, seconds (default 1.0)
#   RUNNERS     space-separated subset to run (default: all five)
#   FILES       space-separated corpus subset (default: synthetic + fetched + ../real)
#   SKIP_BUILD  non-empty skips the build step - for resuming an interrupted sweep with
#               binaries that must stay the bytes the earlier rows measured

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WARMUP="${WARMUP:-3}"
MIN_TIME="${MIN_TIME:-1.0}"
RUNNERS="${RUNNERS:-organism orgize go-org uniorg org-element}"
OUT="${1:-$ROOT/results/$(date +%Y-%m-%d)-all.tsv}"

mkdir -p "$ROOT/results"

if [ -n "${FILES:-}" ]; then
  read -r -a FILES <<< "$FILES"
else
  FILES=()
  for f in "$ROOT"/corpus/synthetic/*.org "$ROOT"/corpus/fetched/*.org "$ROOT"/../real/*/*.org; do
    [ -f "$f" ] && FILES+=("$f")
  done
fi
if [ "${#FILES[@]}" -eq 0 ]; then
  echo "no corpus files found - run 'orgbench gen corpus/synthetic' and fetch-bench-corpus.sh first" >&2
  exit 1
fi

echo "building runners..." >&2
[ -n "${SKIP_BUILD:-}" ] && RUNNERS_TO_BUILD="" || RUNNERS_TO_BUILD="$RUNNERS"
for r in $RUNNERS_TO_BUILD; do
  case "$r" in
    organism) (cd "$ROOT" && swift build -c release >/dev/null) ;;
    orgize) (cd "$ROOT/competitors/orgize" && cargo build --release --quiet) ;;
    go-org) (cd "$ROOT/competitors/go-org" && go build -o go-org-runner.bin .) ;;
    uniorg) (cd "$ROOT/competitors/uniorg" && pnpm install --silent) ;;
    org-element) : ;;
  esac
done

{
  printf '# date: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '# machine: %s, %s\n' "$(sysctl -n machdep.cpu.brand_string 2>/dev/null || uname -m)" \
    "$(sw_vers -productName 2>/dev/null || uname -s) $(sw_vers -productVersion 2>/dev/null || uname -r)"
  printf '# warmup: %s  min_time: %ss\n' "$WARMUP" "$MIN_TIME"
  printf '# swift: %s\n' "$(swift --version 2>/dev/null | head -1)"
  printf '# rustc: %s\n' "$(rustc --version 2>/dev/null || echo n/a)"
  printf '# go: %s\n' "$(go version 2>/dev/null || echo n/a)"
  printf '# node: %s\n' "$(node --version 2>/dev/null || echo n/a)"
  printf '# emacs: %s\n' "$(emacs --version 2>/dev/null | head -1 || echo n/a)"
  printf 'runner\tfile\tbytes\titers\tmedian_ns\tmin_ns\tmib_s\n'
} > "$OUT"

# measure NAME FILE CMD... - runs CMD FILE WARMUP MIN_TIME, reduces samples, appends a row.
# A runner that exits non-zero (e.g. a parser that refuses the file) records FAIL rather
# than aborting the sweep: a refusal is a benchmark result, not a harness error.
measure() {
  local name="$1" file="$2"
  shift 2
  local bytes base samples err
  bytes=$(wc -c < "$file" | tr -d ' ')
  base=$(basename "$file")
  samples=$(mktemp)
  err=$(mktemp)
  if ! "$@" "$file" "$WARMUP" "$MIN_TIME" > "$samples" 2> "$err" || ! [ -s "$samples" ]; then
    printf '%s\t%s\t%s\tFAIL\t-\t-\t-\n' "$name" "$base" "$bytes" >> "$OUT"
    sed 's/^/    /' "$err" | head -3 >&2
    rm -f "$samples" "$err"
    return 0
  fi
  # One awk pass for every statistic. The previous `sort | head -1` for the minimum died of
  # SIGPIPE under `set -o pipefail` the first time a fast runner produced more samples than a
  # pipe buffer holds - head exited, sort got the signal, pipefail made 141 the sweep's exit.
  sort -n "$samples" | awk -v b="$bytes" '
    {a[NR]=$1}
    END{
      med = (NR%2) ? a[(NR+1)/2] : (a[NR/2]+a[NR/2+1])/2
      printf "%d\t%d\t%d\t%.2f\n", NR, med, a[1], (b/1048576)/(med/1e9)
    }' | while IFS=$'\t' read -r iters median min mib; do
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$base" "$bytes" "$iters" "$median" "$min" "$mib" >> "$OUT"
  done
  rm -f "$samples" "$err"
}

for file in "${FILES[@]}"; do
  echo "=== $(basename "$file")" >&2
  for r in $RUNNERS; do
    echo "  $r" >&2
    case "$r" in
      organism) measure organism "$file" "$ROOT/.build/release/orgbench" sample ;;
      orgize) measure orgize "$file" "$ROOT/competitors/orgize/target/release/orgize-runner" ;;
      go-org) measure go-org "$file" "$ROOT/competitors/go-org/go-org-runner.bin" ;;
      uniorg) measure uniorg "$file" node "$ROOT/competitors/uniorg/main.js" ;;
      org-element) measure org-element "$file" emacs -Q --batch -l "$ROOT/competitors/org-element/runner.el" -- ;;
    esac
  done
done

echo "wrote $OUT" >&2
