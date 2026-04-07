#!/usr/bin/env bats

# vim: set ft=bash
set -euo pipefail

#-------------------------------------------------------------------------------
# Tests for lib/chat.sh
#
# Same strategy as model.bats: override venice:curl as a bash function so
# we test chat.sh's request-building and response-handling logic without
# touching the network.
#
# The override also captures the request body for assertions, so we can
# verify chat:completion actually builds the request shape we expect.
#-------------------------------------------------------------------------------

setup() {
  SCRIPTDIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" > /dev/null 2>&1 && pwd)"
  SCRATCH_HOME="$(cd "${SCRIPTDIR}/.." && pwd)"
  source "${SCRIPTDIR}/helpers.sh"
  source "${SCRATCH_HOME}/lib/chat.sh"

  # Per-test HOME - consistent with other lib tests, even though chat.sh
  # does not itself write files.
  export HOME="${BATS_TEST_TMPDIR}/home"
  mkdir -p "$HOME"

  # Safety net - not actually needed since venice:curl is overridden
  export SCRATCH_VENICE_API_KEY="test-key"

  # Shared state file between the stub and the test body
  CAPTURE_FILE="${BATS_TEST_TMPDIR}/captured-request.json"
  RESPONSE_FILE="${BATS_TEST_TMPDIR}/canned-response.json"
}

# Install a venice:curl override that:
#   - captures method + path + body into CAPTURE_FILE
#   - returns the contents of RESPONSE_FILE (must be pre-populated)
install_venice_curl_capture() {
  local capture="$CAPTURE_FILE"
  local response="$RESPONSE_FILE"
  eval "venice:curl() {
    local method=\"\$1\"
    local path=\"\$2\"
    local body=\"\${3:-}\"
    jq -n \
      --arg method \"\$method\" \
      --arg path \"\$path\" \
      --arg body \"\$body\" \
      '{method: \$method, path: \$path, body: \$body}' > '${capture}'
    cat '${response}'
  }"
}

# A minimal Venice response shape for chat:extract-content tests
canned_chat_response() {
  cat << 'EOF'
{
  "id": "cmpl-test",
  "object": "chat.completion",
  "created": 1700000000,
  "model": "llama-3-large",
  "choices": [
    {
      "index": 0,
      "message": {
        "role": "assistant",
        "content": "Hello there, traveler."
      },
      "finish_reason": "stop"
    }
  ],
  "usage": {
    "prompt_tokens": 10,
    "completion_tokens": 5,
    "total_tokens": 15
  }
}
EOF
}

# ---------------------------------------------------------------------------
# chat:completion - request building
# ---------------------------------------------------------------------------

@test "chat:completion calls POST /chat/completions" {
  canned_chat_response > "$RESPONSE_FILE"
  install_venice_curl_capture

  chat:completion llama-3-large '[{"role":"user","content":"hi"}]' > /dev/null

  run jq -r '.method' "$CAPTURE_FILE"
  is "$output" "POST"

  run jq -r '.path' "$CAPTURE_FILE"
  is "$output" "/chat/completions"
}

@test "chat:completion sets model in the body" {
  canned_chat_response > "$RESPONSE_FILE"
  install_venice_curl_capture

  chat:completion llama-3-large '[{"role":"user","content":"hi"}]' > /dev/null

  run jq -r '.body | fromjson | .model' "$CAPTURE_FILE"
  is "$output" "llama-3-large"
}

@test "chat:completion passes through messages array" {
  canned_chat_response > "$RESPONSE_FILE"
  install_venice_curl_capture

  local messages='[{"role":"system","content":"be helpful"},{"role":"user","content":"hi"}]'
  chat:completion llama-3-large "$messages" > /dev/null

  run jq -r '.body | fromjson | .messages | length' "$CAPTURE_FILE"
  is "$output" "2"

  run jq -r '.body | fromjson | .messages[0].role' "$CAPTURE_FILE"
  is "$output" "system"

  run jq -r '.body | fromjson | .messages[1].content' "$CAPTURE_FILE"
  is "$output" "hi"
}

@test "chat:completion merges extras shallowly into the body" {
  canned_chat_response > "$RESPONSE_FILE"
  install_venice_curl_capture

  local messages='[{"role":"user","content":"x"}]'
  local extras='{"temperature":0.7,"max_completion_tokens":100}'

  chat:completion llama-3-large "$messages" "$extras" > /dev/null

  run jq -r '.body | fromjson | .temperature' "$CAPTURE_FILE"
  is "$output" "0.7"

  run jq -r '.body | fromjson | .max_completion_tokens' "$CAPTURE_FILE"
  is "$output" "100"
}

@test "chat:completion preserves venice_parameters in extras" {
  canned_chat_response > "$RESPONSE_FILE"
  install_venice_curl_capture

  local messages='[{"role":"user","content":"x"}]'
  local extras='{"venice_parameters":{"enable_web_search":"auto","character_slug":"test-char"}}'

  chat:completion llama-3-large "$messages" "$extras" > /dev/null

  run jq -r '.body | fromjson | .venice_parameters.enable_web_search' "$CAPTURE_FILE"
  is "$output" "auto"

  run jq -r '.body | fromjson | .venice_parameters.character_slug' "$CAPTURE_FILE"
  is "$output" "test-char"
}

@test "chat:completion works with no extras argument" {
  canned_chat_response > "$RESPONSE_FILE"
  install_venice_curl_capture

  run chat:completion llama-3-large '[{"role":"user","content":"x"}]'
  is "$status" 0
}

@test "chat:completion works with empty string extras" {
  canned_chat_response > "$RESPONSE_FILE"
  install_venice_curl_capture

  run chat:completion llama-3-large '[{"role":"user","content":"x"}]' ''
  is "$status" 0
}

# ---------------------------------------------------------------------------
# chat:completion - response return
# ---------------------------------------------------------------------------

@test "chat:completion prints the full response body" {
  canned_chat_response > "$RESPONSE_FILE"
  install_venice_curl_capture

  run chat:completion llama-3-large '[{"role":"user","content":"x"}]'
  is "$status" 0
  [[ "$output" == *'"cmpl-test"'* ]]
  [[ "$output" == *"Hello there"* ]]
}

# ---------------------------------------------------------------------------
# chat:extract-content
# ---------------------------------------------------------------------------

@test "chat:extract-content pulls the assistant content" {
  run bash -c 'source '"${SCRATCH_HOME}"'/lib/chat.sh; '"$(declare -f canned_chat_response)"'; canned_chat_response | chat:extract-content'
  is "$status" 0
  is "$output" "Hello there, traveler."
}

@test "chat:extract-content returns empty string when content is null" {
  local response='{"choices":[{"index":0,"message":{"role":"assistant","content":null,"tool_calls":[]},"finish_reason":"tool_calls"}]}'

  run bash -c 'source '"${SCRATCH_HOME}"'/lib/chat.sh; echo '"'${response}'"' | chat:extract-content'
  is "$status" 0
  is "$output" ""
}

@test "chat:extract-content handles missing content field" {
  local response='{"choices":[{"message":{"role":"assistant"}}]}'

  run bash -c 'source '"${SCRATCH_HOME}"'/lib/chat.sh; echo '"'${response}'"' | chat:extract-content'
  is "$status" 0
  is "$output" ""
}

# ===========================================================================
# chat:complete-with-tools (recursion driver)
# ===========================================================================

# Multi-response venice:curl override.
#
# Reads canned responses from numbered files: ${RESPONSE_QUEUE_DIR}/0,
# ${RESPONSE_QUEUE_DIR}/1, ... and tracks the call counter in
# ${RESPONSE_QUEUE_DIR}/.counter. Each call to venice:curl returns the
# next file in the queue.
#
# Also captures every request body into ${RESPONSE_QUEUE_DIR}/.req.<n>
# so tests can assert what got sent on each round.
install_venice_curl_queue() {
  local q="$RESPONSE_QUEUE_DIR"
  printf '0' > "${q}/.counter"
  eval "venice:curl() {
    local method=\"\$1\"
    local path=\"\$2\"
    local body=\"\${3:-}\"
    local n
    n=\"\$(cat '${q}/.counter')\"
    printf '%s' \"\$body\" > '${q}/.req.'\$n
    n=\$((n + 1))
    printf '%s' \"\$n\" > '${q}/.counter'
    cat '${q}/'\$((n - 1))
  }"
}

# Set up the response queue dir for a test, and override tool:specs-json
# and tool:invoke-parallel so chat:complete-with-tools doesn't actually
# touch the tool layer.
setup_tool_recursion() {
  RESPONSE_QUEUE_DIR="${BATS_TEST_TMPDIR}/queue"
  mkdir -p "$RESPONSE_QUEUE_DIR"

  # Override tool:specs-json to return a fixed array regardless of args.
  # The recursion driver only cares that it's a non-empty JSON array.
  tool:specs-json() {
    printf '%s\n' '[{"type":"function","function":{"name":"notify","description":"x","parameters":{"type":"object","properties":{},"required":[]}}}]'
  }
  export -f tool:specs-json

  # Override tool:invoke-parallel to return canned tool results read from
  # ${RESPONSE_QUEUE_DIR}/.tool_results.<n>. Each call to the override
  # increments its own counter so multi-round tests can serve different
  # results per round.
  TOOL_RESULTS_DIR="${BATS_TEST_TMPDIR}/tool_results"
  mkdir -p "$TOOL_RESULTS_DIR"
  printf '0' > "${TOOL_RESULTS_DIR}/.counter"

  local trd="$TOOL_RESULTS_DIR"
  eval "tool:invoke-parallel() {
    local calls=\"\$1\"
    local n
    n=\"\$(cat '${trd}/.counter')\"
    printf '%s' \"\$calls\" > '${trd}/.calls.'\$n
    n=\$((n + 1))
    printf '%s' \"\$n\" > '${trd}/.counter'
    cat '${trd}/'\$((n - 1))
  }"
  export -f tool:invoke-parallel
}

# Helpers for queueing canned responses + tool results. Find the next
# free numeric slot by incremental probe rather than ls/grep/sort/tail,
# which trips set -euo pipefail when no matching files exist (grep
# returns 1 on no match, killing the pipeline).
queue_response() {
  local n=0
  while [[ -e "${RESPONSE_QUEUE_DIR}/${n}" ]]; do
    n=$((n + 1))
  done
  cat > "${RESPONSE_QUEUE_DIR}/${n}"
}

queue_tool_results() {
  local n=0
  while [[ -e "${TOOL_RESULTS_DIR}/${n}" ]]; do
    n=$((n + 1))
  done
  cat > "${TOOL_RESULTS_DIR}/${n}"
}

# A plain text response (no tool_calls), used to terminate the recursion.
text_response() {
  local content="$1"
  cat << EOF
{
  "id": "cmpl-test",
  "object": "chat.completion",
  "model": "fake-model",
  "choices": [
    {
      "index": 0,
      "message": {"role": "assistant", "content": "${content}"},
      "finish_reason": "stop"
    }
  ]
}
EOF
}

# A response with one tool_call, used to drive the recursion.
tool_call_response() {
  local id="$1"
  local name="$2"
  local args_json_str="$3"  # this is a STRING containing JSON, per OpenAI
  cat << EOF
{
  "id": "cmpl-test",
  "object": "chat.completion",
  "model": "fake-model",
  "choices": [
    {
      "index": 0,
      "message": {
        "role": "assistant",
        "content": null,
        "tool_calls": [
          {
            "id": "${id}",
            "type": "function",
            "function": {"name": "${name}", "arguments": "${args_json_str}"}
          }
        ]
      },
      "finish_reason": "tool_calls"
    }
  ]
}
EOF
}

# ---------------------------------------------------------------------------
# chat:complete-with-tools - validation
# ---------------------------------------------------------------------------

@test "chat:complete-with-tools dies on empty TOOL_NAMES_JSON" {
  setup_tool_recursion
  run chat:complete-with-tools fake-model '[]' '[]'
  is "$status" 1
  [[ "$output" == *"non-empty"* ]] || [[ "$output" == *"chat:completion"* ]]
}

# ---------------------------------------------------------------------------
# chat:complete-with-tools - one round (no tool calls, model returns text immediately)
# ---------------------------------------------------------------------------

@test "chat:complete-with-tools returns plain response when model has no tool calls" {
  setup_tool_recursion
  install_venice_curl_queue

  text_response "hello world" | queue_response

  local out
  out="$(chat:complete-with-tools fake-model '[{"role":"user","content":"hi"}]' '["notify"]')"

  run jq -r '.choices[0].message.content' <<< "$out"
  is "$output" "hello world"
}

# ---------------------------------------------------------------------------
# chat:complete-with-tools - two rounds (model requests one tool call, then text)
# ---------------------------------------------------------------------------

@test "chat:complete-with-tools recurses through one tool call then text" {
  setup_tool_recursion
  install_venice_curl_queue

  # Round 1: model asks for notify
  tool_call_response "call_1" "notify" '{\"level\":\"info\",\"message\":\"hello\"}' | queue_response
  # Round 2: model returns final text
  text_response "all done" | queue_response

  # Tool result for round 1
  printf '%s' '[{"tool_call_id":"call_1","content":"notification delivered","ok":true}]' | queue_tool_results

  local out
  out="$(chat:complete-with-tools fake-model '[{"role":"user","content":"notify me"}]' '["notify"]')"

  run jq -r '.choices[0].message.content' <<< "$out"
  is "$output" "all done"

  # Verify two API calls were made
  local n
  n="$(cat "${RESPONSE_QUEUE_DIR}/.counter")"
  is "$n" "2"
}

# ---------------------------------------------------------------------------
# chat:complete-with-tools - three rounds (chained tool calls)
# ---------------------------------------------------------------------------

@test "chat:complete-with-tools handles chained tool calls across multiple rounds" {
  setup_tool_recursion
  install_venice_curl_queue

  # Round 1: tool call A
  tool_call_response "call_a" "notify" '{}' | queue_response
  # Round 2: tool call B (different id)
  tool_call_response "call_b" "notify" '{}' | queue_response
  # Round 3: text
  text_response "fully chained" | queue_response

  # Tool results for each round
  printf '%s' '[{"tool_call_id":"call_a","content":"a done","ok":true}]' | queue_tool_results
  printf '%s' '[{"tool_call_id":"call_b","content":"b done","ok":true}]' | queue_tool_results

  local out
  out="$(chat:complete-with-tools fake-model '[{"role":"user","content":"chain"}]' '["notify"]')"

  run jq -r '.choices[0].message.content' <<< "$out"
  is "$output" "fully chained"

  local n
  n="$(cat "${RESPONSE_QUEUE_DIR}/.counter")"
  is "$n" "3"
}

# ---------------------------------------------------------------------------
# chat:complete-with-tools - tool result message gets appended to messages
# ---------------------------------------------------------------------------

@test "chat:complete-with-tools appends tool result messages to the next request" {
  setup_tool_recursion
  install_venice_curl_queue

  tool_call_response "call_x" "notify" '{}' | queue_response
  text_response "ok" | queue_response

  printf '%s' '[{"tool_call_id":"call_x","content":"the result","ok":true}]' | queue_tool_results

  chat:complete-with-tools fake-model '[{"role":"user","content":"go"}]' '["notify"]' > /dev/null

  # Inspect the second request body - it should contain the tool result message
  local req2
  req2="$(cat "${RESPONSE_QUEUE_DIR}/.req.1")"

  run jq -r '.messages | length' <<< "$req2"
  is "$output" "3" # original user + assistant tool_call + tool result

  run jq -r '.messages[2].role' <<< "$req2"
  is "$output" "tool"

  run jq -r '.messages[2].tool_call_id' <<< "$req2"
  is "$output" "call_x"

  run jq -r '.messages[2].content' <<< "$req2"
  is "$output" "the result"
}

# ---------------------------------------------------------------------------
# chat:complete-with-tools - tools array gets injected into request body
# ---------------------------------------------------------------------------

@test "chat:complete-with-tools injects tools into the request body" {
  setup_tool_recursion
  install_venice_curl_queue

  text_response "done" | queue_response

  chat:complete-with-tools fake-model '[{"role":"user","content":"x"}]' '["notify"]' > /dev/null

  local req
  req="$(cat "${RESPONSE_QUEUE_DIR}/.req.0")"

  run jq -r '.tools | length' <<< "$req"
  is "$output" "1"

  run jq -r '.tools[0].type' <<< "$req"
  is "$output" "function"

  run jq -r '.tools[0].function.name' <<< "$req"
  is "$output" "notify"
}

# ---------------------------------------------------------------------------
# chat:complete-with-tools - extras are merged with tools
# ---------------------------------------------------------------------------

@test "chat:complete-with-tools merges extras with the tools array" {
  setup_tool_recursion
  install_venice_curl_queue

  text_response "done" | queue_response

  chat:complete-with-tools fake-model '[{"role":"user","content":"x"}]' '["notify"]' '{"temperature":0.7}' > /dev/null

  local req
  req="$(cat "${RESPONSE_QUEUE_DIR}/.req.0")"

  run jq -r '.temperature' <<< "$req"
  is "$output" "0.7"

  run jq -r '.tools | length' <<< "$req"
  is "$output" "1"
}

# ---------------------------------------------------------------------------
# chat:complete-with-tools - malformed tool argument JSON falls back to {}
# ---------------------------------------------------------------------------

@test "chat:complete-with-tools tolerates malformed tool argument JSON" {
  setup_tool_recursion
  install_venice_curl_queue

  # Round 1: tool_call with INVALID JSON in arguments string
  tool_call_response "call_bad" "notify" 'not valid json' | queue_response
  text_response "recovered" | queue_response

  printf '%s' '[{"tool_call_id":"call_bad","content":"ok","ok":true}]' | queue_tool_results

  local out
  out="$(chat:complete-with-tools fake-model '[{"role":"user","content":"go"}]' '["notify"]')"

  run jq -r '.choices[0].message.content' <<< "$out"
  is "$output" "recovered"

  # The tool:invoke-parallel override captured the calls JSON it received.
  # The args field should be {} (the fallback) because the original
  # arguments string was malformed.
  local calls
  calls="$(cat "${TOOL_RESULTS_DIR}/.calls.0")"
  run jq -c '.[0].args' <<< "$calls"
  is "$output" "{}"
}
