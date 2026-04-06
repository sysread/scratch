#!/usr/bin/env bats

# vim: set ft=bash
set -euo pipefail

#-------------------------------------------------------------------------------
# Tests for lib/base.sh
#-------------------------------------------------------------------------------

setup() {
  SCRIPTDIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" > /dev/null 2>&1 && pwd)"
  SCRATCH_HOME="$(cd "${SCRIPTDIR}/.." && pwd)"
  source "${SCRIPTDIR}/helpers.sh"
  source "${SCRATCH_HOME}/lib/base.sh"
}

# ---------------------------------------------------------------------------
# warn
# ---------------------------------------------------------------------------

@test "warn outputs to stderr" {
  run --separate-stderr warn "test message"
  is "$stderr" "test message"
  is "$output" ""
}

# ---------------------------------------------------------------------------
# die
# ---------------------------------------------------------------------------

@test "die outputs to stderr and returns 1" {
  run --separate-stderr bash -c 'source '"${SCRATCH_HOME}"'/lib/base.sh; die "fatal error"'
  is "$status" 1
  is "$stderr" "fatal error"
}

# ---------------------------------------------------------------------------
# has-commands
# ---------------------------------------------------------------------------

@test "has-commands succeeds for a command on PATH" {
  run has-commands bash
  is "$status" 0
}

@test "has-commands fails for a missing command" {
  run bash -c 'source '"${SCRATCH_HOME}"'/lib/base.sh; has-commands nonexistent_xyz_tool_12345 2>&1'
  is "$status" 1
  [[ "$output" == *"not found on PATH"* ]]
}

@test "has-commands checks all arguments" {
  run bash -c 'source '"${SCRATCH_HOME}"'/lib/base.sh; has-commands bash nonexistent_xyz_tool_12345 2>&1'
  is "$status" 1
  [[ "$output" == *"nonexistent_xyz_tool_12345"* ]]
}

# ---------------------------------------------------------------------------
# require-env-vars
# ---------------------------------------------------------------------------

@test "require-env-vars succeeds when var is set" {
  export TEST_VAR_12345="hello"
  run require-env-vars TEST_VAR_12345
  is "$status" 0
  unset TEST_VAR_12345
}

@test "require-env-vars fails when var is unset" {
  run bash -c 'source '"${SCRATCH_HOME}"'/lib/base.sh; require-env-vars TEST_VAR_12345 2>&1'
  is "$status" 1
  [[ "$output" == *"Missing required env var"* ]]
}

@test "require-env-vars fails when var is empty" {
  run bash -c 'export TEST_VAR_12345=""; source '"${SCRATCH_HOME}"'/lib/base.sh; require-env-vars TEST_VAR_12345 2>&1'
  is "$status" 1
  [[ "$output" == *"Missing required env var"* ]]
}

# ---------------------------------------------------------------------------
# has-min-bash-version
# ---------------------------------------------------------------------------

@test "has-min-bash-version succeeds for current bash" {
  run has-min-bash-version 5
  is "$status" 0
}

@test "has-min-bash-version rejects invalid version string" {
  run has-min-bash-version "abc"
  is "$status" 1
}
