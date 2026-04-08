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

@test "tui:debug with a message arg writes to stderr" {
  run --separate-stderr tui:debug "noisy"
  is "$status" 0
  [[ "$stderr" == *"noisy"* ]]
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
