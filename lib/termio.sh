#!/usr/bin/env bash

#-------------------------------------------------------------------------------
# Terminal I/O utilities
#-------------------------------------------------------------------------------

#-------------------------------------------------------------------------------
# Prevent multiple inclusions
#-------------------------------------------------------------------------------
[[ "${_INCLUDED_TERMIO:-}" == "1" ]] && return 0
_INCLUDED_TERMIO=1

#-------------------------------------------------------------------------------
# Imports
#-------------------------------------------------------------------------------
_TERMIO_SCRIPTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source-path=SCRIPTDIR/lib
# shellcheck disable=SC1091
source "$_TERMIO_SCRIPTDIR/base.sh"

#-------------------------------------------------------------------------------
# Note on stdbuf: io:autoflush and io:sedl use stdbuf when available but
# fall back gracefully when it is not. We intentionally do NOT declare
# `has-commands stdbuf` here because that would die at source time on
# systems without it, defeating the fallback. stdbuf is an optional
# performance enhancement, not a hard requirement.
#-------------------------------------------------------------------------------

#-------------------------------------------------------------------------------
# io:is-tty [FD]
#
# Test whether the given file descriptor (default: 1 / stdout) is connected
# to a terminal.
#
# Examples:
#   if io:is-tty; then ...          # check stdout (default)
#   if io:is-tty 2; then ...        # check stderr
#-------------------------------------------------------------------------------
io:is-tty() {
  [[ -t "${1:-1}" ]]
}

export -f io:is-tty

#-------------------------------------------------------------------------------
# io:autoflush COMMAND [ARGS...]
#
# Run a command with line-buffered stdout and stderr. Uses stdbuf when
# available, otherwise falls back to running the command directly.
#
# Examples:
#   io:autoflush some_command --flag
#-------------------------------------------------------------------------------
io:autoflush() {
  if command -v stdbuf > /dev/null 2>&1; then
    stdbuf -oL -eL "$@"
  else
    "$@"
  fi
}

export -f io:autoflush

#-------------------------------------------------------------------------------
# io:sedl REGEX
#
# Line-buffered sed with extended regex. Keeps streaming transforms in
# pipelines from batching until stdin closes.
#
# - BSD/macOS sed supports -l for line-buffered output.
# - GNU sed does not; we fall back to stdbuf wrapping.
#-------------------------------------------------------------------------------
io:sedl() {
  local ext=()
  if sed -E '' < /dev/null > /dev/null 2>&1; then
    ext=(-E)
  elif sed --version > /dev/null 2>&1; then
    ext=(-r)
  fi

  # BSD/macOS: sed -l is line buffered
  if sed -l '' < /dev/null > /dev/null 2>&1; then
    sed -l "${ext[@]}" "$@"
    return
  fi

  # GNU: line-buffer via stdbuf if available, otherwise plain sed
  io:autoflush sed "${ext[@]}" "$@"
}

export -f io:sedl

#-------------------------------------------------------------------------------
# io:trim
#
# Trim leading and trailing whitespace from stdin, skip empty lines.
#-------------------------------------------------------------------------------
io:trim() {
  io:sedl 's/^[[:space:]]+//;s/[[:space:]]+$//' | grep -v '^$'
}

export -f io:trim

#-------------------------------------------------------------------------------
# io:strip-ansi
#
# Strip ANSI escape codes from stdin.
#-------------------------------------------------------------------------------
io:strip-ansi() {
  io:sedl 's/\x1B\[[0-9;]*[mK]//g'
}

export -f io:strip-ansi

#-------------------------------------------------------------------------------
# io:strip-ansi-notty
#
# Strip ANSI escape codes from stdin only if stdout is not a terminal.
# Pass-through when interactive.
#-------------------------------------------------------------------------------
io:strip-ansi-notty() {
  if io:is-tty; then
    cat
  else
    io:strip-ansi
  fi
}

export -f io:strip-ansi-notty

#-------------------------------------------------------------------------------
# io:has-flag FLAG ARGS...
#
# Check if a specific flag is present in the given arguments.
#
# Examples:
#   if io:has-flag --color "$@"; then ...
#-------------------------------------------------------------------------------
io:has-flag() {
  local flag="$1"
  shift

  for arg in "$@"; do
    [[ "$arg" == "$flag" ]] && return 0
  done

  return 1
}

export -f io:has-flag

#-------------------------------------------------------------------------------
# io:is-non-empty MESSAGE
#
# Validates that stdin is non-empty, or dies with the provided message.
# Data is printed unchanged if validation passes.
#
# IMPORTANT: reads entire input into memory before validating.
#-------------------------------------------------------------------------------
io:is-non-empty() {
  local msg="$1"
  local input

  input="$(cat)"
  if [[ -z "$input" ]]; then
    die "$msg"
    return 1
  fi

  printf '%s\n' "$input"
}

export -f io:is-non-empty
