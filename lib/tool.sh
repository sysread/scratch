#!/usr/bin/env bash

#-------------------------------------------------------------------------------
# Tool calling infrastructure
#
# A "tool" in scratch is a self-contained directory under tools/ with three
# required files:
#
#   tools/<name>/spec.json    - OpenAI function-calling JSON spec (the inner
#                               function object: name, description, parameters).
#                               Not executable.
#   tools/<name>/main         - the executable; any language. Receives args
#                               via SCRATCH_TOOL_ARGS_JSON env var. Exit 0 +
#                               stdout = success result; non-zero + stderr =
#                               failure result. Stdout and stderr are kept
#                               STRICTLY separate (unlike fnord which merges).
#   tools/<name>/is-available - bash script. Two purposes:
#                               1. Runtime gate: exit 0 if the tool is usable
#                                  in the current environment, non-zero (with
#                                  reason on stderr) if not.
#                               2. Dependency manifest: must source lib/base.sh
#                                  and call has-commands for any external
#                                  programs the tool needs. The doctor scanner
#                                  picks up these declarations textually and
#                                  attributes them to "tool:<name>".
#
# This library handles tool discovery, schema reading, availability gating,
# and synchronous + parallel invocation. The chat layer (lib/chat.sh) builds
# on this with chat:complete-with-tools, which loops on Venice tool_calls
# responses and feeds tool results back to the model.
#
# Environment contract for tool main scripts:
#
#   SCRATCH_TOOL_ARGS_JSON  the LLM's arguments as a JSON object (always set,
#                           may be "{}" for tools with no parameters)
#   SCRATCH_TOOL_DIR        absolute path to tools/<name>/ (so tools can find
#                           sibling files like fixtures or sub-scripts)
#   SCRATCH_HOME            absolute path to the scratch repo root (so bash
#                           tools can `source "$SCRATCH_HOME/lib/tui.sh"` etc.)
#   SCRATCH_PROJECT         current project name from project:detect, only
#                           set if a project is detected (use [[ -n ${VAR:-} ]])
#   SCRATCH_PROJECT_ROOT    current project root path, only set if detected
#-------------------------------------------------------------------------------

[[ "${_INCLUDED_TOOL:-}" == "1" ]] && return 0
_INCLUDED_TOOL=1

_TOOL_SCRIPTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source-path=SCRIPTDIR/lib
# shellcheck disable=SC1091
{
  source "$_TOOL_SCRIPTDIR/base.sh"
  source "$_TOOL_SCRIPTDIR/tempfiles.sh"
  source "$_TOOL_SCRIPTDIR/project.sh"
}

has-commands jq

#-------------------------------------------------------------------------------
# Globals (set by tool:available and tool:invoke)
#
# These are intentionally globals because the alternative - returning multi-
# line content from a function - is fragile in bash, especially when the
# content includes JSON or trailing newlines. Callers read these immediately
# after the function returns.
#-------------------------------------------------------------------------------
# shellcheck disable=SC2034
_TOOL_AVAILABILITY_ERR=""
# shellcheck disable=SC2034
_TOOL_INVOKE_STDOUT=""
# shellcheck disable=SC2034
_TOOL_INVOKE_STDERR=""

#-------------------------------------------------------------------------------
# tool:tools-dir
#
# Print the absolute path to the tools directory. Honors SCRATCH_TOOLS_DIR
# for tests; defaults to <repo>/tools.
#-------------------------------------------------------------------------------
tool:tools-dir() {
  if [[ -n "${SCRATCH_TOOLS_DIR:-}" ]]; then
    printf '%s\n' "$SCRATCH_TOOLS_DIR"
  else
    printf '%s\n' "$(cd "$_TOOL_SCRIPTDIR/../tools" 2> /dev/null && pwd -P || echo "$_TOOL_SCRIPTDIR/../tools")"
  fi
}

export -f tool:tools-dir

#-------------------------------------------------------------------------------
# tool:list
#
# Print the names of all tools (sorted, one per line). A tool is a directory
# under tool:tools-dir that contains at least a spec.json file. Directories
# missing spec.json are silently skipped, which keeps test fixture setup easy.
#-------------------------------------------------------------------------------
tool:list() {
  local tools_dir
  local d
  local name

  tools_dir="$(tool:tools-dir)"
  [[ -d "$tools_dir" ]] || return 0

  for d in "$tools_dir"/*/; do
    [[ -d "$d" ]] || continue
    [[ -f "${d}spec.json" ]] || continue
    name="$(basename "$d")"
    printf '%s\n' "$name"
  done | sort
}

export -f tool:list

#-------------------------------------------------------------------------------
# tool:exists NAME
#
# Return 0 if tools/NAME/ has all three required files (spec.json, main,
# is-available). Return 1 otherwise. Silent. Does NOT check executable bits;
# that's the contract test's job at structural-validation time.
#-------------------------------------------------------------------------------
tool:exists() {
  local name="$1"
  local tools_dir
  tools_dir="$(tool:tools-dir)"

  [[ -f "${tools_dir}/${name}/spec.json" ]] || return 1
  [[ -f "${tools_dir}/${name}/main" ]] || return 1
  [[ -f "${tools_dir}/${name}/is-available" ]] || return 1
  return 0
}

export -f tool:exists

#-------------------------------------------------------------------------------
# tool:dir NAME
#
# Print the absolute path to tools/NAME/. Dies if the directory does not
# exist or is missing the required files.
#-------------------------------------------------------------------------------
tool:dir() {
  local name="$1"
  if ! tool:exists "$name"; then
    die "tool: not found: $name (expected tools/$name/ with spec.json + main + is-available)"
    return 1
  fi
  printf '%s\n' "$(tool:tools-dir)/$name"
}

export -f tool:dir

#-------------------------------------------------------------------------------
# tool:spec NAME
#
# Print the raw spec.json contents for NAME. Does not validate the JSON
# shape - that's the contract test's job. Dies if the tool doesn't exist.
#-------------------------------------------------------------------------------
tool:spec() {
  local name="$1"
  if ! tool:exists "$name"; then
    die "tool: not found: $name"
    return 1
  fi
  cat "$(tool:tools-dir)/$name/spec.json"
}

export -f tool:spec

#-------------------------------------------------------------------------------
# tool:available NAME
#
# Run tools/NAME/is-available with the env contract set up. Return its
# exit code. Stderr from the script is captured into _TOOL_AVAILABILITY_ERR
# (a global) for the caller to inspect on failure.
#
# Honors SCRATCH_TOOL_SKIP_AVAILABILITY=1 by always returning 0 without
# running anything. Useful in tests that don't want the gate.
#-------------------------------------------------------------------------------
tool:available() {
  local name="$1"
  local script
  local err_file
  local rc

  if [[ "${SCRATCH_TOOL_SKIP_AVAILABILITY:-}" == "1" ]]; then
    _TOOL_AVAILABILITY_ERR=""
    return 0
  fi

  if ! tool:exists "$name"; then
    _TOOL_AVAILABILITY_ERR="tool: not found: $name"
    return 1
  fi

  script="$(tool:tools-dir)/$name/is-available"

  tmp:make err_file /tmp/scratch-tool-avail-err.XXXXXX
  tmp:install-traps

  # Subshell so SCRATCH_HOME export does not leak into the caller, and
  # so a die() inside the script (via has-commands) propagates as a real
  # exit code rather than aborting the calling test or function.
  # SC2030/SC2031: subshell-local modification is intentional here.
  # shellcheck disable=SC2030
  (
    export SCRATCH_HOME
    SCRATCH_HOME="$(cd "$_TOOL_SCRIPTDIR/.." && pwd -P)"
    "$script"
  ) 2> "$err_file"
  rc=$?

  _TOOL_AVAILABILITY_ERR="$(cat "$err_file")"
  rm -f "$err_file"
  return "$rc"
}

export -f tool:available

#-------------------------------------------------------------------------------
# tool:specs-json [NAMES...]
#
# Print a JSON array of tool specs in OpenAI's wire format:
#
#   [{"type": "function", "function": <spec.json contents>}, ...]
#
# With no NAMES, iterates every tool from tool:list. With one or more NAMES,
# iterates only those (deduplicated, in input order). Tools that fail their
# is-available check are filtered out and logged via tui:debug if available
# (unless SCRATCH_TOOL_SKIP_AVAILABILITY=1). Dies if a named tool does not
# exist (different from being unavailable - "doesn't exist" is a typo, while
# "unavailable" is a runtime condition we silently degrade around).
#-------------------------------------------------------------------------------
tool:specs-json() {
  local -a names
  local -a seen=()
  local name
  local result='[]'
  local spec
  local entry

  if (($# == 0)); then
    mapfile -t names < <(tool:list)
  else
    names=("$@")
  fi

  for name in "${names[@]}"; do
    [[ -z "$name" ]] && continue

    # Dedup
    if [[ " ${seen[*]:-} " == *" ${name} "* ]]; then
      continue
    fi
    seen+=("$name")

    # Existence is fatal (typo case)
    if ! tool:exists "$name"; then
      die "tool:specs-json: not found: $name"
      return 1
    fi

    # Availability is silently filtered
    if ! tool:available "$name"; then
      if type -t tui:debug &> /dev/null; then
        tui:debug "tool:specs-json: filtering unavailable tool" name "$name" reason "${_TOOL_AVAILABILITY_ERR}" || true
      fi
      continue
    fi

    spec="$(tool:spec "$name")"
    entry="$(jq -c -n --argjson s "$spec" '{type: "function", function: $s}')"
    result="$(jq -c --argjson e "$entry" '. + [$e]' <<< "$result")"
  done

  printf '%s\n' "$result"
}

export -f tool:specs-json

#-------------------------------------------------------------------------------
# tool:invoke NAME ARGS_JSON
#
# Synchronously execute tools/NAME/main with the env contract. Captures
# stdout and stderr into separate global scalars (_TOOL_INVOKE_STDOUT and
# _TOOL_INVOKE_STDERR) and returns the tool's exit code as the function
# return.
#
# If tool:available returns non-zero first, returns 127 with the
# availability error in _TOOL_INVOKE_STDERR (no-command-style exit code).
#
# Does NOT parse ARGS_JSON; passes it through opaquely. Tools are
# responsible for their own input validation.
#
# Tempfile-based stream capture (NOT process substitution) is used so the
# exit code stays clean and we don't risk SIGPIPE or deadlock on large
# stderr output.
#-------------------------------------------------------------------------------
tool:invoke() {
  local name="$1"
  local args_json="$2"
  local main_path
  local out_file
  local err_file
  local rc

  if ! tool:exists "$name"; then
    die "tool: not found: $name"
    return 1
  fi

  if ! tool:available "$name"; then
    _TOOL_INVOKE_STDOUT=""
    _TOOL_INVOKE_STDERR="$_TOOL_AVAILABILITY_ERR"
    return 127
  fi

  main_path="$(tool:tools-dir)/$name/main"

  tmp:make out_file /tmp/scratch-tool-out.XXXXXX
  tmp:make err_file /tmp/scratch-tool-err.XXXXXX
  tmp:install-traps

  # Run main in a subshell so the exported env vars don't pollute the
  # caller's environment. Tempfiles capture stdout and stderr separately
  # so the exit-code-determines-stream rule (success=stdout, failure=stderr)
  # has clean inputs.
  # SC2030/SC2031: all env modifications are intentionally subshell-local.
  # shellcheck disable=SC2030,SC2031
  (
    export SCRATCH_TOOL_ARGS_JSON="$args_json"
    export SCRATCH_TOOL_DIR
    SCRATCH_TOOL_DIR="$(tool:tools-dir)/$name"
    export SCRATCH_HOME
    SCRATCH_HOME="$(cd "$_TOOL_SCRIPTDIR/.." && pwd -P)"

    # Populate project env vars only when project:detect succeeds. Tools
    # can then use [[ -n ${SCRATCH_PROJECT:-} ]] to test for "in a project".
    #
    # We use plain assignment (not `local`) here because we're in a subshell
    # ( ... ), and subshell-scoped vars are discarded when the subshell
    # exits regardless of declaration. Avoiding `local` also dodges a
    # set -u edge case where `local foo` inside a subshell can trigger
    # an "unbound variable" error before the nameref-based assignment runs.
    _scratch_proj_name=""
    _scratch_proj_worktree=""
    if project:detect _scratch_proj_name _scratch_proj_worktree 2> /dev/null; then
      export SCRATCH_PROJECT="$_scratch_proj_name"
      export SCRATCH_PROJECT_ROOT
      # project:detect doesn't return the root directly; resolve via cwd
      # since we know we're inside the project.
      SCRATCH_PROJECT_ROOT="$(pwd -P)"
    fi

    "$main_path"
  ) > "$out_file" 2> "$err_file"
  rc=$?

  _TOOL_INVOKE_STDOUT="$(cat "$out_file")"
  _TOOL_INVOKE_STDERR="$(cat "$err_file")"
  rm -f "$out_file" "$err_file"

  return "$rc"
}

export -f tool:invoke
