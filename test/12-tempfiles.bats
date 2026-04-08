#!/usr/bin/env bats

# vim: set ft=bash
set -euo pipefail

#-------------------------------------------------------------------------------
# Tests for lib/tempfiles.sh
#
# Focused on tmp:make's input validation. The fuller registry/cleanup
# behavior is exercised indirectly by every lib that uses it (tool.sh,
# accumulator.sh) plus the integration smoke of the whole test suite,
# but this file pins the contracts that future contributors will trip
# over if they regress.
#-------------------------------------------------------------------------------

setup() {
  SCRIPTDIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" > /dev/null 2>&1 && pwd)"
  SCRATCH_HOME="$(cd "${SCRIPTDIR}/.." && pwd)"
  source "${SCRIPTDIR}/helpers.sh"
  source "${SCRATCH_HOME}/lib/tempfiles.sh"

  export HOME="${BATS_TEST_TMPDIR}/home"
  mkdir -p "$HOME"
}

# ---------------------------------------------------------------------------
# tmp:make: input validation
# ---------------------------------------------------------------------------

@test "tmp:make creates a file under the requested absolute template" {
  local p
  tmp:make p "${BATS_TEST_TMPDIR}/scratch-test.XXXXXX"
  [[ -f "$p" ]]
  [[ "$p" == "${BATS_TEST_TMPDIR}/scratch-test."* ]]
}

@test "tmp:make rejects a relative template" {
  run tmp:make somevar "scratch-relative.XXXXXX"
  is "$status" 1
  [[ "$output" == *"absolute path"* ]]
  [[ "$output" == *"scratch-relative.XXXXXX"* ]]
}

@test "tmp:make rejects a bare filename without slashes" {
  run tmp:make somevar "noslash.XXXXXX"
  is "$status" 1
  [[ "$output" == *"absolute path"* ]]
}

@test "tmp:make rejects a relative path with intermediate directories" {
  run tmp:make somevar "subdir/scratch.XXXXXX"
  is "$status" 1
  [[ "$output" == *"absolute path"* ]]
}

@test "tmp:make dies on a missing variable name" {
  run tmp:make
  is "$status" 1
  [[ "$output" == *"variable name"* ]]
}

@test "tmp:make dies on a missing template" {
  run tmp:make somevar
  is "$status" 1
  [[ "$output" == *"template"* ]]
}

# ---------------------------------------------------------------------------
# tmp:cleanup: handles both files and directories
# ---------------------------------------------------------------------------

@test "tmp:cleanup removes a tracked file" {
  local f
  tmp:make f "${BATS_TEST_TMPDIR}/scratch-cleanup-file.XXXXXX"
  [[ -f "$f" ]]
  tmp:cleanup
  [[ ! -e "$f" ]]
}

@test "tmp:cleanup removes a tracked directory recursively" {
  # Regression: tmp:cleanup used rm -f, which silently fails on dirs.
  # Both lib/tool.sh and lib/agent.sh's intuition example create
  # workdirs via mktemp -d + tmp:track. Without -r in cleanup, those
  # workdirs lingered until the OS reaped them.
  local d
  d="$(mktemp -d -t scratch-cleanup-dir.XXXXXX)"
  tmp:track "$d"
  printf 'sentinel' > "${d}/file"
  [[ -d "$d" && -f "${d}/file" ]]
  tmp:cleanup
  [[ ! -e "$d" ]]
}
