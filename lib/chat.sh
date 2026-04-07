#!/usr/bin/env bash

#-------------------------------------------------------------------------------
# Venice chat completions
#
# Thin wrapper around POST /chat/completions. Callers build their own
# messages array (as JSON) and optionally pass an extras object that gets
# merged into the request body for temperature, venice_parameters, tools,
# and so on.
#
# This library deliberately does NOT provide a message builder API. The
# simplest useful shape is: "give me a model, an array of messages, and
# optional extras - hand me back the raw response JSON." Callers that want
# fancy builders can build them locally; library complexity should be
# driven by real use cases, not anticipated ones.
#-------------------------------------------------------------------------------

[[ "${_INCLUDED_CHAT:-}" == "1" ]] && return 0
_INCLUDED_CHAT=1

_CHAT_SCRIPTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source-path=SCRIPTDIR/lib
# shellcheck disable=SC1091
{
  source "$_CHAT_SCRIPTDIR/base.sh"
  source "$_CHAT_SCRIPTDIR/venice.sh"
}

has-commands jq

#-------------------------------------------------------------------------------
# chat:completion MODEL MESSAGES_JSON [EXTRA_JSON]
#
# Make a chat completion request and print the full response body to
# stdout. Dies with a helpful message on API errors (via venice:curl).
#
# MODEL           model id string (e.g., "llama-3-large")
# MESSAGES_JSON   JSON array of message objects, already formed
# EXTRA_JSON      optional JSON object merged shallowly into the request.
#                 Use this for temperature, venice_parameters, tools,
#                 response_format, etc. Empty string or omitted means no
#                 extras.
#
# The extras merge happens via jq's "+" operator, which is shallow.
# Keys in EXTRA_JSON win over the base {model, messages} object, so
# callers can override if they really want to.
#
# Example:
#   messages='[{"role":"user","content":"hello"}]'
#   chat:completion llama-3-large "$messages" '{"temperature":0.7}'
#
# Example with venice_parameters:
#   chat:completion llama-3-large "$messages" '{
#     "temperature": 0.7,
#     "venice_parameters": {"enable_web_search": "auto"}
#   }'
#-------------------------------------------------------------------------------
chat:completion() {
  local model="$1"
  local messages="$2"
  local extra="${3:-}"
  local body

  # Default to an empty object when no extras are supplied. This keeps the
  # jq expression below uniform instead of branching on the extras path.
  [[ -n "$extra" ]] || extra='{}'

  body="$(
    jq -c -n \
      --arg model "$model" \
      --argjson messages "$messages" \
      --argjson extra "$extra" \
      '{model: $model, messages: $messages} + $extra'
  )"

  venice:curl POST /chat/completions "$body"
}

export -f chat:completion

#-------------------------------------------------------------------------------
# chat:extract-content
#
# Read a Venice chat completion response from stdin and print
# .choices[0].message.content to stdout. If content is null (e.g. a
# tool-call-only response), prints an empty string instead of the literal
# text "null".
#
# Designed for pipeline composition:
#   chat:completion "$model" "$messages" | chat:extract-content
#-------------------------------------------------------------------------------
chat:extract-content() {
  jq -r '.choices[0].message.content // ""'
}

export -f chat:extract-content
