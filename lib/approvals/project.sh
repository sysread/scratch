#!/usr/bin/env bash

#-------------------------------------------------------------------------------
# Project-scoped approval persistence
#
# Stores approvals at ~/.config/scratch/projects/<name>/approvals.json.
# These apply to all conversations within a project. Writes are atomic
# (tmp+mv) and serialized via flock.
#
# All functions require SCRATCH_PROJECT to be set. When unset, load
# returns an empty array and save is a no-op.
#-------------------------------------------------------------------------------

[[ "${_INCLUDED_APPROVALS_PROJECT:-}" == "1" ]] && return 0
_INCLUDED_APPROVALS_PROJECT=1

_APPROVALS_PROJECT_SCRIPTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source-path=SCRIPTDIR/..
# shellcheck disable=SC1091
{
  source "$_APPROVALS_PROJECT_SCRIPTDIR/../base.sh"
  source "$_APPROVALS_PROJECT_SCRIPTDIR/../project.sh"
}

has-commands jq flock

#-------------------------------------------------------------------------------
# _approvals:project-path PROJECT
#
# Print the path to the project's approvals file.
#-------------------------------------------------------------------------------
_approvals:project-path() {
  local project="$1"
  printf '%s/approvals.json' "$(project:config-dir "$project")"
}

export -f _approvals:project-path

#-------------------------------------------------------------------------------
# _approvals:project-load PROJECT
#
# Read the project's approvals file and print the approvals array.
# Returns an empty array if the file does not exist.
#-------------------------------------------------------------------------------
_approvals:project-load() {
  local project="$1"

  if [[ -z "$project" ]]; then
    printf '[]'
    return 0
  fi

  local path
  path="$(_approvals:project-path "$project")"

  if [[ -f "$path" ]]; then
    jq -c '.approvals // []' < "$path"
  else
    printf '[]'
  fi
}

export -f _approvals:project-load

#-------------------------------------------------------------------------------
# _approvals:project-save PROJECT APPROVALS_ARRAY_JSON
#
# Write the approvals array to the project's approvals file. Atomic
# write with flock serialization.
#-------------------------------------------------------------------------------
_approvals:project-save() {
  local project="$1"
  local approvals_json="$2"

  if [[ -z "$project" ]]; then
    return 0
  fi

  local path
  path="$(_approvals:project-path "$project")"

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

export -f _approvals:project-save
