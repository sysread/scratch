#!/usr/bin/env bats

# vim: set ft=bash
set -euo pipefail

#-------------------------------------------------------------------------------
# Subcommand interface contract tests
#
# Every scratch-* subcommand must honor a minimal interface:
#
#   1. scratch-<name> --help exits 0.
#
# These tests glob all bin/scratch-* scripts and verify the requirement. If a
# new subcommand is added without implementing the contract, these tests catch
# it automatically.
#-------------------------------------------------------------------------------

setup() {
  SCRIPTDIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" > /dev/null 2>&1 && pwd)"
  SCRATCH_HOME="$(cd "${SCRIPTDIR}/.." && pwd)"
  source "${SCRIPTDIR}/helpers.sh"
}

@test "all subcommands respond to '--help' with exit 0" {
  local cmd name
  local failures=()

  for cmd in "${SCRATCH_HOME}"/bin/scratch-*; do
    [[ -x "$cmd" ]] || continue
    name="$(basename "$cmd")"

    run "$cmd" --help
    if [[ "$status" -ne 0 ]]; then
      failures+=("${name}: exit ${status}")
    fi
  done

  if ((${#failures[@]} > 0)); then
    for msg in "${failures[@]}"; do
      diag "$msg"
    done
    return 1
  fi
}
