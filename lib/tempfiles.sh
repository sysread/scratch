#!/usr/bin/env bash

#-------------------------------------------------------------------------------
# Temp file tracking and cleanup
#
# Provides an in-memory temp file registry with automatic cleanup on process
# exit. Tracks created temp files and deletes them when the process receives
# EXIT/INT/TERM/HUP signals.
#
# Design constraints:
#   - Bash-only, in-process lifecycle manager
#   - Cannot clean up after SIGKILL or host crash
#   - Files are kept for the lifetime of the process so callers have a chance
#     to read them before cleanup
#-------------------------------------------------------------------------------

set -euo pipefail

#-------------------------------------------------------------------------------
# Prevent multiple inclusions
#-------------------------------------------------------------------------------
[[ "${_INCLUDED_TEMPFILES:-}" == "1" ]] && return 0
_INCLUDED_TEMPFILES=1

#-------------------------------------------------------------------------------
# Imports
#-------------------------------------------------------------------------------
_TEMPFILES_SCRIPTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source-path=SCRIPTDIR/lib
# shellcheck disable=SC1091
source "$_TEMPFILES_SCRIPTDIR/base.sh"

#-------------------------------------------------------------------------------
# Internal logging helper - safe in non-TTY contexts (EXIT traps, pipes).
# Uses tui:debug when available and stderr is a terminal, otherwise plain
# fprintf to stderr.
#-------------------------------------------------------------------------------
tmp:_log() {
  if [[ -t 2 ]] && command -v gum > /dev/null 2>&1 && type tui:debug > /dev/null 2>&1; then
    tui:debug "$@" || true
  else
    printf 'WARN: %s\n' "$*" >&2
  fi
}

#-------------------------------------------------------------------------------
# Globals
#-------------------------------------------------------------------------------

# Paths of temp files registered for deletion when the process exits.
# No deduplication - deletion is idempotent and best-effort.
# shellcheck disable=SC2034
declare -ag SCRATCH_TMPFILES=()

# Guard so we only register traps once per process.
_TMPFILES_TRAPS_INSTALLED=0

#-------------------------------------------------------------------------------
# tmp:track PATH
#
# Register a path for deletion during tmp:cleanup.
#-------------------------------------------------------------------------------
tmp:track() {
  local path="${1:-}"
  [[ -n "$path" ]] || die "tmp:track requires a path"

  SCRATCH_TMPFILES+=("$path")
  return 0
}

export -f tmp:track

#-------------------------------------------------------------------------------
# tmp:make VAR TEMPLATE [mktemp args...]
#
# Create a temp file using mktemp, register it for cleanup, and assign the
# path to VAR via nameref.
#
# WARNING: Command substitution $(...) runs in a subshell. The temp file
# registry lives in the current process's memory. Capturing the result with
# $(...) would only register the file in the subshell, so the parent loses
# track and cleanup breaks. This is why tmp:make uses a nameref API.
#
# WRONG:
#   tmpfile=$(tmp:make /tmp/scratch-XXXXXX)
# RIGHT:
#   tmp:make tmpfile /tmp/scratch-XXXXXX
#-------------------------------------------------------------------------------
tmp:make() {
  local var_name="${1:-}"
  [[ -n "$var_name" ]] || die "tmp:make requires a variable name"
  # shellcheck disable=SC2034,SC2178
  local -n out="$var_name"
  if [[ $# -lt 2 ]]; then
    die "tmp:make requires a template"
  fi
  local template="$2"
  shift 2
  local path
  path=$(mktemp "$template" "$@")
  tmp:track "$path"
  # shellcheck disable=SC2034
  out="$path"
  return 0
}

export -f tmp:make

#-------------------------------------------------------------------------------
# tmp:cleanup
#
# Best-effort deletion of all tracked temp files.
#-------------------------------------------------------------------------------
tmp:cleanup() {
  local path
  ((${#SCRATCH_TMPFILES[@]})) || return 0

  for path in "${SCRATCH_TMPFILES[@]}"; do
    [[ -e "$path" ]] || continue
    tmp:_log "tmp:cleanup attempting" path "$path"
    if rm -f -- "$path"; then
      tmp:_log "tmp:cleanup deleted" path "$path"
    else
      tmp:_log "tmp:cleanup failed" path "$path" err "$?"
    fi
  done

  SCRATCH_TMPFILES=()
  return 0
}

export -f tmp:cleanup

#-------------------------------------------------------------------------------
# tmp:install-traps
#
# Install EXIT/INT/TERM/HUP traps once per process. Chains with any existing
# trap handlers so we don't break other cleanup logic. Safe under set -euo
# pipefail - cleanup is wrapped in || true.
#-------------------------------------------------------------------------------
tmp:install-traps() {
  if [[ "$_TMPFILES_TRAPS_INSTALLED" == "1" ]]; then
    return 0
  fi

  local sig prior new_cmd
  for sig in EXIT INT TERM HUP; do
    # Capture existing trap: trap -p outputs `trap -- 'cmd' SIGNAL`
    prior=$(trap -p "$sig" | awk -F"'" '{print $2}')
    if [[ -n "$prior" ]]; then
      new_cmd="tmp:cleanup || true; $prior"
    else
      new_cmd="tmp:cleanup || true"
    fi
    # shellcheck disable=SC2064
    trap -- "$new_cmd" "$sig"
  done

  _TMPFILES_TRAPS_INSTALLED=1
  return 0
}

export -f tmp:install-traps
