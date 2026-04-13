#!/usr/bin/env bash

#-------------------------------------------------------------------------------
# Global-scoped approval persistence
#
# Stores approvals at ~/.config/scratch/approvals.json. These apply to
# all projects and conversations. Writes are atomic (tmp+mv) and
# serialized via flock to handle concurrent tool invocations.
#-------------------------------------------------------------------------------

[[ "${_INCLUDED_APPROVALS_GLOBAL:-}" == "1" ]] && return 0
_INCLUDED_APPROVALS_GLOBAL=1

_APPROVALS_GLOBAL_SCRIPTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source-path=SCRIPTDIR/..
# shellcheck disable=SC1091
source "$_APPROVALS_GLOBAL_SCRIPTDIR/../base.sh"

has-commands jq flock

#-------------------------------------------------------------------------------
# _approvals:global-path
#
# Print the path to the global approvals file.
#-------------------------------------------------------------------------------
_approvals:global-path() {
  printf '%s/approvals.json' "${SCRATCH_CONFIG_DIR:-${HOME}/.config/scratch}"
}

export -f _approvals:global-path

#-------------------------------------------------------------------------------
# _approvals:global-load
#
# Read the global approvals file and print the approvals array to stdout.
# Returns an empty array if the file does not exist or has no approvals key.
#-------------------------------------------------------------------------------
_approvals:global-load() {
  local path
  path="$(_approvals:global-path)"

  if [[ -f "$path" ]]; then
    jq -c '.approvals // []' < "$path"
  else
    printf '[]'
  fi
}

export -f _approvals:global-load

#-------------------------------------------------------------------------------
# _approvals:global-save APPROVALS_ARRAY_JSON
#
# Write the approvals array to the global approvals file. Atomic write
# (tmp+mv) with flock serialization.
#-------------------------------------------------------------------------------
_approvals:global-save() {
  local approvals_json="$1"
  local path
  path="$(_approvals:global-path)"

  local dir
  dir="$(dirname "$path")"
  mkdir -p "$dir"

  local lock_path="${path}.lock"

  {
    flock 200

    jq -c -n --argjson approvals "$approvals_json" \
      '{approvals: $approvals}' > "${path}.tmp"
    mv "${path}.tmp" "$path"

  } 200> "$lock_path"
}

export -f _approvals:global-save
