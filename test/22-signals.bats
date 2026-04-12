#!/usr/bin/env bats

# vim: set ft=bash
set -euo pipefail

#-------------------------------------------------------------------------------
# Tests for lib/signals.sh
#
# Signal handler tests use subprocess patterns (bash -c) to isolate trap
# state. The parent bats process must not have its traps modified by the
# tests.
#-------------------------------------------------------------------------------

setup() {
  SCRIPTDIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" > /dev/null 2>&1 && pwd)"
  SCRATCH_HOME="$(cd "${SCRIPTDIR}/.." && pwd)"
  source "${SCRIPTDIR}/helpers.sh"
  source "${SCRATCH_HOME}/lib/signals.sh"

  export HOME="${BATS_TEST_TMPDIR}/home"
  mkdir -p "$HOME"
}

# ---------------------------------------------------------------------------
# signal:register / signal:list
# ---------------------------------------------------------------------------

@test "signal:register adds a handler" {
  signal:register EXIT testhandler "echo hello"
  run signal:list EXIT
  is "$status" 0
  is "$output" "testhandler"
}

@test "signal:register replaces same-name handler" {
  signal:register EXIT myhandler "echo first"
  signal:register EXIT myhandler "echo second"

  run signal:list EXIT
  is "$status" 0
  is "$output" "myhandler"

  # Only one entry
  local count
  count="$(signal:list EXIT | wc -l | tr -d ' ')"
  is "$count" "1"
}

@test "signal:register preserves FIFO order" {
  signal:register EXIT first "echo 1"
  signal:register EXIT second "echo 2"
  signal:register EXIT third "echo 3"

  run signal:list EXIT
  is "$status" 0
  local expected
  expected="$(printf 'first\nsecond\nthird')"
  is "$output" "$expected"
}

@test "signal:register rejects unknown signal" {
  run signal:register USR1 handler "echo hi"
  is "$status" 1
  [[ "$output" == *"unsupported signal"* ]]
}

@test "signal:register rejects empty name" {
  run signal:register EXIT "" "echo hi"
  is "$status" 1
  [[ "$output" == *"name must not be empty"* ]]
}

@test "signal:register rejects empty command" {
  run signal:register EXIT myhandler ""
  is "$status" 1
  [[ "$output" == *"command must not be empty"* ]]
}

# ---------------------------------------------------------------------------
# signal:unregister
# ---------------------------------------------------------------------------

@test "signal:unregister removes a handler" {
  signal:register EXIT gone "echo bye"
  signal:unregister EXIT gone

  run signal:list EXIT
  is "$status" 0
  is "$output" ""
}

@test "signal:unregister is idempotent for unknown name" {
  run signal:unregister EXIT nonexistent
  is "$status" 0
}

@test "signal:unregister preserves other handlers" {
  signal:register EXIT keep "echo keep"
  signal:register EXIT remove "echo remove"
  signal:register EXIT also-keep "echo also-keep"

  signal:unregister EXIT remove

  run signal:list EXIT
  is "$status" 0
  local expected
  expected="$(printf 'keep\nalso-keep')"
  is "$output" "$expected"
}

# ---------------------------------------------------------------------------
# _signal:dispatch
# ---------------------------------------------------------------------------

@test "_signal:dispatch EXIT runs handlers in FIFO order" {
  run bash -c '
    source "'"${SCRATCH_HOME}"'/lib/signals.sh"
    signal:register EXIT first "printf first-"
    signal:register EXIT second "printf second"
    exit 0
  '
  is "$status" 0
  is "$output" "first-second"
}

@test "_signal:dispatch continues after handler failure" {
  run bash -c '
    source "'"${SCRATCH_HOME}"'/lib/signals.sh"
    signal:register EXIT broken "false"
    signal:register EXIT working "printf ok"
    exit 0
  '
  is "$status" 0
  is "$output" "ok"
}

@test "INT dispatch exits with 130" {
  run bash -c '
    source "'"${SCRATCH_HOME}"'/lib/signals.sh"
    signal:register INT handler "true"
    kill -INT $$
  '
  is "$status" 130
}

@test "TERM dispatch exits with 143" {
  run bash -c '
    source "'"${SCRATCH_HOME}"'/lib/signals.sh"
    signal:register TERM handler "true"
    kill -TERM $$
  '
  is "$status" 143
}

@test "EXIT handlers fire after INT dispatch" {
  run bash -c '
    source "'"${SCRATCH_HOME}"'/lib/signals.sh"
    signal:register EXIT cleanup "printf cleanup"
    signal:register INT notify "printf notify-"
    kill -INT $$
  '
  is "$status" 130
  is "$output" "notify-cleanup"
}

@test "replaced handler uses new command" {
  run bash -c '
    source "'"${SCRATCH_HOME}"'/lib/signals.sh"
    signal:register EXIT myhandler "printf old"
    signal:register EXIT myhandler "printf new"
    exit 0
  '
  is "$status" 0
  is "$output" "new"
}

# ---------------------------------------------------------------------------
# signal:list
# ---------------------------------------------------------------------------

@test "signal:list returns empty for signal with no handlers" {
  run signal:list EXIT
  is "$status" 0
  is "$output" ""
}

@test "signal:list rejects unknown signal" {
  run signal:list BOGUS
  is "$status" 1
}
