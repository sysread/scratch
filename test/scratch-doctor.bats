#!/usr/bin/env bats

# vim: set ft=bash
set -euo pipefail

#-------------------------------------------------------------------------------
# Tests for scratch-doctor
#
# Doctor scans bin/ and lib/ for declared dependencies, then reports which are
# present and which are missing. These tests verify the scanning, attribution,
# output structure, and exit code behavior.
#
# Strategy: most tests run doctor against the real codebase (all deps should be
# present on a dev machine). To test failure paths, we create temporary stub
# subcommands that declare nonexistent dependencies, or unset env vars.
#-------------------------------------------------------------------------------

setup() {
  SCRIPTDIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" > /dev/null 2>&1 && pwd)"
  SCRATCH_HOME="$(cd "${SCRIPTDIR}/.." && pwd)"
  source "${SCRIPTDIR}/helpers.sh"

  # Stub external commands that doctor discovers via has-commands scanning.
  # On CI, tools like gum, curl, etc. may not be installed. Without stubs,
  # doctor would report them as missing and exit 1.
  local noop=$'#!/usr/bin/env bash\nexit 0'
  local cmd
  for cmd in jq gum curl; do
    command -v "$cmd" > /dev/null 2>&1 || make_stub "$cmd" "$noop" > /dev/null
  done
  prepend_stub_path
}

teardown() {
  rm -f "${SCRATCH_HOME}/bin/scratch-doctortest"
}

# ---------------------------------------------------------------------------
# Baseline: clean environment exits 0 with expected sections
# ---------------------------------------------------------------------------

@test "doctor exits 0 with all expected sections on clean env" {
  run "${SCRATCH_HOME}/bin/scratch-doctor"
  is "$status" 0
  [[ "$output" == *"Runtime"* ]]
  [[ "$output" == *"All checks passed"* ]]
}

# ---------------------------------------------------------------------------
# Missing command: doctor reports failure and exits 1
# ---------------------------------------------------------------------------

@test "doctor exits 1 and reports missing command with attribution" {
  cat > "${SCRATCH_HOME}/bin/scratch-doctortest" << 'STUB'
#!/usr/bin/env bash
has-commands nonexistent_xyz_tool_12345
STUB
  chmod +x "${SCRATCH_HOME}/bin/scratch-doctortest"

  run "${SCRATCH_HOME}/bin/scratch-doctor"
  is "$status" 1
  [[ "$output" == *"nonexistent_xyz_tool_12345"*"not found"* ]]
  [[ "$output" == *"doctortest"* ]]
  [[ "$output" == *"Some checks failed"* ]]
}

# ---------------------------------------------------------------------------
# --dev flag
# ---------------------------------------------------------------------------

@test "doctor without --dev omits Developer tools section" {
  run "${SCRATCH_HOME}/bin/scratch-doctor"
  [[ "$output" != *"Developer tools"* ]]
}

@test "doctor --dev shows developer tools section" {
  run "${SCRATCH_HOME}/bin/scratch-doctor" --dev
  [[ "$output" == *"Developer tools"* ]]
  [[ "$output" == *"mise"* ]]
}

# ---------------------------------------------------------------------------
# Help
# ---------------------------------------------------------------------------

@test "doctor --help prints usage and exits 0" {
  run "${SCRATCH_HOME}/bin/scratch-doctor" --help
  is "$status" 0
  [[ "$output" == *"Usage:"* ]]
}
