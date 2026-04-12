#!/usr/bin/env bats

# vim: set ft=bash
set -euo pipefail

#-------------------------------------------------------------------------------
# Integration tests for the chat feature - REAL API CALLS
#
# Exercises lib/conversations.sh + agents/coordinator end to end against
# Venice. Run via `mise run test:integration` or helpers/run-integration-tests;
# never automatic.
#
# These tests cost real money. Skip cleanly without an API key.
#-------------------------------------------------------------------------------

setup() {
  SCRIPTDIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" > /dev/null 2>&1 && pwd)"
  SCRATCH_HOME="$(cd "${SCRIPTDIR}/../.." && pwd)"
  # shellcheck disable=SC1091
  source "${SCRIPTDIR}/../helpers.sh"
  # shellcheck disable=SC1091
  {
    source "${SCRATCH_HOME}/lib/agent.sh"
    source "${SCRATCH_HOME}/lib/conversations.sh"
    source "${SCRATCH_HOME}/lib/project.sh"
    source "${SCRATCH_HOME}/lib/chat.sh"
    source "${SCRATCH_HOME}/lib/model.sh"
  }

  if [[ -z "${SCRATCH_VENICE_API_KEY:-}" && -z "${VENICE_API_KEY:-}" ]]; then
    skip "no venice api key set (SCRATCH_VENICE_API_KEY or VENICE_API_KEY)"
  fi

  # Isolated HOME so conversation files land in the bats tmpdir
  export HOME="${BATS_TEST_TMPDIR}/home"
  mkdir -p "$HOME"
  export SCRATCH_CONFIG_DIR="${HOME}/.config/scratch"
  export SCRATCH_PROJECTS_DIR="${SCRATCH_CONFIG_DIR}/projects"
  mkdir -p "$SCRATCH_PROJECTS_DIR"

  # Create a fake project for the conversations to live in
  project:save "testproj" "${BATS_TEST_TMPDIR}/testproj" "false"

  # Enable debug logging for every test - makes failures self-diagnosing
  export SCRATCH_CHAT_DEBUG_LOG="${BATS_TEST_TMPDIR}/chat-debug.log"

  # Keep retries low so a persistent 500 fails fast instead of burning
  # minutes on backoff loops.
  export SCRATCH_VENICE_MAX_ATTEMPTS=1
  export SCRATCH_VENICE_DISABLE_JITTER=1
}

# ---------------------------------------------------------------------------
# chat:completion with the balanced profile (what coordinator uses)
# ---------------------------------------------------------------------------

@test "chat:completion with balanced profile answers a trivial prompt" {
  local model extras messages response
  model="$(model:profile:model balanced)"
  extras="$(model:profile:extras balanced)"
  messages='[{"role":"user","content":"Reply with the single word: ack"}]'

  response="$(chat:completion "$model" "$messages" "$extras")"

  # Log what we got for diagnostic purposes
  diag "model=$model"
  diag "extras=$extras"
  diag "response=$(jq -r '.choices[0].message.content // "(empty)"' <<< "$response" 2> /dev/null || echo '(parse failed)')"

  # Should have a choices array with at least one entry
  run jq -r '.choices | length' <<< "$response"
  [[ "$output" -ge 1 ]]
}

# ---------------------------------------------------------------------------
# coordinator agent end-to-end: what the chat loop actually calls
# ---------------------------------------------------------------------------

@test "agent:run coordinator responds to a minimal messages array" {
  # Simulate what bin/scratch-chat passes: a JSON messages array with one
  # user message. The coordinator prepends its system prompt and calls
  # chat:completion with the balanced profile.
  local messages response
  messages='[{"role":"user","content":"Reply with one word only: acknowledged."}]'

  response="$(printf '%s' "$messages" | agent:run coordinator)"

  diag "debug log:"
  if [[ -f "$SCRATCH_CHAT_DEBUG_LOG" ]]; then
    while IFS= read -r line; do
      diag "  $line"
    done < "$SCRATCH_CHAT_DEBUG_LOG"
  fi

  [[ -n "$response" ]]
}

# ---------------------------------------------------------------------------
# Full conversation persistence + coordinator round-trip
# ---------------------------------------------------------------------------

@test "full round: create conversation, append message, run coordinator, persist response" {
  local slug
  slug="$(conversation:create "testproj")"

  # Append user message
  conversation:append-message "testproj" "$slug" \
    '{"role":"user","content":"Reply with exactly: OK"}'

  # Build messages array and call coordinator (what bin/scratch-chat does)
  local messages_array response
  messages_array="$(conversation:messages-as-array "testproj" "$slug")"
  response="$(printf '%s' "$messages_array" | agent:run coordinator)"

  diag "response: $response"
  diag "debug log:"
  if [[ -f "$SCRATCH_CHAT_DEBUG_LOG" ]]; then
    while IFS= read -r line; do
      diag "  $line"
    done < "$SCRATCH_CHAT_DEBUG_LOG"
  fi

  [[ -n "$response" ]]

  # Persist the response like the real chat loop does
  local assistant_msg
  assistant_msg="$(jq -c -n --arg content "$response" \
    '{role: "assistant", content: $content}')"
  conversation:append-message "testproj" "$slug" "$assistant_msg"

  # Verify both messages are in the file
  local count
  count="$(wc -l < "${SCRATCH_PROJECTS_DIR}/testproj/chats/${slug}/messages.jsonl" | tr -d ' ')"
  is "$count" "2"
}
