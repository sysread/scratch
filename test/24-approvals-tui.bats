#!/usr/bin/env bats

# vim: set ft=bash
set -euo pipefail

#-------------------------------------------------------------------------------
# Tests for lib/approvals/tui.sh and lib/approvals/tui/shell.sh
#
# Interactive gum calls are stubbed via function overrides. The
# non-interactive display and pattern generation helpers are tested
# directly.
#-------------------------------------------------------------------------------

setup() {
  SCRIPTDIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" > /dev/null 2>&1 && pwd)"
  SCRATCH_HOME="$(cd "${SCRIPTDIR}/.." && pwd)"
  source "${SCRIPTDIR}/helpers.sh"
  source "${SCRATCH_HOME}/lib/approvals/tui.sh"
  source "${SCRATCH_HOME}/lib/approvals/tui/shell.sh"

  # Isolate config
  export SCRATCH_CONFIG_DIR="${BATS_TEST_TMPDIR}/config"
  export SCRATCH_PROJECTS_DIR="${SCRATCH_CONFIG_DIR}/projects"
  mkdir -p "$SCRATCH_PROJECTS_DIR"

  source "${SCRATCH_HOME}/lib/project.sh"
  project:save "testproj" "/tmp/testproj" "false"

  source "${SCRATCH_HOME}/lib/conversations.sh"
  TEST_SLUG="$(conversation:create "testproj")"
  export SCRATCH_PROJECT="testproj"
  export SCRATCH_CONVERSATION_SLUG="$TEST_SLUG"
}

# ---------------------------------------------------------------------------
# approvals:tui-display-pipeline
# ---------------------------------------------------------------------------

@test "approvals:tui-display-pipeline shows command text" {
  local pipeline='{"operator":"|","expressions":[{"command":"ls","args":["-l"]},{"command":"wc","args":["-l"]}]}'

  # Capture stderr (where the display goes) by redirecting
  local output
  output="$(approvals:tui-display-pipeline "$pipeline" 2>&1)"

  [[ "$output" == *"ls -l"* ]]
  [[ "$output" == *"wc -l"* ]]
}

@test "approvals:tui-display-pipeline shows operator prefix" {
  local pipeline='{"operator":"|","expressions":[{"command":"ls","args":[]},{"command":"wc","args":[]}]}'

  local output
  output="$(approvals:tui-display-pipeline "$pipeline" 2>&1)"

  # Second line should have the operator
  [[ "$output" == *"| wc"* ]]
}

@test "approvals:tui-display-pipeline shows single command without operator" {
  local pipeline='{"operator":"","expressions":[{"command":"ls","args":["-l"]}]}'

  local output
  output="$(approvals:tui-display-pipeline "$pipeline" 2>&1)"

  [[ "$output" == *"ls -l"* ]]
  # Should not contain a pipe operator
  [[ "$output" != *"| "* ]]
}

# ---------------------------------------------------------------------------
# approvals:tui-shell with stubbed gum
# ---------------------------------------------------------------------------

@test "approvals:tui-shell: 'Approve (one-time)' sets result to approved" {
  # Stub gum choose to select "Approve (one-time)"
  # shellcheck disable=SC2329
  gum() {
    case "$1" in
      choose) echo "Approve (one-time)" ;;
      style) shift; echo "$*" >&2 ;;
    esac
  }
  export -f gum

  local pipeline='{"operator":"","expressions":[{"command":"ls","args":["-l"]}]}'
  local result=""
  approvals:tui-shell "$pipeline" result
  is "$result" "approved"
}

@test "approvals:tui-shell: 'Deny' sets result to denied" {
  # shellcheck disable=SC2329
  gum() {
    case "$1" in
      choose) echo "Deny" ;;
      style) shift; echo "$*" >&2 ;;
    esac
  }
  export -f gum

  local pipeline='{"operator":"","expressions":[{"command":"ls","args":["-l"]}]}'
  local result=""
  approvals:tui-shell "$pipeline" result || true
  is "$result" "denied"
}

@test "approvals:tui-shell: 'Approve and remember' persists approval" {
  # Track call count via file (gum runs in subshells)
  local call_file="${BATS_TEST_TMPDIR}/gum_call_count"
  printf '0' > "$call_file"
  export call_file

  # shellcheck disable=SC2329
  gum() {
    case "$1" in
      choose)
        local n
        n=$(<"$call_file")
        n=$((n + 1))
        printf '%s' "$n" > "$call_file"
        case "$n" in
          1) echo "Approve and remember" ;;
          2) echo "Wildcard: ls:*" ;;
          3) echo "Globally" ;;
        esac
        ;;
      style) shift; echo "$*" >&2 ;;
      input) echo "ls:*" ;;
    esac
  }
  export -f gum

  local pipeline='{"operator":"","expressions":[{"command":"ls","args":["-l"]}]}'
  local result=""
  approvals:tui-shell "$pipeline" result

  is "$result" "approved"

  # Verify the approval was persisted globally
  run approvals:is-approved shell "ls -a"
  is "$status" 0
}
