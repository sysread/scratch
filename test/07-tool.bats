#!/usr/bin/env bats

# vim: set ft=bash
set -euo pipefail

#-------------------------------------------------------------------------------
# Tests for lib/tool.sh
#
# Tools are discovered via SCRATCH_TOOLS_DIR (which lib/tool.sh honors when
# set, defaulting to <repo>/tools otherwise). Each test points it at a fresh
# subdir under BATS_TEST_TMPDIR and seeds it with fake tools via the
# make_fake_tool helper.
#
# Tools that need real LLM connectivity or filesystem effects are tested in
# isolation - the fake tools here just echo their env vars or exit with a
# canned status, exercising the lib's discovery, gating, and capture logic.
#-------------------------------------------------------------------------------

setup() {
  SCRIPTDIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" > /dev/null 2>&1 && pwd)"
  SCRATCH_HOME="$(cd "${SCRIPTDIR}/.." && pwd)"
  source "${SCRIPTDIR}/helpers.sh"
  source "${SCRATCH_HOME}/lib/tool.sh"

  # Per-test HOME so anything resolving under $HOME/.config/scratch/...
  # is fresh for every test.
  export HOME="${BATS_TEST_TMPDIR}/home"
  mkdir -p "$HOME"

  # Per-test tools directory. lib/tool.sh's tool:tools-dir honors this.
  export SCRATCH_TOOLS_DIR="${BATS_TEST_TMPDIR}/tools"
  mkdir -p "$SCRATCH_TOOLS_DIR"
}

#-------------------------------------------------------------------------------
# Helpers
#-------------------------------------------------------------------------------

# make_fake_tool NAME [MAIN_BODY] [AVAIL_EXIT_CODE] [SPEC_DESCRIPTION]
#
# Creates a complete fake tool under $SCRATCH_TOOLS_DIR/NAME with all three
# required files. MAIN_BODY is the body of main (after the bash shebang);
# defaults to "echo OK". AVAIL_EXIT_CODE is the exit code is-available
# returns; defaults to 0. SPEC_DESCRIPTION is the tool's description in
# spec.json; defaults to "fake test tool".
make_fake_tool() {
  local name="$1"
  local main_body="${2:-echo OK}"
  local avail_exit="${3:-0}"
  local desc="${4:-fake test tool}"
  local dir="${SCRATCH_TOOLS_DIR}/${name}"

  mkdir -p "$dir"

  jq -n \
    --arg n "$name" \
    --arg d "$desc" \
    '{name: $n, description: $d, parameters: {type: "object", properties: {}, required: []}}' \
    > "${dir}/spec.json"

  printf '#!/usr/bin/env bash\nset -euo pipefail\n%s\n' "$main_body" > "${dir}/main"
  chmod +x "${dir}/main"

  printf '#!/usr/bin/env bash\nexit %s\n' "$avail_exit" > "${dir}/is-available"
  chmod +x "${dir}/is-available"

  # Explicit return 0 - bats's set -e treats a non-zero last-statement exit
  # code as a test failure even when nothing actually failed. The chmod above
  # always exits 0 on success but defensive return 0 prevents future
  # last-statement-shifts from breaking tests.
  return 0
}

# ---------------------------------------------------------------------------
# tool:tools-dir
# ---------------------------------------------------------------------------

@test "tool:tools-dir honors SCRATCH_TOOLS_DIR override" {
  run tool:tools-dir
  is "$status" 0
  is "$output" "$SCRATCH_TOOLS_DIR"
}

# ---------------------------------------------------------------------------
# tool:list
# ---------------------------------------------------------------------------

@test "tool:list returns empty when tools dir is empty" {
  run tool:list
  is "$status" 0
  is "$output" ""
}

@test "tool:list returns one tool when one is defined" {
  make_fake_tool alpha
  run tool:list
  is "$status" 0
  is "$output" "alpha"
}

@test "tool:list returns multiple tools sorted" {
  make_fake_tool gamma
  make_fake_tool alpha
  make_fake_tool beta
  run tool:list
  is "$status" 0
  is "$(echo "$output" | head -1)" "alpha"
  is "$(echo "$output" | tail -1)" "gamma"
  [[ "$output" == *"beta"* ]]
}

@test "tool:list skips dirs without spec.json" {
  make_fake_tool real
  mkdir -p "${SCRATCH_TOOLS_DIR}/incomplete"
  # incomplete has no spec.json, should be silently skipped
  run tool:list
  is "$status" 0
  is "$output" "real"
}

# ---------------------------------------------------------------------------
# tool:exists
# ---------------------------------------------------------------------------

@test "tool:exists returns 0 for a complete tool" {
  make_fake_tool fully-formed
  run tool:exists fully-formed
  is "$status" 0
}

@test "tool:exists returns 1 for an unknown tool" {
  run tool:exists ghost
  is "$status" 1
}

@test "tool:exists returns 1 for a dir missing main" {
  mkdir -p "${SCRATCH_TOOLS_DIR}/half"
  jq -n '{name:"half",description:"x",parameters:{type:"object",properties:{},required:[]}}' \
    > "${SCRATCH_TOOLS_DIR}/half/spec.json"
  printf '#!/usr/bin/env bash\nexit 0\n' > "${SCRATCH_TOOLS_DIR}/half/is-available"
  chmod +x "${SCRATCH_TOOLS_DIR}/half/is-available"
  # No main file
  run tool:exists half
  is "$status" 1
}

@test "tool:exists returns 1 for a dir missing is-available" {
  mkdir -p "${SCRATCH_TOOLS_DIR}/half"
  jq -n '{name:"half",description:"x",parameters:{type:"object",properties:{},required:[]}}' \
    > "${SCRATCH_TOOLS_DIR}/half/spec.json"
  printf '#!/usr/bin/env bash\necho hi\n' > "${SCRATCH_TOOLS_DIR}/half/main"
  chmod +x "${SCRATCH_TOOLS_DIR}/half/main"
  # No is-available
  run tool:exists half
  is "$status" 1
}

# ---------------------------------------------------------------------------
# tool:dir
# ---------------------------------------------------------------------------

@test "tool:dir prints absolute path for a known tool" {
  make_fake_tool alpha
  run tool:dir alpha
  is "$status" 0
  is "$output" "${SCRATCH_TOOLS_DIR}/alpha"
}

@test "tool:dir dies for an unknown tool" {
  run tool:dir ghost
  is "$status" 1
  [[ "$output" == *"not found"* ]]
}

# ---------------------------------------------------------------------------
# tool:spec
# ---------------------------------------------------------------------------

@test "tool:spec prints the raw spec.json" {
  make_fake_tool alpha
  run tool:spec alpha
  is "$status" 0
  run jq -r '.name' <<< "$output"
  is "$output" "alpha"
}

@test "tool:spec dies for an unknown tool" {
  run tool:spec ghost
  is "$status" 1
  [[ "$output" == *"not found"* ]]
}

# ---------------------------------------------------------------------------
# tool:available
# ---------------------------------------------------------------------------

@test "tool:available returns 0 when is-available exits 0" {
  make_fake_tool alpha "echo OK" 0
  run tool:available alpha
  is "$status" 0
}

@test "tool:available returns the script's exit code on failure" {
  make_fake_tool alpha "echo OK" 7
  run tool:available alpha
  is "$status" 7
}

@test "tool:available captures stderr from is-available into _TOOL_AVAILABILITY_ERR" {
  mkdir -p "${SCRATCH_TOOLS_DIR}/grumpy"
  jq -n '{name:"grumpy",description:"x",parameters:{type:"object",properties:{},required:[]}}' \
    > "${SCRATCH_TOOLS_DIR}/grumpy/spec.json"
  printf '#!/usr/bin/env bash\necho hi\n' > "${SCRATCH_TOOLS_DIR}/grumpy/main"
  chmod +x "${SCRATCH_TOOLS_DIR}/grumpy/main"
  printf '#!/usr/bin/env bash\necho "missing dependency: foo" >&2\nexit 1\n' \
    > "${SCRATCH_TOOLS_DIR}/grumpy/is-available"
  chmod +x "${SCRATCH_TOOLS_DIR}/grumpy/is-available"

  tool:available grumpy || true
  [[ "$_TOOL_AVAILABILITY_ERR" == *"missing dependency"* ]]
}

@test "tool:available honors SCRATCH_TOOL_SKIP_AVAILABILITY=1" {
  make_fake_tool alpha "echo OK" 1
  export SCRATCH_TOOL_SKIP_AVAILABILITY=1
  run tool:available alpha
  is "$status" 0
}

# ---------------------------------------------------------------------------
# tool:specs-json
# ---------------------------------------------------------------------------

@test "tool:specs-json with no args returns array of all tools" {
  make_fake_tool alpha
  make_fake_tool beta
  export SCRATCH_TOOL_SKIP_AVAILABILITY=1

  run tool:specs-json
  is "$status" 0
  run jq -r 'length' <<< "$output"
  is "$output" "2"
}

@test "tool:specs-json wraps each spec in OpenAI function envelope" {
  make_fake_tool alpha
  export SCRATCH_TOOL_SKIP_AVAILABILITY=1

  local specs
  specs="$(tool:specs-json alpha)"

  run jq -r '.[0].type' <<< "$specs"
  is "$output" "function"

  run jq -r '.[0].function.name' <<< "$specs"
  is "$output" "alpha"
}

@test "tool:specs-json deduplicates repeated names" {
  make_fake_tool alpha
  export SCRATCH_TOOL_SKIP_AVAILABILITY=1

  local specs
  specs="$(tool:specs-json alpha alpha alpha)"

  run jq -r 'length' <<< "$specs"
  is "$output" "1"
}

@test "tool:specs-json filters out unavailable tools" {
  make_fake_tool good "echo OK" 0
  make_fake_tool bad "echo OK" 1
  # Don't set SCRATCH_TOOL_SKIP_AVAILABILITY - we WANT the gate to fire

  local specs
  specs="$(tool:specs-json)"

  run jq -r 'length' <<< "$specs"
  is "$output" "1"

  run jq -r '.[0].function.name' <<< "$specs"
  is "$output" "good"
}

@test "tool:specs-json dies for an unknown name" {
  run tool:specs-json ghost
  is "$status" 1
  [[ "$output" == *"not found"* ]]
}

# ---------------------------------------------------------------------------
# tool:invoke
# ---------------------------------------------------------------------------

@test "tool:invoke captures stdout into _TOOL_INVOKE_STDOUT on success" {
  make_fake_tool alpha 'echo "hello from alpha"'
  export SCRATCH_TOOL_SKIP_AVAILABILITY=1

  tool:invoke alpha '{}'
  is "$_TOOL_INVOKE_STDOUT" "hello from alpha"
  is "$_TOOL_INVOKE_STDERR" ""
}

@test "tool:invoke captures stderr into _TOOL_INVOKE_STDERR on failure" {
  make_fake_tool alpha 'echo "kaboom" >&2; exit 3'
  export SCRATCH_TOOL_SKIP_AVAILABILITY=1

  tool:invoke alpha '{}' || true
  is "$_TOOL_INVOKE_STDOUT" ""
  is "$_TOOL_INVOKE_STDERR" "kaboom"
}

@test "tool:invoke returns the tool's exit code" {
  make_fake_tool alpha 'exit 42'
  export SCRATCH_TOOL_SKIP_AVAILABILITY=1

  set +e
  tool:invoke alpha '{}'
  local rc=$?
  set -e
  is "$rc" "42"
}

@test "tool:invoke passes SCRATCH_TOOL_ARGS_JSON to main" {
  make_fake_tool alpha 'echo "$SCRATCH_TOOL_ARGS_JSON"'
  export SCRATCH_TOOL_SKIP_AVAILABILITY=1

  tool:invoke alpha '{"x":42,"y":"hello"}'
  is "$_TOOL_INVOKE_STDOUT" '{"x":42,"y":"hello"}'
}

@test "tool:invoke passes SCRATCH_TOOL_DIR to main" {
  make_fake_tool alpha 'echo "$SCRATCH_TOOL_DIR"'
  export SCRATCH_TOOL_SKIP_AVAILABILITY=1

  tool:invoke alpha '{}'
  is "$_TOOL_INVOKE_STDOUT" "${SCRATCH_TOOLS_DIR}/alpha"
}

@test "tool:invoke passes SCRATCH_HOME to main" {
  make_fake_tool alpha 'echo "$SCRATCH_HOME"'
  export SCRATCH_TOOL_SKIP_AVAILABILITY=1

  tool:invoke alpha '{}'
  # SCRATCH_HOME should be the scratch repo root (where lib/tool.sh lives)
  is "$_TOOL_INVOKE_STDOUT" "${SCRATCH_HOME}"
}

@test "tool:invoke returns 127 when tool is unavailable" {
  make_fake_tool alpha "echo OK" 1
  unset SCRATCH_TOOL_SKIP_AVAILABILITY

  set +e
  tool:invoke alpha '{}'
  local rc=$?
  set -e
  is "$rc" "127"
}

@test "tool:invoke dies for an unknown tool" {
  run tool:invoke ghost '{}'
  is "$status" 1
  [[ "$output" == *"not found"* ]]
}
