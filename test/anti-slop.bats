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
