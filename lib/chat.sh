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
  source "$_CHAT_SCRIPTDIR/tool.sh"
}

has-commands jq
uses-env-vars SCRATCH_CHAT_DEBUG_LOG
describe-env-var SCRATCH_CHAT_DEBUG_LOG "explicit file path for chat API request/response log"

#-------------------------------------------------------------------------------
# _chat:_debug-log EVENT PAYLOAD
#
# (Private) Append a debug entry to SCRATCH_CHAT_DEBUG_LOG if set. The log
# file captures every request/response pair so we can diagnose API errors
# without running the chat loop interactively.
#
# EVENT    short identifier for the entry (e.g., "request", "response")
# PAYLOAD  JSON string to include in the entry. Logged as-is; callers
#          compact it with jq -c if they want single-line entries.
#
# No-op when SCRATCH_CHAT_DEBUG_LOG is unset or empty. Best-effort:
# failures to write are swallowed so logging never breaks the chat flow.
#-------------------------------------------------------------------------------
_chat:_debug-log() {
  [[ -n "${SCRATCH_CHAT_DEBUG_LOG:-}" ]] || return 0

  local event="$1"
  local payload="$2"

  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  {
    printf '%s %s\n' "$ts" "$event"
    printf '%s\n' "$payload"
    printf -- '---\n'
  } >> "$SCRATCH_CHAT_DEBUG_LOG" 2> /dev/null || true
}

export -f _chat:_debug-log

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

  _chat:_debug-log "request POST /chat/completions" "$body"

  local response
  response="$(venice:curl POST /chat/completions "$body")"

  _chat:_debug-log "response" "$response"

  printf '%s' "$response"
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

#-------------------------------------------------------------------------------
# chat:complete-with-tools MODEL MESSAGES_JSON TOOL_NAMES_JSON [EXTRA_JSON]
#
# Like chat:completion, but loops on Venice tool_calls responses. Each round:
#
#   1. Send the current messages + tools to the model.
#   2. If the response has .choices[0].message.tool_calls, execute them in
#      parallel via tool:invoke-parallel, append the assistant message and
#      one tool result message per call to the messages array, and repeat.
#   3. If the response is plain text (no tool_calls), return it as-is.
#
# MODEL            model id string
# MESSAGES_JSON    initial JSON array of messages
# TOOL_NAMES_JSON  non-empty JSON array of tool names; tool:specs-json wraps
#                  each into the OpenAI function envelope before sending.
#                  Tools that fail their is-available check are silently
#                  filtered out.
# EXTRA_JSON       optional extras object (temperature, venice_parameters,
#                  response_format, etc.). The "tools" key is set by us;
#                  any "tools" key in EXTRA_JSON will be overridden.
#
# Returns the FINAL response body JSON (after the model has stopped asking
# for tool calls). Dies on API errors via venice:curl.
#
# Empty TOOL_NAMES_JSON dies with a hint to use chat:completion directly.
# No max recursion cap by user decision; runaway models burn API credit
# until Ctrl-C.
#
# Defensive .function.arguments parsing: the model's tool argument JSON is
# parsed via `fromjson? // {}` so a malformed argument string surfaces as
# an empty object instead of killing the recursion. The tool then sees
# {} for SCRATCH_TOOL_ARGS_JSON and can fail with its own clear error.
#
# Example:
#   messages='[{"role":"user","content":"notify me with hello"}]'
#   tools='["notify"]'
#   chat:complete-with-tools llama-3-large "$messages" "$tools"
#-------------------------------------------------------------------------------
chat:complete-with-tools() {
  local model="$1"
  local messages="$2"
  local tool_names_json="$3"
  local extras="${4:-}"

  [[ -n "$extras" ]] || extras='{}'

  # Validate the tools array up front
  local tool_count
  tool_count="$(jq 'length' <<< "$tool_names_json" 2> /dev/null || echo "")"
  if [[ -z "$tool_count" || "$tool_count" == "0" ]]; then
    die "chat:complete-with-tools: TOOL_NAMES_JSON must be a non-empty JSON array (use chat:completion directly for the no-tools case)"
    return 1
  fi

  # Resolve tool names to specs (filters out unavailable tools)
  local tool_names_args
  mapfile -t tool_names_args < <(jq -r '.[]' <<< "$tool_names_json")

  local specs
  specs="$(tool:specs-json "${tool_names_args[@]}")"

  # Inject tools into extras (overriding any caller-provided tools key)
  local merged_extras
  merged_extras="$(jq -c --argjson t "$specs" '. + {tools: $t}' <<< "$extras")"

  local response
  local tool_calls
  local calls
  local results
  local assistant_msg

  while :; do
    response="$(chat:completion "$model" "$messages" "$merged_extras")"

    # Extract tool_calls. Some models return null, some return an empty
    # array [], some omit the field entirely. All three mean "no tool
    # calls." The // empty jq filter covers null and missing; the bash
    # test covers empty string and empty array.
    tool_calls="$(jq -c '.choices[0].message.tool_calls // empty' <<< "$response")"

    if [[ -z "$tool_calls" || "$tool_calls" == "null" || "$tool_calls" == "[]" ]]; then
      # Plain text response (or any non-tool-call response). Return it.
      printf '%s' "$response"
      return 0
    fi

    # Build calls array for tool:invoke-parallel. .function.arguments is
    # a JSON STRING per OpenAI spec; parse it defensively. fromjson? returns
    # null on malformed input; // {} substitutes an empty object so the
    # tool author sees a clear arg shape rather than a crash.
    calls="$(jq -c '[.[] | {
      id: .id,
      name: .function.name,
      args: (.function.arguments | (fromjson? // {}))
    }]' <<< "$tool_calls")"

    results="$(tool:invoke-parallel "$calls")"

    # Append the assistant message (with its tool_calls) and one tool
    # result message per call to the messages array. Order matters: the
    # tool messages must come AFTER the assistant message that requested
    # them, in the same order as the calls.
    assistant_msg="$(jq -c '.choices[0].message' <<< "$response")"
    messages="$(jq -c \
      --argjson assistant "$assistant_msg" \
      --argjson results "$results" \
      '. + [$assistant] + ($results | map({role: "tool", tool_call_id: .tool_call_id, content: .content}))' \
      <<< "$messages")"
  done
}

export -f chat:complete-with-tools
