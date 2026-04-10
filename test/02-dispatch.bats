#!/usr/bin/env bats

# vim: set ft=bash
set -euo pipefail

#-------------------------------------------------------------------------------
# Tests for lib/dispatch.sh
#
# These tests exercise dispatch:list and dispatch:path against the real
# scratch/ bin directory, so they double as a sanity check on the current
# subcommand layout.
#-------------------------------------------------------------------------------

setup() {
  SCRIPTDIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" > /dev/null 2>&1 && pwd)"
  SCRATCH_HOME="$(cd "${SCRIPTDIR}/.." && pwd)"
  source "${SCRIPTDIR}/helpers.sh"
  source "${SCRATCH_HOME}/lib/dispatch.sh"
}

# ---------------------------------------------------------------------------
# dispatch:list
# ---------------------------------------------------------------------------

@test "dispatch:list finds top-level subcommands" {
  run dispatch:list "scratch"
  is "$status" 0
  [[ "$output" == *"doctor"* ]]
  [[ "$output" == *"project"* ]]
}

@test "dispatch:list finds direct children of scratch-project" {
  run dispatch:list "scratch-project"
  is "$status" 0
  [[ "$output" == *"list"* ]]
  [[ "$output" == *"show"* ]]
  [[ "$output" == *"create"* ]]
  [[ "$output" == *"edit"* ]]
  [[ "$output" == *"delete"* ]]
}

@test "dispatch:list excludes grandchildren from parent listing" {
  # scratch-project-list is a child of scratch-project, not of scratch.
  # dispatch:list "scratch" must NOT include "project-list".
  run dispatch:list "scratch"
  is "$status" 0
  [[ "$output" != *"project-list"* ]]
  [[ "$output" != *"project-show"* ]]
}

@test "dispatch:list output is sorted" {
  run dispatch:list "scratch-project"
  is "$status" 0
  local sorted
  sorted="$(printf '%s\n' "$output" | sort)"
  is "$output" "$sorted"
}

# ---------------------------------------------------------------------------
# dispatch:path
# ---------------------------------------------------------------------------

@test "dispatch:path resolves a known subcommand" {
  run dispatch:path "scratch" "doctor"
  is "$status" 0
  [[ "$output" == *"/bin/scratch-doctor" ]]
}

@test "dispatch:path resolves a nested subcommand" {
  run dispatch:path "scratch-project" "list"
  is "$status" 0
  [[ "$output" == *"/bin/scratch-project-list" ]]
}

@test "dispatch:path returns 1 for unknown verb" {
  run dispatch:path "scratch" "ghost"
  is "$status" 1
}

# ---------------------------------------------------------------------------
# dispatch:try
# ---------------------------------------------------------------------------

@test "dispatch:try returns 1 on no args" {
  run bash -c 'source '"${SCRATCH_HOME}"'/lib/dispatch.sh; dispatch:try "scratch" && echo ok || echo no'
  is "$output" "no"
}

@test "dispatch:try returns 1 on --help" {
  run bash -c 'source '"${SCRATCH_HOME}"'/lib/dispatch.sh; dispatch:try "scratch" --help && echo ok || echo no'
  is "$output" "no"
}

@test "dispatch:try returns 1 on unknown verb" {
  run bash -c 'source '"${SCRATCH_HOME}"'/lib/dispatch.sh; dispatch:try "scratch" bogus && echo ok || echo no'
  is "$output" "no"
}

@test "dispatch:try execs to child on known verb" {
  # scratch-doctor synopsis prints its description. If dispatch:try execs it,
  # we should see that output. We can only observe this via the stdout of the
  # exec'd child.
  run bash -c 'source '"${SCRATCH_HOME}"'/lib/dispatch.sh; dispatch:try "scratch" doctor synopsis'
  is "$status" 0
  [[ "$output" == *"dependencies"* ]]
}

@test "dispatch:try dispatches help as a normal verb" {
  # With bin/scratch-help existing, 'help' is a regular subcommand —
  # no special-case interception in dispatch:try.
  run bash -c 'source '"${SCRATCH_HOME}"'/lib/dispatch.sh; dispatch:try "scratch" help --help 2>&1'
  is "$status" 0
  [[ "$output" == *"Browse guides"* ]]
}

# ---------------------------------------------------------------------------
# dispatch:usage
# ---------------------------------------------------------------------------

@test "dispatch:usage renders subcommand list for scratch" {
  run bash -c 'source '"${SCRATCH_HOME}"'/lib/dispatch.sh; dispatch:usage "scratch" "top-level desc" 2>&1'
  is "$status" 0
  [[ "$output" == *"USAGE"* ]]
  [[ "$output" == *"SUBCOMMANDS"* ]]
  [[ "$output" == *"doctor"* ]]
  [[ "$output" == *"project"* ]]
}

@test "dispatch:usage renders subcommand list for scratch-project" {
  run bash -c 'source '"${SCRATCH_HOME}"'/lib/dispatch.sh; dispatch:usage "scratch-project" "proj desc" 2>&1'
  is "$status" 0
  [[ "$output" == *"list"* ]]
  [[ "$output" == *"show"* ]]
  [[ "$output" == *"create"* ]]
  [[ "$output" == *"edit"* ]]
  [[ "$output" == *"delete"* ]]
}
