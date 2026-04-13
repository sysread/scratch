#!/usr/bin/env bash

#-------------------------------------------------------------------------------
# Approval system - facade and matching engine
#
# Controls what LLMs are allowed to do by checking tool invocations
# against stored approval records. Approvals are scoped to three levels
# (searched in order, first match wins):
#
#   session   conversation metadata (SCRATCH_PROJECT + SCRATCH_CONVERSATION_SLUG)
#   project   project config dir (SCRATCH_PROJECT)
#   global    ~/.config/scratch/approvals.json
#
# Each approval record specifies a class (shell, file_read, etc.), a
# pattern (exact command, wildcard, or PCRE regex), and an optional mode
# constraint (null = always, "mutable" = only in mutable mode).
#
# Pattern types:
#   exact    "ls -l -a"          string comparison
#   wildcard "ls:*"              command-name prefix match
#   regex    "/^find\b(?!.*-exec)/"  PCRE via perl
#
# This file is the public API. Persistence backends live in
# lib/approvals/{session,project,global}.sh.
#-------------------------------------------------------------------------------

[[ "${_INCLUDED_APPROVALS:-}" == "1" ]] && return 0
_INCLUDED_APPROVALS=1

_APPROVALS_SCRIPTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC1091
{
  source "$_APPROVALS_SCRIPTDIR/base.sh"
  source "$_APPROVALS_SCRIPTDIR/approvals/session.sh"
  source "$_APPROVALS_SCRIPTDIR/approvals/project.sh"
  source "$_APPROVALS_SCRIPTDIR/approvals/global.sh"
}

has-commands jq perl

#-------------------------------------------------------------------------------
# _approvals:command-string EXPRESSION_JSON
#
# (Private) Reconstruct a flat command string from a single expression
# object. The expression is {"command":"ls","args":["-l","-a"]}; the
# output is "ls -l -a".
#-------------------------------------------------------------------------------
_approvals:command-string() {
  local expr_json="$1"
  jq -r '[.command] + (.args // []) | join(" ")' <<< "$expr_json"
}

export -f _approvals:command-string

#-------------------------------------------------------------------------------
# _approvals:mode-applies RECORD_JSON
#
# (Private) Return 0 if the record's mode condition is satisfied.
# A null mode always applies. A "mutable" mode applies only when
# SCRATCH_MUTABLE=1 is set.
#-------------------------------------------------------------------------------
_approvals:mode-applies() {
  local record_json="$1"
  local mode
  mode="$(jq -r '.mode // "any"' <<< "$record_json")"

  case "$mode" in
    any | null) return 0 ;;
    mutable)
      [[ "${SCRATCH_MUTABLE:-}" == "1" ]]
      return $?
      ;;
    *)
      # Unknown mode - reject for safety
      return 1
      ;;
  esac
}

export -f _approvals:mode-applies

#-------------------------------------------------------------------------------
# _approvals:match-pattern COMMAND_STRING PATTERN PATTERN_TYPE
#
# (Private) Return 0 if the command string matches the pattern.
#
# Pattern types:
#   exact    - literal string comparison
#   wildcard - "command:*" matches any args for that command name
#   regex    - "/pcre/" matched via perl
#-------------------------------------------------------------------------------
_approvals:match-pattern() {
  local command_string="$1"
  local pattern="$2"
  local pattern_type="$3"

  case "$pattern_type" in
    exact)
      [[ "$command_string" == "$pattern" ]]
      return $?
      ;;
    wildcard)
      # Pattern is "command:*". Extract the command name prefix.
      local pattern_cmd="${pattern%%:*}"
      local actual_cmd="${command_string%% *}"
      [[ "$actual_cmd" == "$pattern_cmd" ]]
      return $?
      ;;
    regex)
      # Pattern is "/pcre/". Strip the delimiters and match via perl.
      local regex="${pattern#/}"
      regex="${regex%/}"
      perl -e "exit(qq{$command_string} =~ /$regex/ ? 0 : 1)"
      return $?
      ;;
    *)
      # Unknown pattern type - no match
      return 1
      ;;
  esac
}

export -f _approvals:match-pattern

#-------------------------------------------------------------------------------
# _approvals:search-array APPROVALS_JSON CLASS COMMAND_STRING
#
# (Private) Search an approvals array for a matching record. Returns 0
# on first match, 1 if no match found. Checks class, pattern, and mode.
#-------------------------------------------------------------------------------
_approvals:search-array() {
  local approvals_json="$1"
  local class="$2"
  local command_string="$3"

  local count
  count="$(jq 'length' <<< "$approvals_json")"

  local i
  for ((i = 0; i < count; i++)); do
    local record
    record="$(jq -c ".[$i]" <<< "$approvals_json")"

    local record_class
    record_class="$(jq -r '.class' <<< "$record")"
    [[ "$record_class" == "$class" ]] || continue

    if ! _approvals:mode-applies "$record"; then
      continue
    fi

    local pattern
    local pattern_type
    pattern="$(jq -r '.pattern' <<< "$record")"
    pattern_type="$(jq -r '.pattern_type' <<< "$record")"

    if _approvals:match-pattern "$command_string" "$pattern" "$pattern_type"; then
      return 0
    fi
  done

  return 1
}

export -f _approvals:search-array

#-------------------------------------------------------------------------------
# approvals:is-approved CLASS COMMAND_STRING
#
# Check if a command is approved across all scopes (session, project,
# global). Returns 0 on first match, 1 if no scope approves it.
#
# Scope search order: session > project > global. A match in any scope
# is sufficient.
#
# Honors SCRATCH_APPROVALS_SKIP=1 for test bypass.
#-------------------------------------------------------------------------------
approvals:is-approved() {
  local class="$1"
  local command_string="$2"

  if [[ "${SCRATCH_APPROVALS_SKIP:-}" == "1" ]]; then
    return 0
  fi

  # Session scope
  local session_approvals
  session_approvals="$(_approvals:session-load)"
  if [[ "$session_approvals" != "[]" ]]; then
    if _approvals:search-array "$session_approvals" "$class" "$command_string"; then
      return 0
    fi
  fi

  # Project scope
  local project="${SCRATCH_PROJECT:-}"
  if [[ -n "$project" ]]; then
    local project_approvals
    project_approvals="$(_approvals:project-load "$project")"
    if [[ "$project_approvals" != "[]" ]]; then
      if _approvals:search-array "$project_approvals" "$class" "$command_string"; then
        return 0
      fi
    fi
  fi

  # Global scope
  local global_approvals
  global_approvals="$(_approvals:global-load)"
  if [[ "$global_approvals" != "[]" ]]; then
    if _approvals:search-array "$global_approvals" "$class" "$command_string"; then
      return 0
    fi
  fi

  return 1
}

export -f approvals:is-approved

#-------------------------------------------------------------------------------
# approvals:check-shell PIPELINE_JSON
#
# Check if all expressions in a shell pipeline are approved. Returns 0
# only if every segment passes approvals:is-approved.
#
# PIPELINE_JSON is the structured command format:
#   {"operator":"|","expressions":[{"command":"ls","args":["-l"]},{"command":"wc","args":["-l"]}]}
#
# Returns 1 if any segment is unapproved.
#-------------------------------------------------------------------------------
approvals:check-shell() {
  local pipeline_json="$1"

  local count
  count="$(jq '.expressions | length' <<< "$pipeline_json")"

  local i
  for ((i = 0; i < count; i++)); do
    local expr
    expr="$(jq -c ".expressions[$i]" <<< "$pipeline_json")"

    local cmd_string
    cmd_string="$(_approvals:command-string "$expr")"

    if ! approvals:is-approved shell "$cmd_string"; then
      return 1
    fi
  done

  return 0
}

export -f approvals:check-shell

#-------------------------------------------------------------------------------
# approvals:add SCOPE CLASS PATTERN PATTERN_TYPE [MODE]
#
# Add an approval record to the given scope's storage.
#
# SCOPE: session | project | global
# CLASS: shell | file_read | ...
# PATTERN: the pattern string
# PATTERN_TYPE: exact | wildcard | regex
# MODE: null (any mode) or "mutable"
#-------------------------------------------------------------------------------
approvals:add() {
  local scope="$1"
  local class="$2"
  local pattern="$3"
  local pattern_type="$4"
  local mode="${5:-null}"

  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  local record
  if [[ "$mode" == "null" ]]; then
    record="$(jq -c -n \
      --arg class "$class" \
      --arg pattern "$pattern" \
      --arg pt "$pattern_type" \
      --arg created "$now" \
      '{class: $class, pattern: $pattern, pattern_type: $pt, mode: null, created: $created}')"
  else
    record="$(jq -c -n \
      --arg class "$class" \
      --arg pattern "$pattern" \
      --arg pt "$pattern_type" \
      --arg mode "$mode" \
      --arg created "$now" \
      '{class: $class, pattern: $pattern, pattern_type: $pt, mode: $mode, created: $created}')"
  fi

  local existing
  local updated

  case "$scope" in
    session)
      existing="$(_approvals:session-load)"
      updated="$(jq -c --argjson r "$record" '. + [$r]' <<< "$existing")"
      _approvals:session-save "$updated"
      ;;
    project)
      local project="${SCRATCH_PROJECT:-}"
      if [[ -z "$project" ]]; then
        die "approvals:add: cannot add project-scoped approval without SCRATCH_PROJECT"
        return 1
      fi
      existing="$(_approvals:project-load "$project")"
      updated="$(jq -c --argjson r "$record" '. + [$r]' <<< "$existing")"
      _approvals:project-save "$project" "$updated"
      ;;
    global)
      existing="$(_approvals:global-load)"
      updated="$(jq -c --argjson r "$record" '. + [$r]' <<< "$existing")"
      _approvals:global-save "$updated"
      ;;
    *)
      die "approvals:add: unknown scope: $scope"
      return 1
      ;;
  esac
}

export -f approvals:add

#-------------------------------------------------------------------------------
# approvals:remove SCOPE CLASS PATTERN
#
# Remove all approval records matching the given class and pattern from
# the given scope.
#-------------------------------------------------------------------------------
approvals:remove() {
  local scope="$1"
  local class="$2"
  local pattern="$3"

  local existing
  local updated

  case "$scope" in
    session)
      existing="$(_approvals:session-load)"
      updated="$(jq -c --arg c "$class" --arg p "$pattern" \
        '[.[] | select(.class != $c or .pattern != $p)]' <<< "$existing")"
      _approvals:session-save "$updated"
      ;;
    project)
      local project="${SCRATCH_PROJECT:-}"
      if [[ -z "$project" ]]; then
        die "approvals:remove: no project set"
        return 1
      fi
      existing="$(_approvals:project-load "$project")"
      updated="$(jq -c --arg c "$class" --arg p "$pattern" \
        '[.[] | select(.class != $c or .pattern != $p)]' <<< "$existing")"
      _approvals:project-save "$project" "$updated"
      ;;
    global)
      existing="$(_approvals:global-load)"
      updated="$(jq -c --arg c "$class" --arg p "$pattern" \
        '[.[] | select(.class != $c or .pattern != $p)]' <<< "$existing")"
      _approvals:global-save "$updated"
      ;;
    *)
      die "approvals:remove: unknown scope: $scope"
      return 1
      ;;
  esac
}

export -f approvals:remove

#-------------------------------------------------------------------------------
# approvals:list SCOPE [CLASS]
#
# Print stored approvals as JSONL (one record per line). Optionally
# filtered by class.
#-------------------------------------------------------------------------------
approvals:list() {
  local scope="$1"
  local class="${2:-}"

  local approvals

  case "$scope" in
    session)
      approvals="$(_approvals:session-load)"
      ;;
    project)
      local project="${SCRATCH_PROJECT:-}"
      if [[ -z "$project" ]]; then
        return 0
      fi
      approvals="$(_approvals:project-load "$project")"
      ;;
    global)
      approvals="$(_approvals:global-load)"
      ;;
    *)
      die "approvals:list: unknown scope: $scope"
      return 1
      ;;
  esac

  if [[ -n "$class" ]]; then
    jq -c --arg c "$class" '.[] | select(.class == $c)' <<< "$approvals"
  else
    jq -c '.[]' <<< "$approvals"
  fi
}

export -f approvals:list
