#!/usr/bin/env bats

# vim: set ft=bash
set -euo pipefail

#-------------------------------------------------------------------------------
# Tests for lib/model.sh
#
# Strategy: override venice:curl as a bash function to return a canned
# JSON response. This tests model.sh logic in isolation from the venice
# HTTP wrapper, which has its own tests in venice.bats.
#
# HOME is already a tmpdir under helpers/run-tests, so cache writes under
# venice:config-dir land in a throwaway location automatically.
#-------------------------------------------------------------------------------

setup() {
  SCRIPTDIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" > /dev/null 2>&1 && pwd)"
  SCRATCH_HOME="$(cd "${SCRIPTDIR}/.." && pwd)"
  source "${SCRIPTDIR}/helpers.sh"
  source "${SCRATCH_HOME}/lib/model.sh"

  # Per-test HOME so the model cache (under venice:config-dir) is fresh
  # for every test. helpers/run-tests already isolates HOME to a tmpdir
  # for the whole run, but tests that share a file path still leak state
  # between each other without this per-test reset.
  export HOME="${BATS_TEST_TMPDIR}/home"
  mkdir -p "$HOME"

  # Needed by venice:api-key if model:fetch ever runs; shouldn't since
  # tests always override venice:curl, but a safety net keeps failures clear.
  export SCRATCH_VENICE_API_KEY="test-key"
}

# Canned response shaped like the real Venice /models?type=all body.
# Two text models with different capabilities, one image model.
canned_response() {
  cat << 'EOF'
{
  "object": "list",
  "type": "all",
  "data": [
    {
      "id": "llama-3-large",
      "type": "text",
      "object": "model",
      "owned_by": "venice.ai",
      "model_spec": {
        "name": "Llama 3 Large",
        "privacy": "private",
        "capabilities": {
          "supportsFunctionCalling": true,
          "supportsVision": false,
          "supportsReasoning": false
        }
      }
    },
    {
      "id": "reasoning-small",
      "type": "text",
      "object": "model",
      "owned_by": "venice.ai",
      "model_spec": {
        "name": "Reasoning Small",
        "privacy": "anonymized",
        "capabilities": {
          "supportsFunctionCalling": false,
          "supportsVision": false,
          "supportsReasoning": true
        }
      }
    },
    {
      "id": "image-xl",
      "type": "image",
      "object": "model",
      "owned_by": "venice.ai",
      "model_spec": {
        "name": "Image XL",
        "privacy": "private"
      }
    }
  ]
}
EOF
}

# Install a function override for venice:curl that returns the canned
# response regardless of args. Callers can inspect $_venice_curl_calls
# to see how many times it was invoked.
install_venice_curl_stub() {
  _venice_curl_calls=0
  venice:curl() {
    _venice_curl_calls=$((_venice_curl_calls + 1))
    canned_response
  }
}

# Pre-populate the cache so read functions don't lazy-fetch.
seed_cache() {
  local cache
  cache="$(model:cache-path)"
  mkdir -p "$(dirname "$cache")"
  canned_response > "$cache"
}

# ---------------------------------------------------------------------------
# model:cache-path
# ---------------------------------------------------------------------------

@test "model:cache-path lives under HOME/.config/scratch/venice" {
  run model:cache-path
  is "$status" 0
  is "$output" "${HOME}/.config/scratch/venice/models.json"
}

# ---------------------------------------------------------------------------
# model:fetch
# ---------------------------------------------------------------------------

@test "model:fetch writes canned response to the cache file" {
  install_venice_curl_stub
  model:fetch

  local cache
  cache="$(model:cache-path)"
  [[ -f "$cache" ]]

  run jq -r '.object' "$cache"
  is "$output" "list"
}

@test "model:fetch is atomic: no partial writes on failure" {
  local cache
  cache="$(model:cache-path)"
  mkdir -p "$(dirname "$cache")"

  # Run model:fetch in a subshell where venice:curl fails. We pass the
  # cache path through so the subshell uses the same per-test HOME.
  run bash -c '
    set -e
    export HOME='"'${HOME}'"'
    source '"${SCRATCH_HOME}"'/lib/model.sh
    venice:curl() { echo >&2 fail; return 1; }
    model:fetch 2>&1
  '
  is "$status" 1

  # Cache should not exist (no partial file)
  [[ ! -f "$cache" ]]
}

# ---------------------------------------------------------------------------
# _model:ensure-cache (lazy load behavior)
# ---------------------------------------------------------------------------

@test "read functions trigger fetch when cache is missing" {
  install_venice_curl_stub

  local cache
  cache="$(model:cache-path)"
  [[ ! -f "$cache" ]]

  run model:list
  is "$status" 0

  # After the first read, cache should exist
  [[ -f "$cache" ]]
}

@test "read functions do not refetch when cache exists" {
  install_venice_curl_stub
  seed_cache
  _venice_curl_calls=0

  model:list > /dev/null
  is "$_venice_curl_calls" "0"
}

# ---------------------------------------------------------------------------
# model:list
# ---------------------------------------------------------------------------

@test "model:list with no filter prints all model ids sorted" {
  install_venice_curl_stub
  seed_cache

  run model:list
  is "$status" 0
  # Expected sorted order: image-xl, llama-3-large, reasoning-small
  is "$(echo "$output" | head -1)" "image-xl"
  is "$(echo "$output" | tail -1)" "reasoning-small"
}

@test "model:list text returns only text models" {
  install_venice_curl_stub
  seed_cache

  run model:list text
  is "$status" 0
  [[ "$output" == *"llama-3-large"* ]]
  [[ "$output" == *"reasoning-small"* ]]
  [[ "$output" != *"image-xl"* ]]
}

@test "model:list image returns only image models" {
  install_venice_curl_stub
  seed_cache

  run model:list image
  is "$status" 0
  is "$output" "image-xl"
}

# ---------------------------------------------------------------------------
# model:get
# ---------------------------------------------------------------------------

@test "model:get returns the full JSON object for a known id" {
  install_venice_curl_stub
  seed_cache

  run model:get llama-3-large
  is "$status" 0
  [[ "$output" == *'"id": "llama-3-large"'* ]]
  [[ "$output" == *'"type": "text"'* ]]
  [[ "$output" == *'"supportsFunctionCalling": true'* ]]
}

@test "model:get dies for an unknown id" {
  install_venice_curl_stub
  seed_cache

  run bash -c '
    set -e
    export HOME='"'${HOME}'"'
    source '"${SCRATCH_HOME}"'/lib/model.sh
    model:get ghost-model 2>&1
  '
  is "$status" 1
  [[ "$output" == *"not found"* ]]
  [[ "$output" == *"ghost-model"* ]]
}

# ---------------------------------------------------------------------------
# model:exists
# ---------------------------------------------------------------------------

@test "model:exists returns 0 for a known id" {
  install_venice_curl_stub
  seed_cache

  run model:exists llama-3-large
  is "$status" 0
}

@test "model:exists returns 1 for an unknown id" {
  install_venice_curl_stub
  seed_cache

  run model:exists ghost-model
  is "$status" 1
}

# ---------------------------------------------------------------------------
# model:jq
# ---------------------------------------------------------------------------

@test "model:jq extracts a capability field" {
  install_venice_curl_stub
  seed_cache

  run model:jq llama-3-large '.model_spec.capabilities.supportsFunctionCalling'
  is "$status" 0
  is "$output" "true"
}

@test "model:jq extracts a nested name" {
  install_venice_curl_stub
  seed_cache

  run model:jq reasoning-small '.model_spec.name'
  is "$status" 0
  is "$output" "Reasoning Small"
}

@test "model:jq handles default fallback syntax" {
  install_venice_curl_stub
  seed_cache

  # image-xl has no capabilities field; use // default
  run model:jq image-xl '.model_spec.capabilities.supportsFunctionCalling // false'
  is "$status" 0
  is "$output" "false"
}

@test "model:jq dies for an unknown id" {
  install_venice_curl_stub
  seed_cache

  run bash -c '
    set -e
    export HOME='"'${HOME}'"'
    source '"${SCRATCH_HOME}"'/lib/model.sh
    model:jq ghost .id 2>&1
  '
  is "$status" 1
  [[ "$output" == *"not found"* ]]
}
