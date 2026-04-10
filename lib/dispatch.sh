#!/usr/bin/env bash

#-------------------------------------------------------------------------------
# Subcommand dispatch library
#
# Parameterized dispatch for hierarchical subcommands. Commands are resolved
# by filename convention:
#
#   scratch project list
#   |       |       |
#   |       |       bin/scratch-project-list    (leaf)
#   |       bin/scratch-project                 (parent dispatcher)
#   helpers/root-dispatcher                     (top-level dispatcher)
#
# Each hyphen in a binary name is a level separator. A "direct child" of a
# prefix P is a binary whose basename is P-<word> where <word> contains no
# further hyphens. This means subcommand names cannot contain hyphens.
#
# Typical usage in a parent command:
#
#   # Respond to synopsis first, for the parent of this command
#   if [[ "${1:-}" == "synopsis" ]]; then
#     echo "Manage project configurations"; exit 0
#   fi
#
#   # Try to dispatch to a child
#   dispatch:try "scratch-project" "$@"
#
#   # Fallthrough: no child matched. Print usage and exit.
#   dispatch:usage "scratch-project" "Manage project configurations" >&2
#   exit 1
#
# If a child matches, dispatch:try execs into it and never returns. If no
# child matches (no args, unknown verb, or flags without a verb), it returns
# non-zero so the caller can decide what to do (print usage, run a default
# action, etc.).
#-------------------------------------------------------------------------------

[[ "${_INCLUDED_DISPATCH:-}" == "1" ]] && return 0
_INCLUDED_DISPATCH=1

_DISPATCH_SCRIPTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source-path=SCRIPTDIR/lib
# shellcheck disable=SC1091
source "$_DISPATCH_SCRIPTDIR/base.sh"

#-------------------------------------------------------------------------------
# dispatch:bindir
#
# (Private) Print the absolute path to the bin/ directory where scratch
# subcommand binaries live. Resolved relative to this library's location.
#-------------------------------------------------------------------------------
dispatch:bindir() {
  printf '%s\n' "$(cd "${_DISPATCH_SCRIPTDIR}/../bin" && pwd)"
}

export -f dispatch:bindir

#-------------------------------------------------------------------------------
# dispatch:list PREFIX
#
# Print the verb names of all direct-child subcommands of PREFIX, one per
# line, sorted. A direct child is a binary named <prefix>-<verb> where <verb>
# contains no further hyphens. Files without the executable bit are skipped.
#
# Example:
#   dispatch:list "scratch"          # -> doctor, project, ...
#   dispatch:list "scratch-project"  # -> create, delete, edit, list, show
#-------------------------------------------------------------------------------
dispatch:list() {
  local prefix="$1"
  local bindir
  local file
  local verb

  bindir="$(dispatch:bindir)"

  for file in "${bindir}/${prefix}"-*; do
    [[ -f "$file" && -x "$file" ]] || continue

    verb="$(basename "$file")"
    verb="${verb#"${prefix}-"}"

    # Direct children only: reject verbs that contain further hyphens
    # (those belong to a deeper level).
    [[ "$verb" == *-* ]] && continue

    printf '%s\n' "$verb"
  done | sort
}

export -f dispatch:list

#-------------------------------------------------------------------------------
# dispatch:path PREFIX VERB
#
# Print the absolute path to the binary implementing VERB under PREFIX.
# Returns 1 if the binary does not exist or is not executable.
#-------------------------------------------------------------------------------
dispatch:path() {
  local prefix="$1"
  local verb="$2"
  local bindir
  local path

  bindir="$(dispatch:bindir)"
  path="${bindir}/${prefix}-${verb}"

  if [[ -f "$path" && -x "$path" ]]; then
    printf '%s\n' "$path"
    return 0
  fi

  return 1
}

export -f dispatch:path

#-------------------------------------------------------------------------------
# dispatch:usage PREFIX DESC
#
# Print a markdown help page to stderr listing all direct-child subcommands
# with their synopsis lines. Renders via tui:format when available, falls
# back to cat.
#
# PREFIX is the binary prefix (e.g. "scratch" or "scratch-project").
# DESC is the one-line description for the SYNOPSIS section.
#-------------------------------------------------------------------------------
dispatch:usage() {
  local prefix="$1"
  local desc="$2"
  local display_name
  local verb
  local path
  local synopsis

  # Convert hyphens to spaces for the display name in USAGE section:
  # "scratch-project" -> "scratch project"
  display_name="${prefix//-/ }"

  {
    printf '# USAGE\n\n'
    # shellcheck disable=SC2016
    printf '`%s <command> [args...]`\n\n' "$display_name"

    printf '# SYNOPSIS\n\n'
    printf '%s\n\n' "$desc"

    printf '# OPTIONS\n\n'
    # shellcheck disable=SC2016
    printf -- '- `-h | --help`\tShow this help message and exit\n'

    printf '\n# SUBCOMMANDS\n\n'
    while IFS= read -r verb; do
      [[ -n "$verb" ]] || continue
      path="$(dispatch:path "$prefix" "$verb")" || continue
      synopsis="$("$path" synopsis 2> /dev/null || echo "")"
      # shellcheck disable=SC2016
      printf -- '\- `%s`\t%s\n' "$verb" "$synopsis"
    done < <(dispatch:list "$prefix")
  } | _dispatch:format >&2
}

export -f dispatch:usage

#-------------------------------------------------------------------------------
# _dispatch:format
#
# (Private) Pipe filter for rendering markdown help. Uses tui:format when
# available, falls back to cat.
#-------------------------------------------------------------------------------
_dispatch:format() {
  if type -t tui:format &> /dev/null; then
    tui:format
  else
    cat
  fi
}

export -f _dispatch:format

#-------------------------------------------------------------------------------
# dispatch:try PREFIX "$@"
#
# Attempt to resolve and execute a subcommand based on argv.
#
# If the first non-flag argument matches a known subcommand of PREFIX,
# exec into that subcommand with the remaining argv. Never returns on success.
#
# If there are no args, or the first arg is -h / --help, or the first arg
# does not match any known subcommand, return 1 so the caller can handle
# the fallthrough (print usage, run a default, show a dancing hamster, etc.).
#
# Special cases handled here:
#   -h / --help      return 1 (caller prints usage)
#   help <verb>      exec <verb> --help
#   synopsis         return 1 (caller handles its own synopsis before calling)
#
# Example:
#   dispatch:try "scratch-project" "$@"
#   # If we're here, no child matched. Do the fallthrough.
#   dispatch:usage "scratch-project" "Manage projects"
#   exit 1
#-------------------------------------------------------------------------------
dispatch:try() {
  local prefix="$1"
  shift

  # No args - caller handles fallthrough
  (($# == 0)) && return 1

  local first="$1"

  case "$first" in
    -h | --help)
      return 1
      ;;

    synopsis)
      # Caller owns synopsis - it must handle this BEFORE calling dispatch:try
      return 1
      ;;

    -*)
      # Unrecognized flag at this level. Caller handles.
      return 1
      ;;
  esac

  # Try to resolve the first arg as a subcommand verb
  local path
  if path="$(dispatch:path "$prefix" "$first")"; then
    shift
    exec "$path" "$@"
  fi

  # Unknown verb - caller handles fallthrough
  return 1
}

export -f dispatch:try
