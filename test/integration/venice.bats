#!/usr/bin/env bats

# vim: set ft=bash
set -euo pipefail

#-------------------------------------------------------------------------------
# Integration tests - REAL API CALLS
#
# These tests hit https://api.venice.ai and cost real money. They are never
# run automatically; opt in via `mise run test:integration` or
# helpers/run-integration-tests.
#
# Tests skip individually if no API key is set (SCRATCH_VENICE_API_KEY or
# VENICE_API_KEY), so the whole run does not fail just because the key
# is unavailable.
#
# Each test uses a per-test HOME so the model cache does not persist across
# tests within a single integration run.
#-------------------------------------------------------------------------------

setup() {
  SCRIPTDIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" > /dev/null 2>&1 && pwd)"
  SCRATCH_HOME="$(cd "${SCRIPTDIR}/../.." && pwd)"
  source "${SCRIPTDIR}/../helpers.sh"
  source "${SCRATCH_HOME}/lib/venice.sh"
  source "${SCRATCH_HOME}/lib/model.sh"
  source "${SCRATCH_HOME}/lib/chat.sh"

  # Skip when the key isn't available so CI (and contributors without a
  # key) don't fail this suite.
  if [[ -z "${SCRATCH_VENICE_API_KEY:-}" && -z "${VENICE_API_KEY:-}" ]]; then
    skip "no venice api key set (SCRATCH_VENICE_API_KEY or VENICE_API_KEY)"
  fi

  # Per-test HOME so model cache state doesn't leak between tests.
  export HOME="${BATS_TEST_TMPDIR}/home"
  mkdir -p "$HOME"
}

# ---------------------------------------------------------------------------
# venice:curl - sanity check that auth and transport work end-to-end
# ---------------------------------------------------------------------------

@test "venice:curl GET /models returns a list envelope" {
  local response
  response="$(venice:curl GET '/models?type=all')"

  local object
  object="$(jq -r '.object' <<< "$response")"
  is "$object" "list"

  # Should contain at least some models
  local count
  count="$(jq -r '.data | length' <<< "$response")"
  [[ "$count" -gt 0 ]]
}

# ---------------------------------------------------------------------------
# model.sh - fetch and validate against the real registry
# ---------------------------------------------------------------------------

@test "model:fetch populates the cache with at least one text model" {
  model:fetch

  # Cache file should exist
  local cache
  cache="$(model:cache-path)"
  [[ -f "$cache" ]]

  # Should contain at least one text model
  local first
  first="$(model:list text | head -1)"
  [[ -n "$first" ]]
}

@test "model:validate accepts the first listed text model" {
  model:fetch
  local first
  first="$(model:list text | head -1)"

  run model:validate "$first"
  is "$status" 0
}

@test "model:validate rejects a nonsense model id" {
  model:fetch

  run model:validate "not-a-real-model-xyz-12345"
  is "$status" 1
}

# ---------------------------------------------------------------------------
# chat.sh - send a tiny completion and verify the shape comes back
# ---------------------------------------------------------------------------

@test "chat:completion returns a valid response against a real text model" {
  model:fetch
  local model
  model="$(model:list text | head -1)"

  local messages='[{"role":"user","content":"Reply with the single word: ok"}]'
  local extras='{"max_completion_tokens":16,"temperature":0}'

  local response
  response="$(chat:completion "$model" "$messages" "$extras")"

  # Response should have the OpenAI-compatible shape
  local object
  object="$(jq -r '.object' <<< "$response")"
  is "$object" "chat.completion"

  # Should have at least one choice with content
  local content
  content="$(chat:extract-content <<< "$response")"
  [[ -n "$content" ]]
}
