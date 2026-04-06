#!/usr/bin/env bats

# vim: set ft=bash
set -euo pipefail

# Policy:
# - Commands and entrypoints in bin/ must be executable.
# - Helper scripts in helpers/ must be executable.
# - Library files in lib/ and libexec/ must NOT be executable.

load "./helpers.sh"

setup() {
  SCRIPTDIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" > /dev/null 2>&1 && pwd)"
  SCRATCH_HOME="$(cd "${SCRIPTDIR}/.." > /dev/null 2>&1 && pwd)"
}

@test "bin/ and helpers/ scripts are executable" {
  local -a files=()

  while IFS= read -r f; do
    [[ "$f" == *.md ]] && continue
    files+=("$f")
  done < <(git -C "$SCRATCH_HOME" ls-files bin/ helpers/)

  for f in "${files[@]}"; do
    if [[ ! -x "$SCRATCH_HOME/$f" ]]; then
      echo "expected executable: $f"
      return 1
    fi
  done
}

@test "lib/ files are not executable" {
  local -a files=()

  while IFS= read -r f; do
    files+=("$f")
  done < <(git -C "$SCRATCH_HOME" ls-files lib/)

  for f in "${files[@]}"; do
    if [[ -x "$SCRATCH_HOME/$f" ]]; then
      echo "expected non-executable: $f"
      return 1
    fi
  done
}

@test "libexec/ files are not executable" {
  local -a files=()

  while IFS= read -r f; do
    files+=("$f")
  done < <(git -C "$SCRATCH_HOME" ls-files libexec/)

  [[ ${#files[@]} -eq 0 ]] && return 0

  for f in "${files[@]}"; do
    if [[ -x "$SCRATCH_HOME/$f" ]]; then
      echo "expected non-executable: $f"
      return 1
    fi
  done
}
