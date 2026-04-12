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
{
  source "$_TEMPFILES_SCRIPTDIR/base.sh"
  source "$_TEMPFILES_SCRIPTDIR/signals.sh"
}

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
  if [[ -z "$path" ]]; then
    die "tmp:track requires a path"
    return 1
  fi

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
# TEMPLATE must be an absolute path (e.g. /tmp/scratch-foo-XXXXXX). A
# relative template makes mktemp create the file in the current working
# directory, which can pollute a tracked source tree if the caller is
# running from inside one. The guard rejects relative templates outright
# rather than silently doing the wrong thing.
#
# WARNING: Command substitution $(...) runs in a subshell. The temp file
# registry lives in the current process's memory. Capturing the result with
# $(...) would only register the file in the subshell, so the parent loses
# track and cleanup breaks. This is why tmp:make uses a nameref API.
#
# WRONG:
#   tmpfile=$(tmp:make /tmp/scratch-XXXXXX)
#   tmp:make tmpfile scratch-XXXXXX           # relative - dies
# RIGHT:
#   tmp:make tmpfile /tmp/scratch-XXXXXX
#-------------------------------------------------------------------------------
tmp:make() {
  local var_name="${1:-}"
  if [[ -z "$var_name" ]]; then
    die "tmp:make requires a variable name"
    return 1
  fi
  if [[ $# -lt 2 ]]; then
    die "tmp:make requires a template"
    return 1
  fi
  local template="$2"
  if [[ "$template" != /* ]]; then
    die "tmp:make: template must be an absolute path: $template"
    return 1
  fi
  # shellcheck disable=SC2034,SC2178
  local -n out="$var_name"
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
# Best-effort deletion of all tracked temp files AND directories.
# Uses rm -rf so directories created via `mktemp -d` and tracked via
# tmp:track get cleaned up too. Without -r, the rm fails on directory
# entries (which both lib/tool.sh and lib/agent.sh's intuition example
# create). The -f stays so missing entries are silent.
#-------------------------------------------------------------------------------
tmp:cleanup() {
  local path
  ((${#SCRATCH_TMPFILES[@]})) || return 0

  for path in "${SCRATCH_TMPFILES[@]}"; do
    [[ -e "$path" ]] || continue
    tmp:_log "tmp:cleanup attempting" path "$path"
    if rm -rf -- "$path"; then
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
# Register temp file cleanup via the signal handler registry. Cleanup
# runs on EXIT only - because _signal:dispatch calls exit after handling
# INT/TERM/HUP, the EXIT trap fires on all termination paths.
#
# Skipped in subshells (where $BASHPID != $$). Subshells inherit the
# parent's traps, and the parent's cleanup fires when the parent exits.
# See lib/signals.sh header for the full subshell rationale.
#-------------------------------------------------------------------------------
tmp:install-traps() {
  if [[ "$_TMPFILES_TRAPS_INSTALLED" == "1" ]]; then
    return 0
  fi

  if [[ "$BASHPID" != "$$" ]]; then
    return 0
  fi

  signal:register EXIT tempfiles "tmp:cleanup || true"

  _TMPFILES_TRAPS_INSTALLED=1
  return 0
}

export -f tmp:install-traps
