#!/usr/bin/env bats

# vim: set ft=bash
set -euo pipefail

load "./helpers.sh"

setup() {
  SCRIPTDIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" > /dev/null 2>&1 && pwd)"
  SCRATCH_HOME="$(cd "${SCRIPTDIR}/.." > /dev/null 2>&1 && pwd)"
}

@test "no smart quotes or em dashes (anti-slop)" {
  local matches

  matches="$(
    git -C "$SCRATCH_HOME" ls-files \
      | grep -v '^\.git/' \
      | LC_ALL=C perl -n \
        -e 'BEGIN{$|=1} $bad = qr/[\x{2018}\x{2019}\x{201C}\x{201D}\x{2014}]/; if (/$bad/) { print "$ARGV:$.:$_" }' \
        --
  )"

  if [[ -n "$matches" ]]; then
    echo "Found smart quotes or em dashes (Unicode punctuation) in tracked files." >&2
    echo "These characters look innocent but break shells and diffs." >&2
    echo >&2
    echo "Matches (file:line:contents):" >&2
    echo "$matches" >&2
    echo >&2
    echo "Fix: replace with plain ASCII: ' \" and -" >&2
    return 1
  fi
}

#-------------------------------------------------------------------------------
# Anti-slop check: no AI attribution in unpushed commits
#
# Walks the commits between the current branch's upstream (or origin/main
# as a fallback) and HEAD, scanning each commit message for AI-attribution
# slop: Co-Authored-By lines naming AI vendors, "Generated with..." footers,
# the robot emoji marker, and similar.
#
# Comparison base resolution (least-surprising semantics):
#   1. SCRATCH_SLOP_BASE env var if set (escape hatch for special cases)
#   2. The current branch's upstream tracking ref (@{upstream})
#   3. origin/main as a fallback if no upstream is set
#   4. Skip if origin doesn't exist or no comparable ref is available
#
# This catches slop:
#   - locally before push (most common case)
#   - in CI for any commits between the PR branch and main
#   - on main itself for any commits since the last `git push`
#-------------------------------------------------------------------------------
@test "no AI attribution in unpushed commits" {
  # No origin remote -> nothing to compare against, skip cleanly
  if ! git -C "$SCRATCH_HOME" remote get-url origin > /dev/null 2>&1; then
    skip "no origin remote configured"
  fi

  local base
  if [[ -n "${SCRATCH_SLOP_BASE:-}" ]]; then
    base="$SCRATCH_SLOP_BASE"
  elif git -C "$SCRATCH_HOME" rev-parse --verify --quiet '@{upstream}' > /dev/null 2>&1; then
    base='@{upstream}'
  elif git -C "$SCRATCH_HOME" rev-parse --verify --quiet 'origin/main' > /dev/null 2>&1; then
    base='origin/main'
  else
    skip "no upstream and no origin/main (run: git fetch origin)"
  fi

  # Resolve base to a SHA so we have stable comparison output
  local base_sha
  if ! base_sha="$(git -C "$SCRATCH_HOME" rev-parse --verify --quiet "$base")"; then
    skip "cannot resolve base ref: $base"
  fi

  # Find commits in HEAD not yet at base. Empty range is fine - test passes.
  local shas
  shas="$(git -C "$SCRATCH_HOME" rev-list "${base_sha}..HEAD" 2> /dev/null || true)"
  if [[ -z "$shas" ]]; then
    return 0
  fi

  # Pattern set: case-insensitive
  # - co-authored-by lines mentioning known AI vendors / generic "ai"
  # - "generated with" attributions
  # - the robot emoji used as a footer marker
  local pattern='co-authored-by:.*(claude|anthropic|\bai\b|gpt|copilot|gemini|bard)|generated with .*(claude|anthropic|copilot|gpt|gemini)|🤖'

  local found_slop=0
  local sha subject body
  while IFS= read -r sha; do
    [[ -z "$sha" ]] && continue
    body="$(git -C "$SCRATCH_HOME" log -1 --format='%B' "$sha")"
    if printf '%s\n' "$body" | grep -iE "$pattern" > /dev/null 2>&1; then
      subject="$(git -C "$SCRATCH_HOME" log -1 --format='%s' "$sha")"
      diag "AI attribution found in ${sha:0:12}: ${subject}"
      diag "  matched lines:"
      while IFS= read -r line; do
        diag "    > ${line}"
      done < <(printf '%s\n' "$body" | grep -iE "$pattern" || true)
      found_slop=1
    fi
  done <<< "$shas"

  if ((found_slop != 0)); then
    diag ""
    diag "AI attribution is forbidden per the project conventions."
    diag "Fix: rewrite the offending commits to remove the attribution lines."
    diag "     git rebase -i ${base}  (then 'reword' or 'edit' each flagged commit)"
    diag ""
    diag "Override (use sparingly): SCRATCH_SLOP_BASE=<ref> mise run test"
    return 1
  fi
}
