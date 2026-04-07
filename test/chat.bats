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
