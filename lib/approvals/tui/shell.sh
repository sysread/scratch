#!/usr/bin/env bash

#-------------------------------------------------------------------------------
# Shell command approval TUI
#
# Interactive workflow for approving shell command pipelines. Shows the
# pipeline with color-coded segments, presents approval options, and
# persists "remember" choices to the selected scope.
#
# The workflow:
#   1. Display the pipeline (green = pre-approved, red = needs approval)
#   2. Main menu: approve all / remember / no / no with comment
#   3. For "remember": per-segment pattern + scope selection
#-------------------------------------------------------------------------------

[[ "${_INCLUDED_APPROVALS_TUI_SHELL:-}" == "1" ]] && return 0
_INCLUDED_APPROVALS_TUI_SHELL=1

_APPROVALS_TUI_SHELL_SCRIPTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source-path=SCRIPTDIR/../..
# shellcheck disable=SC1091
{
  source "$_APPROVALS_TUI_SHELL_SCRIPTDIR/../../base.sh"
  source "$_APPROVALS_TUI_SHELL_SCRIPTDIR/../../tui.sh"
  source "$_APPROVALS_TUI_SHELL_SCRIPTDIR/../../approvals.sh"
  source "$_APPROVALS_TUI_SHELL_SCRIPTDIR/../tui.sh"
}

has-commands gum jq

#-------------------------------------------------------------------------------
# _approvals:tui-shell-pattern-choice VAR COMMAND_STRING
#
# (Private) Prompt the user to choose how to remember a command approval.
# Offers exact match, wildcard, and regex. For wildcard and regex, the
# pattern is pre-filled with a sensible default and editable via gum input.
#
# VAR receives the pattern string. PATTERN_TYPE_VAR receives the type.
#-------------------------------------------------------------------------------
_approvals:tui-shell-pattern-choice() {
  local -n _atspc_pattern="$1"
  local -n _atspc_type="$2"
  local cmd_string="$3"

  local cmd_name="${cmd_string%% *}"
  local default_wildcard="${cmd_name}:*"
  local default_regex="/^${cmd_name}\b/"

  local choice
  if choice="$(gum choose \
    --header "How should this be remembered?" \
    "Exact: ${cmd_string}" \
    "Wildcard: ${default_wildcard}" \
    "Custom regex")"; then
    case "$choice" in
      Exact:*)
        _atspc_pattern="$cmd_string"
        _atspc_type="exact"
        ;;
      Wildcard:*)
        local edited
        if edited="$(gum input \
          --header "Edit wildcard pattern" \
          --value "$default_wildcard")"; then
          _atspc_pattern="$edited"
        else
          _atspc_pattern="$default_wildcard"
        fi
        _atspc_type="wildcard"
        ;;
      "Custom regex")
        local edited
        if edited="$(gum input \
          --header "Enter PCRE regex (with / delimiters)" \
          --value "$default_regex")"; then
          _atspc_pattern="$edited"
        else
          _atspc_pattern="$default_regex"
        fi
        _atspc_type="regex"
        ;;
      *)
        _atspc_pattern="$cmd_string"
        _atspc_type="exact"
        ;;
    esac
  else
    # Cancelled - default to exact
    _atspc_pattern="$cmd_string"
    _atspc_type="exact"
  fi
}

export -f _approvals:tui-shell-pattern-choice

#-------------------------------------------------------------------------------
# approvals:tui-shell PIPELINE_JSON RESULT_VAR [WHY_VAR]
#
# Full shell command approval TUI workflow. Shows the pipeline, prompts
# for a decision, and persists "remember" approvals.
#
# RESULT_VAR is set to "approved" or "denied".
# WHY_VAR (optional) is set when the user denies with a comment.
#
# Returns 0 when approved (including one-time), 1 when denied.
#-------------------------------------------------------------------------------
approvals:tui-shell() {
  local pipeline_json="$1"
  local -n _ats_result="$2"
  local why_var="${3:-}"

  printf '\n' >&2
  gum style --bold --foreground 15 "Shell command approval required" >&2
  printf '\n' >&2

  # Display the pipeline with approval status coloring
  approvals:tui-display-pipeline "$pipeline_json"
  printf '\n' >&2

  # Main choice
  local choice
  if ! choice="$(gum choose \
    --header "Allow this command?" \
    "Approve (one-time)" \
    "Approve and remember" \
    "Deny" \
    "Deny with comment")"; then
    # Cancelled via ESC/Ctrl-C
    _ats_result="denied"
    return 1
  fi

  case "$choice" in
    "Approve (one-time)")
      _ats_result="approved"
      return 0
      ;;
    "Deny")
      _ats_result="denied"
      return 1
      ;;
    "Deny with comment")
      _ats_result="denied"
      if [[ -n "$why_var" ]]; then
        local -n _ats_why="$why_var"
        local comment
        if tui:write comment "Why is this denied?" "Explain to the LLM..."; then
          # shellcheck disable=SC2034
          _ats_why="$comment"
        fi
      fi
      return 1
      ;;
    "Approve and remember")
      # Fall through to per-segment approval below
      ;;
  esac

  # Per-segment approval: for each unapproved segment, choose pattern + scope
  local count
  count="$(jq '.expressions | length' <<< "$pipeline_json")"

  local i
  for ((i = 0; i < count; i++)); do
    local expr
    expr="$(jq -c ".expressions[$i]" <<< "$pipeline_json")"

    local cmd_string
    cmd_string="$(_approvals:command-string "$expr")"

    # Skip segments that are already approved
    if approvals:is-approved shell "$cmd_string"; then
      continue
    fi

    printf '\n' >&2
    gum style --foreground 9 "  ${cmd_string}" >&2
    printf '\n' >&2

    # Choose pattern type
    local pattern=""
    local pattern_type=""
    _approvals:tui-shell-pattern-choice pattern pattern_type "$cmd_string"

    # Choose scope
    local scope=""
    approvals:tui-scope-choice scope

    # Persist
    approvals:add "$scope" shell "$pattern" "$pattern_type"
  done

  _ats_result="approved"
  return 0
}

export -f approvals:tui-shell
