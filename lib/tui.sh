#!/usr/bin/env bash

#-------------------------------------------------------------------------------
# TUI utilities - gum wrappers for logging, formatting, and user interaction
#-------------------------------------------------------------------------------

#-------------------------------------------------------------------------------
# Prevent multiple inclusions
#-------------------------------------------------------------------------------
[[ "${_INCLUDED_TUI:-}" == "1" ]] && return 0
_INCLUDED_TUI=1

#-------------------------------------------------------------------------------
# Imports
#-------------------------------------------------------------------------------
_TUI_SCRIPTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source-path=SCRIPTDIR/lib
# shellcheck disable=SC1091
{
  source "$_TUI_SCRIPTDIR/base.sh"
  source "$_TUI_SCRIPTDIR/termio.sh"
}

has-commands gum

#-------------------------------------------------------------------------------
# tui:log LEVEL [ARGS...]
#
# Log a structured message to stderr via gum. When stdin is a pipe, reads
# line-by-line and logs each line with the given args as structured fields.
#
# Examples:
#   tui:log info "Starting process"
#   tui:log error "Failed" detail "connection refused"
#   some_command 2>&1 | tui:log info "output"
#-------------------------------------------------------------------------------
tui:log() {
  local level="$1"
  local line
  shift

  if [[ -t 0 ]]; then
    gum log --structured --level "$level" "$@"
  else
    while read -r line; do
      gum log --structured --level "$level" "$line" "$@"
    done
  fi

  return 0
}

tui:debug() { tui:log debug "$@"; }
tui:info() { tui:log info "$@"; }
tui:warn() { tui:log warn "$@"; }
tui:error() { tui:log error "$@"; }

tui:die() {
  tui:error "$1" "${@:2}"
  die "$1"
}

export -f \
  tui:log \
  tui:debug \
  tui:info \
  tui:warn \
  tui:error \
  tui:die

#-------------------------------------------------------------------------------
# tui:format
#
# Render markdown via gum format when connected to a terminal.
# Falls back to plain text (cat) when piped.
#-------------------------------------------------------------------------------
tui:format() {
  if io:is-tty; then
    gum format
  else
    cat
  fi
}

export -f tui:format

#-------------------------------------------------------------------------------
# tui:spin TITLE
#
# Show a spinner while running a command piped to stdin. Stderr from the
# command is dropped. Stdout is passed through.
#-------------------------------------------------------------------------------
tui:spin() {
  local title="${1:-Working...}"
  gum spin --show-stdout --title "$title"
}

export -f tui:spin

#-------------------------------------------------------------------------------
# tui:choose VAR HEADER PROMPT [gum filter args...]
#
# Prompt the user to choose from a list on stdin using gum filter. The
# selection is assigned to the variable named by VAR (nameref).
#
# - Escape (no selection): assigns empty string, returns 0
# - Ctrl-C (abort): returns 1
#
# IMPORTANT: Under set -e, do not let the [[ -z "$var" ]] guard be the last
# statement in a function. Add an explicit return 0 after it:
#
#   tui:choose-one MY_VAR "Header" "Prompt" <<< "$options"
#   [[ -z "$MY_VAR" ]] && die "nothing selected"
#   return 0
#
# Examples:
#   tui:choose fav "FRUITS" "Pick one" <<< $'apple\nbanana\ncherry'
#-------------------------------------------------------------------------------
tui:choose() {
  local -n into="$1"
  local header="$2"
  local prompt="$3"
  local rest=("${@:4}")
  local exit_code

  # shellcheck disable=SC2034
  into="$(
    gum filter \
      --height 20 \
      --fuzzy \
      --fuzzy-sort \
      --header "$header" \
      --prompt "$prompt: " \
      "${rest[@]}"
  )" || {
    exit_code=$?

    # gum prints "nothing selected" to stderr on escape. We can't filter it
    # in a pipe without also filtering the interactive prompt. Instead,
    # manipulate the terminal directly to erase it.
    printf '\033[1A\033[2K' > /dev/tty

    # 130: ctrl-c, user aborted
    ((exit_code == 130)) && return 1

    # Otherwise escape - treat as non-error, empty selection
    into=""
  }

  return 0
}

export -f tui:choose

#-------------------------------------------------------------------------------
# tui:choose-one VAR HEADER PROMPT [gum filter args...]
#
# Like tui:choose but limited to a single selection. Auto-selects if only
# one option is available.
#-------------------------------------------------------------------------------
tui:choose-one() {
  # shellcheck disable=SC2034
  local -n into_one="$1"
  local header="$2"
  local prompt="$3"
  local rest=("${@:4}")
  tui:choose into_one "$header" "$prompt" "${rest[@]}" --limit 1 --select-if-one
}

export -f tui:choose-one
