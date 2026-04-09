#!/usr/bin/env bats

# vim: set ft=bash
set -euo pipefail

#-------------------------------------------------------------------------------
# Tests for lib/tui.sh
#
# Focused on tui:log's dispatch (args vs piped stdin) and the
# stderr-only output guarantee. The interactive helpers (tui:choose-one,
# tui:spin, etc.) need a real terminal and are out of scope here.
#-------------------------------------------------------------------------------

setup() {
  SCRIPTDIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" > /dev/null 2>&1 && pwd)"
  SCRATCH_HOME="$(cd "${SCRIPTDIR}/.." && pwd)"
  source "${SCRIPTDIR}/helpers.sh"
  source "${SCRATCH_HOME}/lib/tui.sh"

  export HOME="${BATS_TEST_TMPDIR}/home"
  mkdir -p "$HOME"
}

# ---------------------------------------------------------------------------
# tui:log: args mode
# ---------------------------------------------------------------------------

@test "tui:warn with a message arg writes to stderr" {
  run --separate-stderr tui:warn "hello stderr"
  is "$status" 0
  is "$output" ""
  [[ "$stderr" == *"hello stderr"* ]]
}

@test "tui:info with a message arg writes to stderr (script context, not a TTY)" {
  # The whole point of the redesign: a non-interactive script call must
  # land on stderr, not be silently swallowed by the old TTY check.
  run --separate-stderr tui:info "scripted message"
  is "$status" 0
  [[ "$stderr" == *"scripted message"* ]]
}

@test "tui:warn with structured fields renders them as key=value" {
  run --separate-stderr tui:warn "main message" detail "extra info" code "42"
  is "$status" 0
  [[ "$stderr" == *"main message"* ]]
  [[ "$stderr" == *"detail=extra info"* || "$stderr" == *"detail=\"extra info\""* ]]
  [[ "$stderr" == *"code=42"* ]]
}

@test "tui:error with a message arg writes to stderr" {
  run --separate-stderr tui:error "boom"
  is "$status" 0
  [[ "$stderr" == *"boom"* ]]
}

@test "tui:debug is suppressed at default log level (info)" {
  run --separate-stderr tui:debug "noisy"
  is "$status" 0
  is "$stderr" ""
}

# ---------------------------------------------------------------------------
# tui:log: pipe mode
# ---------------------------------------------------------------------------

@test "tui:info reads stdin line by line when no args are supplied" {
  run --separate-stderr bash -c 'source lib/tui.sh; printf "alpha\nbeta\ngamma\n" | tui:info'
  is "$status" 0
  [[ "$stderr" == *"alpha"* ]]
  [[ "$stderr" == *"beta"* ]]
  [[ "$stderr" == *"gamma"* ]]
}

@test "tui:warn pipe mode with empty stdin emits nothing and exits 0" {
  run --separate-stderr bash -c 'source lib/tui.sh; : | tui:warn'
  is "$status" 0
  is "$stderr" ""
}

# ---------------------------------------------------------------------------
# stdout/stderr separation
# ---------------------------------------------------------------------------

@test "tui:warn does not write to stdout" {
  run --separate-stderr tui:warn "should be on stderr only"
  is "$output" ""
}

# ---------------------------------------------------------------------------
# SCRATCH_LOG_LEVEL filtering
# ---------------------------------------------------------------------------

@test "SCRATCH_LOG_LEVEL=warn suppresses debug and info" {
  run --separate-stderr bash -c "
    export SCRATCH_LOG_LEVEL=warn
    _INCLUDED_TUI='' source '${SCRATCH_HOME}/lib/tui.sh'
    tui:debug 'should be hidden'
    tui:info 'also hidden'
    tui:warn 'should show'
  "
  is "$status" 0
  [[ "$stderr" != *"should be hidden"* ]]
  [[ "$stderr" != *"also hidden"* ]]
  [[ "$stderr" == *"should show"* ]]
}

@test "SCRATCH_LOG_LEVEL=error suppresses everything below error" {
  run --separate-stderr bash -c "
    export SCRATCH_LOG_LEVEL=error
    _INCLUDED_TUI='' source '${SCRATCH_HOME}/lib/tui.sh'
    tui:debug 'hidden'
    tui:info 'hidden'
    tui:warn 'hidden'
    tui:error 'visible'
  "
  is "$status" 0
  [[ "$stderr" == *"visible"* ]]
  # Only "visible" should be in stderr (4 calls, 1 output)
  local line_count
  line_count="$(echo "$stderr" | grep -c '.' || true)"
  is "$line_count" "1"
}

@test "SCRATCH_LOG_LEVEL=debug shows everything" {
  run --separate-stderr bash -c "
    export SCRATCH_LOG_LEVEL=debug
    _INCLUDED_TUI='' source '${SCRATCH_HOME}/lib/tui.sh'
    tui:debug 'visible'
  "
  is "$status" 0
  [[ "$stderr" == *"visible"* ]]
}

@test "SCRATCH_LOG_LEVEL defaults to info (debug suppressed)" {
  run --separate-stderr bash -c "
    unset SCRATCH_LOG_LEVEL
    _INCLUDED_TUI='' source '${SCRATCH_HOME}/lib/tui.sh'
    tui:debug 'should be hidden'
    tui:info 'should show'
  "
  is "$status" 0
  [[ "$stderr" != *"should be hidden"* ]]
  [[ "$stderr" == *"should show"* ]]
}

@test "log level filtering drains stdin in pipe mode" {
  run --separate-stderr bash -c "
    export SCRATCH_LOG_LEVEL=error
    _INCLUDED_TUI='' source '${SCRATCH_HOME}/lib/tui.sh'
    printf 'line1\nline2\n' | tui:info
  "
  is "$status" 0
  is "$stderr" ""
}

# ---------------------------------------------------------------------------
# tui:*-if conditional variants
# ---------------------------------------------------------------------------

@test "tui:debug-if logs when env var is set" {
  export MY_DEBUG_FLAG=1
  run --separate-stderr tui:debug-if MY_DEBUG_FLAG "conditional debug"
  [[ "$stderr" == *"conditional debug"* ]]
}

@test "tui:debug-if is silent when env var is unset" {
  unset MY_DEBUG_FLAG
  run --separate-stderr tui:debug-if MY_DEBUG_FLAG "should not appear"
  is "$stderr" ""
}

@test "tui:info-if logs when env var is set" {
  export MY_FLAG=yes
  run --separate-stderr tui:info-if MY_FLAG "conditional info"
  [[ "$stderr" == *"conditional info"* ]]
}

@test "tui:info-if is silent when env var is unset" {
  unset MY_FLAG
  run --separate-stderr tui:info-if MY_FLAG "should not appear"
  is "$stderr" ""
}
