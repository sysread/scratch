#!/usr/bin/env bats

# vim: set ft=bash
set -euo pipefail

#-------------------------------------------------------------------------------
# Self-reflection: lint the entire codebase with shellcheck.
#
# This is dominantly the slowest part of the unit suite because the
# linter has no native parallelism and the per-file invocation cost is
# steep. Each test below collects its file list and hands it to
# the shellcheck_parallel helper in test/helpers.sh, which forks a process per
# file capped at SHELLCHECK_PARALLEL_JOBS (default 8) via wait -n.
#
# Output is buffered per file and reprinted in input order on failure,
# so test diagnostics are deterministic regardless of which child
# happened to finish first.
#-------------------------------------------------------------------------------

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

  # SC2030/SC2031: bin scripts follow sources into lib/ which uses
  # intentional subshell-scoped variable modifications throughout.
  run shellcheck_parallel -xa -e SC2030,SC2031 -- "${files[@]}"
  if [[ "$status" -ne 0 ]]; then
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

  run shellcheck_parallel -xa -- "${files[@]}"
  if [[ "$status" -ne 0 ]]; then
    echo "$output"
  fi
  is "$status" 0
}

@test "shellcheck ./lib" {
  local -a files=()
  while IFS= read -r rel; do
    [[ -z "$rel" ]] && continue
    files+=("${SCRATCH_HOME}/${rel}")
  done < <(git -C "$SCRATCH_HOME" ls-files 'lib/*.sh' 'lib/**/*.sh')

  [[ ${#files[@]} -eq 0 ]] && return 0

  run shellcheck_parallel -xa -e SC1091 -- "${files[@]}"
  if [[ "$status" -ne 0 ]]; then
    echo "$output"
  fi
  is "$status" 0
}

@test "shellcheck ./test" {
  # SC1091: library paths are resolved dynamically from SCRATCH_HOME
  # SC2030/SC2031: every @test is a bats subshell by design; variable
  #   modifications are always local to the test, which is correct behavior.
  local -a files=()
  while IFS= read -r rel; do
    [[ -z "$rel" ]] && continue
    files+=("${SCRATCH_HOME}/${rel}")
  done < <(git -C "$SCRATCH_HOME" ls-files 'test/*.bats' 'test/*/*.bats' 'test/helpers.sh')

  [[ ${#files[@]} -eq 0 ]] && return 0

  run shellcheck_parallel -e SC1091,SC2030,SC2031 -- "${files[@]}"
  if [[ "$status" -ne 0 ]]; then
    echo "$output"
  fi
  is "$status" 0
}
