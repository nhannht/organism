#!/usr/bin/env bash
# fetch-bench-corpus.sh
#
# Downloads the LARGE real-world org files the speed benchmark runs on, into
# bench/corpus/fetched/ (gitignored). Same hygiene as harness/fetch-corpus.sh:
# these are GPL/GFDL sources, FETCH-ONLY, never vendored into this MIT repo.
#
# The headline file is org-mode's own manual - the largest widely-known org
# document in existence (~1.2 MB) and the fairest possible "real document"
# for every parser under test.
#
# Usage:
#   bash bench/fetch-bench-corpus.sh
#
# Requires: git, a network connection. Idempotent - re-running replaces the
# previous fetch atomically.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="$ROOT_DIR/corpus/fetched"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

# Mirror used because git.savannah.gnu.org has no scriptable raw endpoint;
# bzg/org-mode tracks upstream Savannah closely (bzg is a former org-mode
# maintainer). Same mirror harness/fetch-corpus.sh already uses.
REPO="https://github.com/bzg/org-mode.git"
BRANCH="main"

clone_dir="$WORK_DIR/org-mode"
staging_dir="$WORK_DIR/staged"

echo "Fetching benchmark corpus from $REPO ($BRANCH)..."
git clone --quiet --depth 1 --branch "$BRANCH" "$REPO" "$clone_dir"
commit="$(git -C "$clone_dir" rev-parse HEAD)"
echo "Fetched at commit: $commit"

mkdir -p "$staging_dir"
cp "$clone_dir/COPYING" "$staging_dir/LICENSE"
cp "$clone_dir/doc/org-manual.org" "$staging_dir/org-manual.org"
cp "$clone_dir/doc/org-guide.org" "$staging_dir/org-guide.org"

{
  echo "Source:  $REPO"
  echo "Branch:  $BRANCH"
  echo "Commit:  $commit"
  echo "Fetched: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "Status:  FETCH-ONLY - GPLv3 content, do not vendor into the repo or commit this directory."
  echo "License: see LICENSE in this directory."
} > "$staging_dir/PROVENANCE.txt"

rm -rf "$OUT_DIR"
mkdir -p "$(dirname "$OUT_DIR")"
mv "$staging_dir" "$OUT_DIR"

ls -la "$OUT_DIR"
echo "Done. Fetched files are in $OUT_DIR (gitignored, never commit them)."
