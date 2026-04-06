#!/usr/bin/env bats

# vim: set ft=bash
set -euo pipefail

setup() {
  SCRIPTDIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" > /dev/null 2>&1 && pwd)"
  source "${SCRIPTDIR}/helpers.sh"
  SCRATCH_HOME="$(cd "${SCRIPTDIR}/.." > /dev/null 2>&1 && pwd)"
}

@test "shellcheck ./bin" {
  local -a files=()

  while IFS= read -r rel; do
    local f="${SCRATCH_HOME}/${rel}"
    [[ -x "$f" ]] && files+=("$f")
  done < <(git -C "$SCRATCH_HOME" ls-files bin/)

  if [[ ${#files[@]} -eq 0 ]]; then
    echo "Error: No executable files found in ${SCRATCH_HOME}/bin"
    return 1
  fi

  run shellcheck -xa "${files[@]}"
  if [[ "$status" -ne 0 ]]; then
    echo "shellcheck failed (exit $status):"
    echo "$output"
  fi
  is "$status" 0
}

@test "shellcheck ./helpers" {
  local -a files=()

  while IFS= read -r rel; do
    [[ -z "$rel" ]] && continue
    files+=("${SCRATCH_HOME}/${rel}")
  done < <(git -C "$SCRATCH_HOME" ls-files helpers/ | grep -v '\.md$')

  [[ ${#files[@]} -eq 0 ]] && return 0

  run shellcheck -xa "${files[@]}"
  if [[ "$status" -ne 0 ]]; then
    echo "shellcheck failed (exit $status):"
    echo "$output"
  fi
  is "$status" 0
}

@test "shellcheck ./lib" {
  run shellcheck -xa -e SC1091 "${SCRATCH_HOME}/lib/"*.sh
  if [[ "$status" -ne 0 ]]; then
    echo "shellcheck failed (exit $status):"
    echo "$output"
  fi
  is "$status" 0
}

@test "shellcheck ./test" {
  run shellcheck -e SC1091 "${SCRATCH_HOME}/test/"*.bats "${SCRATCH_HOME}/test/"helpers.sh
  if [[ "$status" -ne 0 ]]; then
    echo "shellcheck failed (exit $status):"
    echo "$output"
  fi
  is "$status" 0
}
