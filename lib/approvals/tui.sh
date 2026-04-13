#!/usr/bin/env bash

#-------------------------------------------------------------------------------
# Approval TUI utilities
#
# Shared display functions for approval dialogs. The class-specific
# workflows live in lib/approvals/tui/{shell,read}.sh; this file
# provides the building blocks they share.
#-------------------------------------------------------------------------------

[[ "${_INCLUDED_APPROVALS_TUI:-}" == "1" ]] && return 0
_INCLUDED_APPROVALS_TUI=1

_APPROVALS_TUI_SCRIPTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source-path=SCRIPTDIR/..
# shellcheck disable=SC1091
{
  source "$_APPROVALS_TUI_SCRIPTDIR/../base.sh"
  source "$_APPROVALS_TUI_SCRIPTDIR/../tui.sh"
  source "$_APPROVALS_TUI_SCRIPTDIR/../approvals.sh"
}

has-commands gum jq

#-------------------------------------------------------------------------------
# approvals:tui-display-pipeline PIPELINE_JSON
#
# Render a color-coded representation of a shell pipeline to stderr.
# Each expression is shown on its own line with the operator prefix.
# Approved segments are green, unapproved segments are red.
#
# Example output for "ls -l | wc -l" where ls is approved but wc is not:
#
#     ls -l
#   | wc -l      (red)
#
#-------------------------------------------------------------------------------
approvals:tui-display-pipeline() {
  local pipeline_json="$1"

  local operator
  operator="$(jq -r '.operator // ""' <<< "$pipeline_json")"

  local count
  count="$(jq '.expressions | length' <<< "$pipeline_json")"

  local i
  for ((i = 0; i < count; i++)); do
    local expr
    expr="$(jq -c ".expressions[$i]" <<< "$pipeline_json")"

    local cmd_string
    cmd_string="$(_approvals:command-string "$expr")"

    local prefix="  "
    if ((i > 0)) && [[ -n "$operator" ]]; then
      prefix="${operator} "
    fi

    local color
    if approvals:is-approved shell "$cmd_string"; then
      color=10 # bright green
    else
      color=9 # bright red
    fi

    gum style --foreground "$color" "${prefix}${cmd_string}" >&2
  done
}

export -f approvals:tui-display-pipeline

#-------------------------------------------------------------------------------
# approvals:tui-scope-choice VAR
#
# Prompt the user to select an approval scope. Result assigned via
# nameref: "session", "project", or "global".
#-------------------------------------------------------------------------------
approvals:tui-scope-choice() {
  local -n _atsc_out="$1"

  local choice
  if choice="$(gum choose \
    --header "Remember for which scope?" \
    "This session" \
    "This project" \
    "Globally")"; then
    case "$choice" in
      "This session") _atsc_out="session" ;;
      "This project") _atsc_out="project" ;;
      "Globally") _atsc_out="global" ;;
      *) _atsc_out="session" ;;
    esac
  else
    # Cancelled - default to session (least persistent)
    _atsc_out="session"
  fi
}

export -f approvals:tui-scope-choice
