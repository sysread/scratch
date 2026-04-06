#!/usr/bin/env bats

# vim: set ft=bash
set -euo pipefail

#-------------------------------------------------------------------------------
# Tests for lib/project.sh
#
# Each test gets its own SCRATCH_PROJECTS_DIR under BATS_TEST_TMPDIR so
# tests don't interfere with each other or the user's real config.
#-------------------------------------------------------------------------------

setup() {
  SCRIPTDIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" > /dev/null 2>&1 && pwd)"
  SCRATCH_HOME="$(cd "${SCRIPTDIR}/.." && pwd)"
  source "${SCRIPTDIR}/helpers.sh"
  source "${SCRATCH_HOME}/lib/project.sh"

  # Isolate from real config
  export SCRATCH_CONFIG_DIR="${BATS_TEST_TMPDIR}/config"
  export SCRATCH_PROJECTS_DIR="${SCRATCH_CONFIG_DIR}/projects"
  mkdir -p "$SCRATCH_PROJECTS_DIR"
}

# ---------------------------------------------------------------------------
# project:save / project:exists / project:config-path
# ---------------------------------------------------------------------------

@test "project:save creates settings.json with correct structure" {
  project:save "myproj" "/tmp/myproj" "true" "node_modules/**" ".git/**"

  local config
  config="$(project:config-path "myproj")"
  [[ -f "$config" ]]

  # Verify JSON structure
  run jq -r '.root' "$config"
  is "$output" "/tmp/myproj"

  run jq -r '.is_git' "$config"
  is "$output" "true"

  run jq -r '.exclude | length' "$config"
  is "$output" "2"

  run jq -r '.exclude[0]' "$config"
  is "$output" "node_modules/**"
}

@test "project:save with no excludes creates empty array" {
  project:save "bare" "/tmp/bare" "false"

  local config
  config="$(project:config-path "bare")"
  run jq -r '.exclude | length' "$config"
  is "$output" "0"
}

@test "project:exists returns 0 for existing project" {
  project:save "exists-test" "/tmp/x" "false"
  run project:exists "exists-test"
  is "$status" 0
}

@test "project:exists returns 1 for missing project" {
  run project:exists "nope"
  is "$status" 1
}

# ---------------------------------------------------------------------------
# project:load
# ---------------------------------------------------------------------------

@test "project:load reads config into namerefs" {
  project:save "loadtest" "/home/user/code" "true" "vendor/**"

  local root is_git exclude
  project:load "loadtest" root is_git exclude

  is "$root" "/home/user/code"
  is "$is_git" "true"
  is "$exclude" "vendor/**"
}

@test "project:load fails for missing project" {
  run bash -c 'set -e; source '"${SCRATCH_HOME}"'/lib/project.sh; export SCRATCH_PROJECTS_DIR='"${SCRATCH_PROJECTS_DIR}"'; f() { local r g e; project:load "ghost" r g e; }; f 2>&1'
  is "$status" 1
  [[ "$output" == *"project not found"* ]]
}

# ---------------------------------------------------------------------------
# project:list
# ---------------------------------------------------------------------------

@test "project:list returns empty when no projects configured" {
  run project:list
  is "$status" 0
  is "$output" ""
}

@test "project:list returns configured project names" {
  project:save "alpha" "/tmp/a" "false"
  project:save "beta" "/tmp/b" "true"

  run project:list
  is "$status" 0
  [[ "$output" == *"alpha"* ]]
  [[ "$output" == *"beta"* ]]
}

@test "project:list ignores directories without settings.json" {
  mkdir -p "${SCRATCH_PROJECTS_DIR}/orphan"

  run project:list
  is "$status" 0
  is "$output" ""
}

# ---------------------------------------------------------------------------
# project:delete
# ---------------------------------------------------------------------------

@test "project:delete removes project config" {
  project:save "doomed" "/tmp/doomed" "false"
  project:exists "doomed"

  project:delete "doomed"
  run project:exists "doomed"
  is "$status" 1
}

@test "project:delete fails for missing project" {
  run bash -c 'set -e; source '"${SCRATCH_HOME}"'/lib/project.sh; export SCRATCH_PROJECTS_DIR='"${SCRATCH_PROJECTS_DIR}"'; project:delete "nope" 2>&1'
  is "$status" 1
  [[ "$output" == *"project not found"* ]]
}

# ---------------------------------------------------------------------------
# project:detect
# ---------------------------------------------------------------------------

@test "project:detect finds project from cwd" {
  local test_root="${BATS_TEST_TMPDIR}/fakerepo"
  mkdir -p "$test_root"
  # Resolve symlinks so saved root matches what pwd -P returns inside detect
  test_root="$(cd "$test_root" && pwd -P)"
  project:save "fakerepo" "$test_root" "false"

  local name wt
  cd "$test_root"
  project:detect name wt
  is "$name" "fakerepo"
  is "$wt" "false"
}

@test "project:detect finds project from subdirectory" {
  local test_root="${BATS_TEST_TMPDIR}/subrepo"
  mkdir -p "$test_root/src/deep"
  test_root="$(cd "$test_root" && pwd -P)"
  project:save "subrepo" "$test_root" "false"

  local name wt
  cd "$test_root/src/deep"
  project:detect name wt
  is "$name" "subrepo"
}

@test "project:detect returns 1 when no project matches" {
  cd /tmp
  run bash -c '
    source '"${SCRATCH_HOME}"'/lib/project.sh
    export SCRATCH_PROJECTS_DIR='"${SCRATCH_PROJECTS_DIR}"'
    local n w
    project:detect n w
  '
  is "$status" 1
}
