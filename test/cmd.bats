#!/usr/bin/env bats

# vim: set ft=bash
# shellcheck disable=SC2016
set -euo pipefail

#-------------------------------------------------------------------------------
# Tests for lib/cmd.sh
#
# Each test runs in a subprocess to get a clean cmd state (the global arrays
# accumulate across calls in the same process).
#-------------------------------------------------------------------------------

setup() {
  SCRIPTDIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" > /dev/null 2>&1 && pwd)"
  SCRATCH_HOME="$(cd "${SCRIPTDIR}/.." && pwd)"
  source "${SCRIPTDIR}/helpers.sh"
}

# Helper: run a cmd.sh script fragment in a clean subprocess
run_cmd() {
  run bash -c 'source '"${SCRATCH_HOME}"'/lib/cmd.sh; '"$1"''
}

# ---------------------------------------------------------------------------
# cmd:define + synopsis
# ---------------------------------------------------------------------------

@test "cmd:define stores name and description" {
  run_cmd '
    cmd:define "test" "A test command"
    cmd:parse synopsis
  '
  is "$status" 0
  is "$output" "A test command"
}

# ---------------------------------------------------------------------------
# cmd:flag
# ---------------------------------------------------------------------------

@test "cmd:flag defaults to off" {
  run_cmd '
    cmd:define "test" "desc"
    cmd:flag "--verbose" "-v" "Enable verbose"
    cmd:parse
    printf "%s" "$(cmd:get --verbose)"
  '
  is "$status" 0
  is "$output" "0"
}

@test "cmd:flag set to on when passed" {
  run_cmd '
    cmd:define "test" "desc"
    cmd:flag "--verbose" "-v" "Enable verbose"
    cmd:parse --verbose
    printf "%s" "$(cmd:get --verbose)"
  '
  is "$status" 0
  is "$output" "1"
}

@test "cmd:flag recognizes short form" {
  run_cmd '
    cmd:define "test" "desc"
    cmd:flag "--verbose" "-v" "Enable verbose"
    cmd:parse -v
    printf "%s" "$(cmd:get --verbose)"
  '
  is "$status" 0
  is "$output" "1"
}

@test "cmd:has returns true for set flag" {
  run_cmd '
    cmd:define "test" "desc"
    cmd:flag "--verbose" "-v" "Enable verbose"
    cmd:parse --verbose
    cmd:has --verbose && echo yes || echo no
  '
  is "$output" "yes"
}

@test "cmd:has returns false for unset flag" {
  run_cmd '
    cmd:define "test" "desc"
    cmd:flag "--verbose" "-v" "Enable verbose"
    cmd:parse
    cmd:has --verbose && echo yes || echo no
  '
  is "$output" "no"
}

# ---------------------------------------------------------------------------
# cmd:required-arg
# ---------------------------------------------------------------------------

@test "cmd:required-arg parses value" {
  run_cmd '
    cmd:define "test" "desc"
    cmd:required-arg "--name" "-n" "Name" "string"
    cmd:parse --name Alice
    printf "%s" "$(cmd:get --name)"
  '
  is "$status" 0
  is "$output" "Alice"
}

@test "cmd:required-arg parses short form" {
  run_cmd '
    cmd:define "test" "desc"
    cmd:required-arg "--name" "-n" "Name" "string"
    cmd:parse -n Alice
    printf "%s" "$(cmd:get --name)"
  '
  is "$status" 0
  is "$output" "Alice"
}

@test "cmd:validate fails when required arg missing" {
  run_cmd '
    cmd:define "test" "desc"
    cmd:required-arg "--name" "-n" "Name" "string"
    cmd:parse
    cmd:validate && echo ok || echo fail
  '
  is "$output" "fail"
}

@test "cmd:validate succeeds when required arg present" {
  run_cmd '
    cmd:define "test" "desc"
    cmd:required-arg "--name" "-n" "Name" "string"
    cmd:parse --name Alice
    cmd:validate && echo ok || echo fail
  '
  is "$output" "ok"
}

# ---------------------------------------------------------------------------
# cmd:optional-arg
# ---------------------------------------------------------------------------

@test "cmd:optional-arg uses default when not passed" {
  run_cmd '
    cmd:define "test" "desc"
    cmd:optional-arg "--greeting" "-g" "Greeting" "string" "Hello"
    cmd:parse
    printf "%s" "$(cmd:get --greeting)"
  '
  is "$output" "Hello"
}

@test "cmd:optional-arg uses provided value" {
  run_cmd '
    cmd:define "test" "desc"
    cmd:optional-arg "--greeting" "-g" "Greeting" "string" "Hello"
    cmd:parse --greeting Howdy
    printf "%s" "$(cmd:get --greeting)"
  '
  is "$output" "Howdy"
}

# ---------------------------------------------------------------------------
# cmd:get-into (nameref)
# ---------------------------------------------------------------------------

@test "cmd:get-into sets variable via nameref" {
  run_cmd '
    cmd:define "test" "desc"
    cmd:required-arg "--name" "-n" "Name" "string"
    cmd:parse --name Bob
    cmd:get-into MY_NAME --name
    printf "%s" "$MY_NAME"
  '
  is "$output" "Bob"
}

# ---------------------------------------------------------------------------
# cmd:rest (positionals)
# ---------------------------------------------------------------------------

@test "cmd:rest collects positional args" {
  run_cmd '
    cmd:define "test" "desc"
    cmd:flag "--verbose" "-v" "Verbose"
    cmd:parse -v -- foo bar baz
    cmd:rest
  '
  is "$status" 0
  [[ "$output" == *"foo"* ]]
  [[ "$output" == *"bar"* ]]
  [[ "$output" == *"baz"* ]]
}

@test "cmd:rest returns 1 when no positionals" {
  run_cmd '
    cmd:define "test" "desc"
    cmd:parse
    cmd:rest && echo yes || echo no
  '
  is "$output" "no"
}

# ---------------------------------------------------------------------------
# cmd:optional-value-arg
# ---------------------------------------------------------------------------

@test "cmd:optional-value-arg: not passed" {
  run_cmd '
    cmd:define "test" "desc"
    cmd:optional-value-arg "--team" "-t" "Team" "string"
    cmd:parse
    cmd:has --team && echo has || echo nope
  '
  is "$output" "nope"
}

@test "cmd:optional-value-arg: passed bare" {
  run_cmd '
    cmd:define "test" "desc"
    cmd:optional-value-arg "--team" "-t" "Team" "string"
    cmd:parse --team
    cmd:has --team && echo has || echo nope
    printf "val=[%s]" "$(cmd:get --team)"
  '
  [[ "$output" == *"has"* ]]
  [[ "$output" == *"val=[]"* ]]
}

@test "cmd:optional-value-arg: passed with value" {
  run_cmd '
    cmd:define "test" "desc"
    cmd:optional-value-arg "--team" "-t" "Team" "string"
    cmd:parse --team Infra
    cmd:has --team && echo has || echo nope
    printf "val=[%s]" "$(cmd:get --team)"
  '
  [[ "$output" == *"has"* ]]
  [[ "$output" == *"val=[Infra]"* ]]
}

# ---------------------------------------------------------------------------
# Error handling
# ---------------------------------------------------------------------------

@test "unknown flag is recorded as error" {
  run_cmd '
    cmd:define "test" "desc"
    cmd:parse --bogus
    cmd:validate && echo ok || echo fail
  '
  is "$output" "fail"
}

# ---------------------------------------------------------------------------
# cmd:usage exits with help output
# ---------------------------------------------------------------------------

@test "cmd:usage exits 0 on clean help" {
  run_cmd '
    cmd:define "test" "A test command"
    cmd:flag "--verbose" "-v" "Enable verbose"
    cmd:parse --help 2>&1
  '
  is "$status" 0
  [[ "$output" == *"USAGE"* ]]
  [[ "$output" == *"SYNOPSIS"* ]]
  [[ "$output" == *"A test command"* ]]
  [[ "$output" == *"--verbose"* ]]
}
