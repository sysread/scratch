#!/usr/bin/env bats

# vim: set ft=bash
set -euo pipefail

load "./helpers.sh"

# Ensures checked-in files are already formatted with shfmt.
# Makes formatting drift a hard failure in CI.

setup() {
  SCRIPTDIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" > /dev/null 2>&1 && pwd)"
  SCRATCH_HOME="$(cd "${SCRIPTDIR}/.." > /dev/null 2>&1 && pwd)"
}

@test "shfmt would not change bin/, helpers/, or lib/" {
  local -a files=()
  local diff_output

  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    [[ "$f" == *.md ]] && continue
    files+=("$SCRATCH_HOME/$f")
  done < <(git -C "$SCRATCH_HOME" ls-files bin/ helpers/ lib/)

  [[ ${#files[@]} -eq 0 ]] && return 0

  diff_output="$(shfmt -d "${files[@]}")"

  if [[ -n "$diff_output" ]]; then
    echo "shfmt would change one or more files; run: mise run format"
    echo
    echo "$diff_output"
    return 1
  fi
}
