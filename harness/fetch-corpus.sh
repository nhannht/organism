#!/usr/bin/env bash
# fetch-corpus.sh
#
# Downloads the GPL/GFDL org-mode corpus sources used by the Layer 1/2/3
# conformance suite. These files are FETCH-ONLY: their licenses (GNU FDL,
# GPLv3) are copyleft and are not compatible with vendoring source text
# straight into this repo the way the MIT-licensed corpus under
# real/ is. Instead this script re-downloads them on demand
# into real-fetched/, which is gitignored and must never be
# committed.
#
# Usage:
#   bash harness/fetch-corpus.sh
#
# Requires: git, a network connection. Safe to run more than once - each
# run wipes and re-clones its own working dir, so it is idempotent.
#
# This script is NOT invoked by `swift test`. Layer 3 (OracleDiffTests)
# only reads real/ (vendored) plus whatever oracle JSON the
# Emacs dump script has produced; it never depends on this script having
# been run. Use it manually when you want a wider fetch-only corpus to
# spot-check the parser against, or to refresh testing/examples files
# from upstream org-mode.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="$ROOT_DIR/real-fetched"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

mkdir -p "$OUT_DIR"

# fetch_source SLUG REPO_URL BRANCH LICENSE_PATH_IN_REPO FILE...
#
# Shallow-clones REPO_URL at BRANCH into a scratch dir, copies
# LICENSE_PATH_IN_REPO plus each listed FILE into
# real-fetched/SLUG/, and writes a PROVENANCE.txt recording
# the exact commit fetched (shallow clones track a moving branch, not a
# pinned SHA, so the resolved commit is recorded at fetch time instead).
#
# Publishes atomically: every step below builds into a STAGING directory
# under $WORK_DIR (already covered by the top-level EXIT trap), and
# real-fetched/SLUG/ is only replaced once staging is fully complete,
# PROVENANCE.txt included. Under `set -e`, any failing step - a missing
# upstream file, a network drop mid-clone - aborts before that final swap,
# so SLUG's directory is either the untouched previous fetch or does not
# exist yet, never a partial new one. This matters because SLUG holds
# copyleft (GPL/GFDL) content: a half-written directory with some files
# copied and no PROVENANCE.txt would leave that content on disk with no
# license/commit record at all, which is exactly the hygiene this repo's
# real/ vs. real-fetched/ split exists to prevent.
fetch_source() {
  local slug="$1" repo_url="$2" branch="$3" license_path="$4"
  shift 4
  local files=("$@")
  local clone_dir="$WORK_DIR/$slug"
  local staging_dir="$WORK_DIR/$slug.staged"
  local dest_dir="$OUT_DIR/$slug"

  echo "=== $slug ==="
  echo "Source: $repo_url (branch: $branch)"

  rm -rf "$staging_dir"
  git clone --quiet --depth 1 --branch "$branch" "$repo_url" "$clone_dir"
  local commit
  commit="$(git -C "$clone_dir" rev-parse HEAD)"
  echo "Fetched at commit: $commit"

  mkdir -p "$staging_dir"
  if [ -f "$clone_dir/$license_path" ]; then
    cp "$clone_dir/$license_path" "$staging_dir/LICENSE"
  else
    echo "WARNING: no license file found at $license_path - skipping this source's license copy" >&2
  fi

  local f
  for f in "${files[@]}"; do
    mkdir -p "$staging_dir/$(dirname "$f")"
    cp "$clone_dir/$f" "$staging_dir/$f"
  done

  {
    echo "Source:  $repo_url"
    echo "Branch:  $branch"
    echo "Commit:  $commit"
    echo "Fetched: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "Status:  FETCH-ONLY - copyleft license, do not vendor into the repo or commit this directory."
    echo "License: see LICENSE in this directory."
  } > "$staging_dir/PROVENANCE.txt"

  # Staging is complete (clone, license, every file, provenance all succeeded) - publish
  # atomically. rm+mv rather than mv-over-existing, since dest_dir may already hold a prior
  # fetch of this same slug.
  rm -rf "$dest_dir"
  mv "$staging_dir" "$dest_dir"

  echo "-> $dest_dir (${#files[@]} files)"
  echo
}

echo "Fetching GPL/GFDL org-mode corpus sources into $OUT_DIR"
echo "These are FETCH-ONLY: real-fetched is gitignored, never commit it."
echo

# --- Worg: the org-mode community manual/wiki. GNU FDL 1.3+ for prose, ---
# --- GPLv3+ for code examples and stylesheets (see its LICENSE.org).   ---
fetch_source "worg" "https://git.sr.ht/~bzg/worg" "master" "LICENSE.org" \
  "index.org" \
  "agenda-optimization.org" \
  "gtd-software-comparison.org" \
  "contributors.org" \
  "org-8.0.org"

# --- org-mode official test corpus. Part of GNU Emacs, GPLv3. ---
# --- Mirror used because git.savannah.gnu.org has no browsable raw ---
# --- file endpoint suitable for scripting; bzg/org-mode tracks the ---
# --- upstream Savannah repo closely (bzg is a former org-mode maintainer). ---
fetch_source "org-mode-testing" "https://github.com/bzg/org-mode.git" "main" "COPYING" \
  "testing/examples/babel.org" \
  "testing/examples/links.org" \
  "testing/examples/agenda-file.org" \
  "testing/examples/include.org" \
  "testing/examples/no-heading.org" \
  "testing/examples/macro-templates.org"

echo "Done. Fetched files are in $OUT_DIR (gitignored, never vendor these into real)."
