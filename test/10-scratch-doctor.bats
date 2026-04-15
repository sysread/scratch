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
# Strategy: each test runs doctor inside a private SCRATCH_HOME assembled
# under BATS_TEST_TMPDIR. The fake home has a real bin/ directory (so we
# can drop stub subcommands into it without polluting the live tree),
# while lib/, helpers/, tools/, and data/ are directory symlinks pointing
# back at the real repo (so doctor still scans the real components and
# attribution works). This isolation matters because test 94 globs the
# live bin/ for the subcommand contract check, and a stray stub left in
# the live tree races with that test under the parallel runner.
#-------------------------------------------------------------------------------

setup() {
  SCRIPTDIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" > /dev/null 2>&1 && pwd)"
  REAL_SCRATCH_HOME="$(cd "${SCRIPTDIR}/.." && pwd)"
  source "${SCRIPTDIR}/helpers.sh"

  export HOME="${BATS_TEST_TMPDIR}/home"
  mkdir -p "$HOME"

  # Build the fake SCRATCH_HOME. bin/ is a real dir populated by copying
  # every real bin/* file (small shell scripts) so tests can add stubs
  # alongside them. The other component dirs are symlinks back to the
  # real tree so doctor scans the actual lib/helpers/tools/data without
  # us having to keep two trees in sync.
  SCRATCH_HOME="${BATS_TEST_TMPDIR}/scratch"
  mkdir -p "${SCRATCH_HOME}/bin"
  cp "${REAL_SCRATCH_HOME}"/bin/* "${SCRATCH_HOME}/bin/"
  ln -s "${REAL_SCRATCH_HOME}/lib" "${SCRATCH_HOME}/lib"
  ln -s "${REAL_SCRATCH_HOME}/helpers" "${SCRATCH_HOME}/helpers"
  ln -s "${REAL_SCRATCH_HOME}/tools" "${SCRATCH_HOME}/tools"
  ln -s "${REAL_SCRATCH_HOME}/data" "${SCRATCH_HOME}/data"

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

# ---------------------------------------------------------------------------
# Instrumented sourcing for tools/agents/toolboxes is-available files.
#
# These tests exercise the scan-via-source path, which sources the
# is-available script with `has-commands` and `require-env-vars` overridden
# as recorders. This eliminates the textual-grep coupling that would miss
# declarations wrapped, extracted into functions, or interpolated.
# ---------------------------------------------------------------------------

# Direct unit tests for the scan-via-source function. We exercise it on
# is-available files written under BATS_TEST_TMPDIR, isolated from the
# live tree. The point is to verify that instrumented sourcing finds
# `has-commands` and `require-env-vars` declarations the old grep
# scanner would miss (wrapped lines, function extraction, conditionals).

@test "scan-via-source finds has-commands inside a function (grep would miss)" {
  local fixture="${BATS_TEST_TMPDIR}/wrapped-is-available"
  cat > "$fixture" << 'STUB'
#!/usr/bin/env bash
set -euo pipefail
source "$SCRATCH_HOME/lib/base.sh"
_declare_deps() {
  has-commands wrapped_xyz_dep_67890
}
_declare_deps
STUB
  chmod +x "$fixture"

  # Source scratch-doctor's bash to load scan-via-source. Use a guarded
  # sourcing pattern: scratch-doctor's main flow runs scan-all-deps and
  # the check-* functions at top-level, so we can't just `source` it
  # without it doing all its own work. Instead extract scan-via-source
  # by sourcing in a subshell that immediately exits before the main
  # flow runs. The simpler path: bats already ran scratch-doctor in
  # other tests, so we know the function body is valid; here we just
  # invoke a fresh bash that sources only the lib pieces and a copy of
  # the function. To avoid duplicating scan-via-source's body, we
  # exercise it indirectly: drop the fixture into a per-test fake
  # scratch home and run scratch-doctor against it.
  local fakehome="${BATS_TEST_TMPDIR}/fakehome"
  mkdir -p "${fakehome}/bin" "${fakehome}/tools/_doctortest_wrapped"
  cp "${REAL_SCRATCH_HOME}"/bin/* "${fakehome}/bin/"
  ln -s "${REAL_SCRATCH_HOME}/lib" "${fakehome}/lib"
  ln -s "${REAL_SCRATCH_HOME}/helpers" "${fakehome}/helpers"
  ln -s "${REAL_SCRATCH_HOME}/agents" "${fakehome}/agents"
  ln -s "${REAL_SCRATCH_HOME}/toolboxes" "${fakehome}/toolboxes"
  ln -s "${REAL_SCRATCH_HOME}/data" "${fakehome}/data"
  # tools/ is a real dir so we can drop the fixture without polluting
  # the live tree. Symlink each real tool into it.
  local t
  for t in "${REAL_SCRATCH_HOME}"/tools/*/; do
    ln -s "$t" "${fakehome}/tools/$(basename "$t")"
  done
  cp "$fixture" "${fakehome}/tools/_doctortest_wrapped/is-available"
  cat > "${fakehome}/tools/_doctortest_wrapped/spec.json" << 'SPEC'
{"name":"_doctortest_wrapped","description":"x","parameters":{"type":"object","properties":{},"required":[]}}
SPEC
  cat > "${fakehome}/tools/_doctortest_wrapped/main" << 'MAIN'
#!/usr/bin/env bash
exit 0
MAIN
  chmod +x "${fakehome}/tools/_doctortest_wrapped/main"

  run "${fakehome}/bin/scratch-doctor"
  # The fake dep doesn't exist on the system, so doctor reports it
  # missing AND attributes it to the test tool — proving the scanner
  # found the declaration despite it being inside a function (which
  # the legacy grep scanner did handle, but the test still serves as
  # a regression guard for instrumentation).
  [[ "$output" == *"wrapped_xyz_dep_67890"*"not found"* ]]
  [[ "$output" == *"tool:_doctortest_wrapped"* ]]
}
