#!/usr/bin/env bats

# vim: set ft=bash
set -euo pipefail

#-------------------------------------------------------------------------------
# Tests for lib/approvals.sh and lib/approvals/{session,project,global}.sh
#
# Covers pattern matching, mode filtering, scope search order, CRUD, and
# graceful degradation when scopes are unavailable.
#-------------------------------------------------------------------------------

setup() {
  SCRIPTDIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" > /dev/null 2>&1 && pwd)"
  SCRATCH_HOME="$(cd "${SCRIPTDIR}/.." && pwd)"
  source "${SCRIPTDIR}/helpers.sh"
  source "${SCRATCH_HOME}/lib/approvals.sh"

  # Isolate from real config
  export SCRATCH_CONFIG_DIR="${BATS_TEST_TMPDIR}/config"
  export SCRATCH_PROJECTS_DIR="${SCRATCH_CONFIG_DIR}/projects"
  mkdir -p "$SCRATCH_PROJECTS_DIR"

  # Create a project for project-scoped tests
  source "${SCRATCH_HOME}/lib/project.sh"
  project:save "testproj" "/tmp/testproj" "false"

  # Create a conversation for session-scoped tests
  source "${SCRATCH_HOME}/lib/conversations.sh"
  TEST_SLUG="$(conversation:create "testproj")"
  export SCRATCH_PROJECT="testproj"
  export SCRATCH_CONVERSATION_SLUG="$TEST_SLUG"
}

# ---------------------------------------------------------------------------
# Pattern matching: exact
# ---------------------------------------------------------------------------

@test "_approvals:match-pattern exact: matches identical string" {
  run _approvals:match-pattern "ls -l -a" "ls -l -a" exact
  is "$status" 0
}

@test "_approvals:match-pattern exact: rejects different string" {
  run _approvals:match-pattern "ls -l -a" "ls -l" exact
  is "$status" 1
}

# ---------------------------------------------------------------------------
# Pattern matching: wildcard
# ---------------------------------------------------------------------------

@test "_approvals:match-pattern wildcard: matches same command any args" {
  run _approvals:match-pattern "ls -l -a" "ls:*" wildcard
  is "$status" 0
}

@test "_approvals:match-pattern wildcard: matches command with no args" {
  run _approvals:match-pattern "ls" "ls:*" wildcard
  is "$status" 0
}

@test "_approvals:match-pattern wildcard: rejects different command" {
  run _approvals:match-pattern "find /tmp" "ls:*" wildcard
  is "$status" 1
}

# ---------------------------------------------------------------------------
# Pattern matching: regex
# ---------------------------------------------------------------------------

@test "_approvals:match-pattern regex: matches with pcre" {
  run _approvals:match-pattern "find /tmp -name foo" '/^find\b/' regex
  is "$status" 0
}

@test "_approvals:match-pattern regex: rejects non-matching" {
  run _approvals:match-pattern "ls -l" '/^find\b/' regex
  is "$status" 1
}

@test "_approvals:match-pattern regex: negative lookahead works" {
  # Approve find but NOT find -exec
  run _approvals:match-pattern "find /tmp -name foo" '/^find\b(?!.*-exec)/' regex
  is "$status" 0

  run _approvals:match-pattern "find /tmp -exec rm {} ;" '/^find\b(?!.*-exec)/' regex
  is "$status" 1
}

# ---------------------------------------------------------------------------
# Command string reconstruction
# ---------------------------------------------------------------------------

@test "_approvals:command-string reconstructs command with args" {
  run _approvals:command-string '{"command":"ls","args":["-l","-a"]}'
  is "$status" 0
  is "$output" "ls -l -a"
}

@test "_approvals:command-string handles command with no args" {
  run _approvals:command-string '{"command":"pwd","args":[]}'
  is "$status" 0
  is "$output" "pwd"
}

@test "_approvals:command-string handles missing args key" {
  run _approvals:command-string '{"command":"pwd"}'
  is "$status" 0
  is "$output" "pwd"
}

# ---------------------------------------------------------------------------
# Mode filtering
# ---------------------------------------------------------------------------

@test "_approvals:mode-applies: null mode always applies" {
  run _approvals:mode-applies '{"mode": null}'
  is "$status" 0
}

@test "_approvals:mode-applies: mutable mode applies when SCRATCH_MUTABLE=1" {
  SCRATCH_MUTABLE=1 run _approvals:mode-applies '{"mode": "mutable"}'
  is "$status" 0
}

@test "_approvals:mode-applies: mutable mode rejects when SCRATCH_MUTABLE unset" {
  unset SCRATCH_MUTABLE
  run _approvals:mode-applies '{"mode": "mutable"}'
  is "$status" 1
}

# ---------------------------------------------------------------------------
# CRUD: add / list / remove
# ---------------------------------------------------------------------------

@test "approvals:add global + approvals:list global" {
  approvals:add global shell "ls:*" wildcard

  run approvals:list global
  is "$status" 0
  [[ "$output" == *'"pattern":"ls:*"'* ]]
  [[ "$output" == *'"class":"shell"'* ]]
}

@test "approvals:add project + approvals:list project" {
  approvals:add project shell "grep:*" wildcard

  run approvals:list project
  is "$status" 0
  [[ "$output" == *'"pattern":"grep:*"'* ]]
}

@test "approvals:add session + approvals:list session" {
  approvals:add session shell "wc -l" exact

  run approvals:list session
  is "$status" 0
  [[ "$output" == *'"pattern":"wc -l"'* ]]
}

@test "approvals:remove removes matching record" {
  approvals:add global shell "ls:*" wildcard
  approvals:add global shell "grep:*" wildcard

  approvals:remove global shell "ls:*"

  run approvals:list global
  is "$status" 0
  [[ "$output" != *'"pattern":"ls:*"'* ]]
  [[ "$output" == *'"pattern":"grep:*"'* ]]
}

@test "approvals:add with mutable mode" {
  approvals:add global shell '/^find\b/' regex mutable

  run approvals:list global
  is "$status" 0
  [[ "$output" == *'"mode":"mutable"'* ]]
}

# ---------------------------------------------------------------------------
# approvals:is-approved - scope search
# ---------------------------------------------------------------------------

@test "approvals:is-approved finds match in global scope" {
  approvals:add global shell "ls:*" wildcard
  run approvals:is-approved shell "ls -l"
  is "$status" 0
}

@test "approvals:is-approved finds match in project scope" {
  approvals:add project shell "cat:*" wildcard
  run approvals:is-approved shell "cat /etc/hosts"
  is "$status" 0
}

@test "approvals:is-approved finds match in session scope" {
  approvals:add session shell "echo hello" exact
  run approvals:is-approved shell "echo hello"
  is "$status" 0
}

@test "approvals:is-approved returns 1 when no match" {
  run approvals:is-approved shell "rm -rf /"
  is "$status" 1
}

@test "approvals:is-approved honors SCRATCH_APPROVALS_SKIP" {
  SCRATCH_APPROVALS_SKIP=1 run approvals:is-approved shell "anything"
  is "$status" 0
}

# ---------------------------------------------------------------------------
# approvals:check-shell
# ---------------------------------------------------------------------------

@test "approvals:check-shell approves fully-approved pipeline" {
  approvals:add global shell "ls:*" wildcard
  approvals:add global shell "wc:*" wildcard

  local pipeline='{"operator":"|","expressions":[{"command":"ls","args":["-l"]},{"command":"wc","args":["-l"]}]}'
  run approvals:check-shell "$pipeline"
  is "$status" 0
}

@test "approvals:check-shell rejects pipeline with unapproved segment" {
  approvals:add global shell "ls:*" wildcard
  # wc is NOT approved

  local pipeline='{"operator":"|","expressions":[{"command":"ls","args":["-l"]},{"command":"wc","args":["-l"]}]}'
  run approvals:check-shell "$pipeline"
  is "$status" 1
}

# ---------------------------------------------------------------------------
# Graceful degradation
# ---------------------------------------------------------------------------

@test "approvals:is-approved works when session scope is unavailable" {
  unset SCRATCH_CONVERSATION_SLUG
  approvals:add global shell "ls:*" wildcard

  run approvals:is-approved shell "ls"
  is "$status" 0
}

@test "approvals:is-approved works when project scope is unavailable" {
  unset SCRATCH_PROJECT
  approvals:add global shell "ls:*" wildcard

  run approvals:is-approved shell "ls"
  is "$status" 0
}

# ---------------------------------------------------------------------------
# Atomic write safety
# ---------------------------------------------------------------------------

@test "global approvals file is valid JSON after save" {
  approvals:add global shell "ls:*" wildcard

  local path
  path="$(_approvals:global-path)"
  [[ -f "$path" ]]
  run jq -e . "$path"
  is "$status" 0
}

@test "project approvals file is valid JSON after save" {
  approvals:add project shell "cat:*" wildcard

  local path
  path="$(_approvals:project-path "testproj")"
  [[ -f "$path" ]]
  run jq -e . "$path"
  is "$status" 0
}
