#!/usr/bin/env bash

#-------------------------------------------------------------------------------
# Project configuration library
#
# A "project" is a named directory (not necessarily a git repo) that scratch
# knows about. Each project has a JSON config stored at:
#
#   ~/.config/scratch/projects/<name>/settings.json
#
# Config keys:
#   root     (string)          Absolute path to the project directory
#   is_git   (bool)            Whether the project root is a git repository
#   exclude  (array of string) Path globs to exclude from indexing
#
# Detection:
#   project:detect resolves the current working directory to a known project.
#   If cwd is inside a git worktree, it traces back to the main repo and
#   matches against that path instead, reporting the worktree status to the
#   caller via nameref.
#-------------------------------------------------------------------------------

[[ "${_INCLUDED_PROJECT:-}" == "1" ]] && return 0
_INCLUDED_PROJECT=1

_PROJECT_SCRIPTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source-path=SCRIPTDIR/lib
# shellcheck disable=SC1091
source "$_PROJECT_SCRIPTDIR/base.sh"

has-commands jq git

#-------------------------------------------------------------------------------
# Global config root for all scratch data
#-------------------------------------------------------------------------------
SCRATCH_CONFIG_DIR="${SCRATCH_CONFIG_DIR:-${HOME}/.config/scratch}"
SCRATCH_PROJECTS_DIR="${SCRATCH_PROJECTS_DIR:-${SCRATCH_CONFIG_DIR}/projects}"

export SCRATCH_CONFIG_DIR SCRATCH_PROJECTS_DIR

#-------------------------------------------------------------------------------
# project:config-dir NAME
#
# Print the config directory path for a named project.
#-------------------------------------------------------------------------------
project:config-dir() {
  printf '%s\n' "${SCRATCH_PROJECTS_DIR}/$1"
}

export -f project:config-dir

#-------------------------------------------------------------------------------
# project:config-path NAME
#
# Print the settings.json path for a named project.
#-------------------------------------------------------------------------------
project:config-path() {
  printf '%s\n' "${SCRATCH_PROJECTS_DIR}/$1/settings.json"
}

export -f project:config-path

#-------------------------------------------------------------------------------
# project:exists NAME
#
# Return 0 if a project with the given name has a settings.json, 1 otherwise.
#-------------------------------------------------------------------------------
project:exists() {
  local config
  config="$(project:config-path "$1")"
  [[ -f "$config" ]]
}

export -f project:exists

#-------------------------------------------------------------------------------
# project:list
#
# Print the names of all configured projects, one per line.
#-------------------------------------------------------------------------------
project:list() {
  local d name
  [[ -d "$SCRATCH_PROJECTS_DIR" ]] || return 0

  for d in "$SCRATCH_PROJECTS_DIR"/*/; do
    [[ -d "$d" ]] || continue
    name="$(basename "$d")"
    if [[ -f "${d}settings.json" ]]; then
      printf '%s\n' "$name"
    fi
  done

  return 0
}

export -f project:list

#-------------------------------------------------------------------------------
# project:load NAME OUT_ROOT OUT_IS_GIT OUT_EXCLUDE
#
# Read a project's settings.json and assign values to the caller's variables
# via namerefs.
#
# OUT_ROOT:    absolute path string
# OUT_IS_GIT:  "true" or "false"
# OUT_EXCLUDE: newline-separated glob patterns
#-------------------------------------------------------------------------------
project:load() {
  local name="$1"
  local -n _pl_root="$2"
  local -n _pl_is_git="$3"
  local -n _pl_exclude="$4"

  local config
  config="$(project:config-path "$name")"
  [[ -f "$config" ]] || die "project not found: $name"

  local json
  json="$(cat "$config")"

  # shellcheck disable=SC2034
  _pl_root="$(jq -r '.root // empty' <<< "$json")"

  # A project without a root is unusable — reject early so callers
  # (especially project:detect) don't match against an empty string.
  if [[ -z "$_pl_root" ]]; then
    die "project '$name': settings.json has no root path"
    return 1
  fi

  # shellcheck disable=SC2034
  _pl_is_git="$(jq -r '.is_git // "false"' <<< "$json")"
  # shellcheck disable=SC2034
  _pl_exclude="$(jq -r '.exclude[]? // empty' <<< "$json")"
}

export -f project:load

#-------------------------------------------------------------------------------
# project:save NAME ROOT IS_GIT [EXCLUDE...]
#
# Write a project's settings.json. Creates the config directory if needed.
# EXCLUDE args are individual glob patterns.
#-------------------------------------------------------------------------------
project:save() {
  local name="$1"
  local root="$2"
  local is_git="$3"
  shift 3

  local config_dir
  config_dir="$(project:config-dir "$name")"
  mkdir -p "$config_dir"

  local config
  config="$(project:config-path "$name")"

  # Build the exclude array as a JSON fragment
  local exclude_json="[]"
  if (($# > 0)); then
    exclude_json="$(printf '%s\n' "$@" | jq -R . | jq -s .)"
  fi

  jq -n \
    --arg root "$root" \
    --argjson is_git "$is_git" \
    --argjson exclude "$exclude_json" \
    '{root: $root, is_git: $is_git, exclude: $exclude}' \
    > "$config"
}

export -f project:save

#-------------------------------------------------------------------------------
# project:delete NAME
#
# Remove a project's config directory entirely.
#-------------------------------------------------------------------------------
project:delete() {
  local name="$1"
  local config_dir
  config_dir="$(project:config-dir "$name")"

  project:exists "$name" || die "project not found: $name"

  rm -rf "$config_dir"
}

export -f project:delete

#-------------------------------------------------------------------------------
# project:detect OUT_NAME OUT_IS_WORKTREE
#
# Identify which configured project the current directory belongs to.
# Sets OUT_NAME to the project name and OUT_IS_WORKTREE to "true"/"false".
#
# A project is always registered against a main repo root, never a
# worktree path. Worktrees are views of a project, not separate
# projects — they share the same config, index, and settings. When
# the user runs `scratch index` from a worktree, they expect it to
# operate on the main project. This function resolves worktrees to
# their parent repo so a single project registration covers all of
# its worktrees automatically.
#
# Detection strategy:
#   1. If cwd is in a git worktree, resolve to the main repo's root
#      (the parent of --git-common-dir, which points to the shared
#      .git directory).
#   2. Walk configured projects and match the resolved root (or cwd
#      for non-worktree cases) against each project's stored root.
#
# Returns 1 if no matching project is found.
#-------------------------------------------------------------------------------
project:detect() {
  local -n _pd_name="$1"
  local -n _pd_worktree="$2"

  local cwd
  cwd="$(pwd -P)"

  local resolved_root="$cwd"
  local is_worktree=false

  # If we're in a git repo, check for worktree status
  if git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
    local git_dir git_common_dir toplevel

    git_dir="$(git rev-parse --git-dir 2> /dev/null)"
    git_common_dir="$(git rev-parse --git-common-dir 2> /dev/null)"
    toplevel="$(git rev-parse --show-toplevel 2> /dev/null)"

    # Normalize to absolute paths for comparison
    git_dir="$(cd "$git_dir" && pwd -P)"
    git_common_dir="$(cd "$git_common_dir" && pwd -P)"

    # In a worktree, --git-dir points to .git/worktrees/<name> while
    # --git-common-dir points to the main repo's .git. If they differ,
    # we're in a worktree — resolve to the main repo root so we match
    # against the project registration (which is always the main root,
    # not any worktree path).
    if [[ "$git_dir" != "$git_common_dir" ]]; then
      is_worktree=true
      resolved_root="$(dirname "$git_common_dir")"
    else
      resolved_root="$toplevel"
    fi
  fi

  # Match against configured projects
  # shellcheck disable=SC2034 # proj_is_git and proj_exclude are populated by project:load via nameref
  local proj_name proj_root proj_is_git proj_exclude
  while IFS= read -r proj_name; do
    [[ -n "$proj_name" ]] || continue

    project:load "$proj_name" proj_root proj_is_git proj_exclude

    # Check if resolved_root is the project root or a subdirectory of it
    if [[ "$resolved_root" == "$proj_root" || "$cwd" == "$proj_root"/* || "$resolved_root" == "$proj_root"/* ]]; then
      # shellcheck disable=SC2034
      _pd_name="$proj_name"
      # shellcheck disable=SC2034
      _pd_worktree="$is_worktree"
      return 0
    fi
  done < <(project:list)

  return 1
}

export -f project:detect

#-------------------------------------------------------------------------------
# project:resolve-name OUT_NAME [ARG]
#
# Resolve a project name from an explicit argument or, if empty, from the
# current working directory via project:detect. Dies if neither yields a
# project name.
#
# Used by subcommands that accept an optional project name argument and fall
# back to cwd detection.
#-------------------------------------------------------------------------------
project:resolve-name() {
  local -n _prn_out="$1"
  local arg="${2:-}"

  if [[ -n "$arg" ]]; then
    # shellcheck disable=SC2034
    _prn_out="$arg"
    return 0
  fi

  # shellcheck disable=SC2034 # detected_wt is populated by project:detect via nameref but unused here
  local detected_name detected_wt
  if project:detect detected_name detected_wt; then
    # shellcheck disable=SC2034
    _prn_out="$detected_name"
    return 0
  fi

  die "no project name given and none detected from cwd"
}

export -f project:resolve-name

#-------------------------------------------------------------------------------
# project:is-git PATH
#
# Print "true" if PATH is inside a git work tree, "false" otherwise.
# Always returns 0 so the function composes cleanly with command
# substitution under set -e.
#
# Used by create/edit to auto-populate the is_git field - it's derivable
# state, never asked from the user.
#
# Example:
#   local flag
#   flag="$(project:is-git "$some_path")"
#-------------------------------------------------------------------------------
project:is-git() {
  local path="$1"
  if git -C "$path" rev-parse --is-inside-work-tree > /dev/null 2>&1; then
    printf 'true\n'
  else
    printf 'false\n'
  fi
  return 0
}

export -f project:is-git
