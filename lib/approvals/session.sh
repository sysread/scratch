#!/usr/bin/env bash

#-------------------------------------------------------------------------------
# Session-scoped approval persistence
#
# Stores approvals in the conversation's metadata.json under an
# "approvals" key. These persist between invocations of the same
# conversation but do not carry over to new conversations.
#
# Requires SCRATCH_PROJECT and SCRATCH_CONVERSATION_SLUG to be set.
# When either is unset, load returns an empty array and save is a no-op.
# This allows the approval check to degrade gracefully for tool
# invocations outside of a chat session.
#-------------------------------------------------------------------------------

[[ "${_INCLUDED_APPROVALS_SESSION:-}" == "1" ]] && return 0
_INCLUDED_APPROVALS_SESSION=1

_APPROVALS_SESSION_SCRIPTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source-path=SCRIPTDIR/..
# shellcheck disable=SC1091
{
  source "$_APPROVALS_SESSION_SCRIPTDIR/../base.sh"
  source "$_APPROVALS_SESSION_SCRIPTDIR/../conversations.sh"
}

has-commands jq
uses-env-vars SCRATCH_CONVERSATION_SLUG
describe-env-var SCRATCH_CONVERSATION_SLUG "current conversation id (set by chat at runtime)"

#-------------------------------------------------------------------------------
# _approvals:session-load
#
# Read session approvals from the current conversation's metadata.json.
# Prints the approvals array to stdout, or [] if unavailable.
#
# Uses SCRATCH_PROJECT and SCRATCH_CONVERSATION_SLUG from the env.
#-------------------------------------------------------------------------------
_approvals:session-load() {
  local project="${SCRATCH_PROJECT:-}"
  local slug="${SCRATCH_CONVERSATION_SLUG:-}"

  if [[ -z "$project" || -z "$slug" ]]; then
    printf '[]'
    return 0
  fi

  if ! conversation:exists "$project" "$slug"; then
    printf '[]'
    return 0
  fi

  local meta
  meta="$(conversation:load-metadata "$project" "$slug")"
  jq -c '.approvals // []' <<< "$meta"
}

export -f _approvals:session-load

#-------------------------------------------------------------------------------
# _approvals:session-save APPROVALS_ARRAY_JSON
#
# Write session approvals to the current conversation's metadata.json.
# Uses conversation:update-metadata for atomic writes.
#
# No-op when SCRATCH_PROJECT or SCRATCH_CONVERSATION_SLUG is unset.
#-------------------------------------------------------------------------------
_approvals:session-save() {
  local approvals_json="$1"
  local project="${SCRATCH_PROJECT:-}"
  local slug="${SCRATCH_CONVERSATION_SLUG:-}"

  if [[ -z "$project" || -z "$slug" ]]; then
    return 0
  fi

  # Embed the JSON array directly in the jq expression since
  # conversation:update-metadata takes a plain jq expression string.
  conversation:update-metadata "$project" "$slug" \
    ".approvals = ${approvals_json}"
}

export -f _approvals:session-save
