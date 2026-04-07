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

# ===========================================================================
# MODEL PROFILES (model:profile:*)
#
# Profile tests use a fake data file written under BATS_TEST_TMPDIR and a
# stubbed model:profile:data-path so the lib reads our fixture instead of
# the repo's real data/models.json. This isolates the tests from the actual
# profile config we ship.
#
# Tests that exercise model:profile:validate also seed the registry cache
# (via the install_venice_curl_stub + seed_cache helpers used above) with
# canned model objects whose capabilities flags we control.
# ===========================================================================

# Write a fake profile data file to BATS_TEST_TMPDIR and override the
# data-path function to point at it.
seed_profile_data() {
  local data="$1"
  printf '%s\n' "$data" > "${BATS_TEST_TMPDIR}/profile-data.json"
  eval "model:profile:data-path() { printf '%s\n' '${BATS_TEST_TMPDIR}/profile-data.json'; }"
}

# Sample profile data shaped like the real data/models.json. Two bases
# (smart, fast) and two variants (coding, web) with the same merge
# semantics as the production file.
sample_profile_data() {
  cat << 'EOF'
{
  "version": 1,
  "base": {
    "smart": {
      "model": "llama-3-large",
      "params": {
        "reasoning_effort": "medium"
      }
    },
    "fast": {
      "model": "fast-tiny",
      "params": {}
    }
  },
  "variants": {
    "coding": {
      "extends": "smart",
      "params": {
        "temperature": 0.2
      },
      "venice_parameters": {
        "include_venice_system_prompt": false
      }
    },
    "web": {
      "extends": "smart",
      "venice_parameters": {
        "enable_web_search": "auto"
      }
    }
  }
}
EOF
}

# ---------------------------------------------------------------------------
# model:profile:list / model:profile:exists
# ---------------------------------------------------------------------------

@test "model:profile:list returns all base and variant names sorted" {
  seed_profile_data "$(sample_profile_data)"
  run model:profile:list
  is "$status" 0
  # Expected sorted order: coding, fast, smart, web
  is "$(echo "$output" | head -1)" "coding"
  is "$(echo "$output" | tail -1)" "web"
  [[ "$output" == *"smart"* ]]
  [[ "$output" == *"fast"* ]]
}

@test "model:profile:exists returns 0 for a base profile" {
  seed_profile_data "$(sample_profile_data)"
  run model:profile:exists smart
  is "$status" 0
}

@test "model:profile:exists returns 0 for a variant profile" {
  seed_profile_data "$(sample_profile_data)"
  run model:profile:exists coding
  is "$status" 0
}

@test "model:profile:exists returns 1 for an unknown name" {
  seed_profile_data "$(sample_profile_data)"
  run model:profile:exists ghost
  is "$status" 1
}

# ---------------------------------------------------------------------------
# model:profile:resolve
# ---------------------------------------------------------------------------

@test "model:profile:resolve returns base profile with normalized fields" {
  seed_profile_data "$(sample_profile_data)"
  run model:profile:resolve smart
  is "$status" 0

  # Should have model, params, and (empty) venice_parameters
  run jq -r '.model' <<< "$output"
  is "$output" "llama-3-large"
}

@test "model:profile:resolve normalizes empty venice_parameters" {
  seed_profile_data "$(sample_profile_data)"
  local result
  result="$(model:profile:resolve smart)"
  run jq -r '.venice_parameters | type' <<< "$result"
  is "$output" "object"
}

@test "model:profile:resolve deep-merges variant params with base params" {
  seed_profile_data "$(sample_profile_data)"
  local result
  result="$(model:profile:resolve coding)"

  # Both base's reasoning_effort AND variant's temperature should be present
  run jq -r '.params.reasoning_effort' <<< "$result"
  is "$output" "medium"

  run jq -r '.params.temperature' <<< "$result"
  is "$output" "0.2"
}

@test "model:profile:resolve inherits model from extended base" {
  seed_profile_data "$(sample_profile_data)"
  local result
  result="$(model:profile:resolve coding)"
  run jq -r '.model' <<< "$result"
  is "$output" "llama-3-large"
}

@test "model:profile:resolve includes variant venice_parameters" {
  seed_profile_data "$(sample_profile_data)"
  local result
  result="$(model:profile:resolve coding)"
  run jq -r '.venice_parameters.include_venice_system_prompt' <<< "$result"
  is "$output" "false"
}

@test "model:profile:resolve drops the extends field from output" {
  seed_profile_data "$(sample_profile_data)"
  local result
  result="$(model:profile:resolve coding)"
  run jq -r 'has("extends")' <<< "$result"
  is "$output" "false"
}

@test "model:profile:resolve dies for an unknown name" {
  seed_profile_data "$(sample_profile_data)"
  run model:profile:resolve ghost
  is "$status" 1
  [[ "$output" == *"not found"* ]]
}

# ---------------------------------------------------------------------------
# model:profile:model / model:profile:extras
# ---------------------------------------------------------------------------

@test "model:profile:model returns just the model id" {
  seed_profile_data "$(sample_profile_data)"
  run model:profile:model coding
  is "$status" 0
  is "$output" "llama-3-large"
}

@test "model:profile:extras flattens params to top level" {
  seed_profile_data "$(sample_profile_data)"
  local result
  result="$(model:profile:extras coding)"
  run jq -r '.reasoning_effort' <<< "$result"
  is "$output" "medium"

  run jq -r '.temperature' <<< "$result"
  is "$output" "0.2"
}

@test "model:profile:extras keeps venice_parameters nested when non-empty" {
  seed_profile_data "$(sample_profile_data)"
  local result
  result="$(model:profile:extras coding)"
  run jq -r '.venice_parameters.include_venice_system_prompt' <<< "$result"
  is "$output" "false"
}

@test "model:profile:extras omits venice_parameters when empty" {
  seed_profile_data "$(sample_profile_data)"
  local result
  result="$(model:profile:extras smart)"
  run jq -r 'has("venice_parameters")' <<< "$result"
  is "$output" "false"
}

# ---------------------------------------------------------------------------
# model:profile:validate
# ---------------------------------------------------------------------------

# Profile validation needs both a fake profile file AND a seeded registry
# cache with capability flags we control. We use the existing seed_cache
# helper for the latter.

@test "model:profile:validate detects unknown model" {
  install_venice_curl_stub
  seed_cache
  # Profile that points at a model id NOT in the canned registry
  seed_profile_data '{"version":1,"base":{"ghost":{"model":"nonexistent-xyz","params":{}}},"variants":{}}'

  run model:profile:validate ghost
  is "$status" 1
  [[ "$output" == *"unknown model"* ]]
  [[ "$output" == *"nonexistent-xyz"* ]]
}

@test "model:profile:validate detects unsupported capability" {
  install_venice_curl_stub
  seed_cache
  # Profile uses reasoning_effort but the model (llama-3-large in the
  # canned data) has supportsReasoning=false.
  seed_profile_data '{"version":1,"base":{"reason":{"model":"llama-3-large","params":{"reasoning_effort":"medium"}}},"variants":{}}'

  run model:profile:validate reason
  is "$status" 1
  [[ "$output" == *"reasoning_effort"* ]]
  [[ "$output" == *"supportsReasoning"* ]]
}

@test "model:profile:validate succeeds when capability flags are present" {
  install_venice_curl_stub
  seed_cache
  # reasoning-small in canned_response has supportsReasoning=true
  # but lacks supportsReasoningEffort. The mapping requires BOTH, so this
  # should still fail. Use a model that has both - we need to seed a
  # custom cache for that.
  local custom_cache='{"object":"list","type":"all","data":[{"id":"full-reasoner","type":"text","object":"model","owned_by":"venice.ai","model_spec":{"name":"Full","privacy":"private","capabilities":{"supportsReasoning":true,"supportsReasoningEffort":true}}}]}'
  printf '%s\n' "$custom_cache" > "$(model:cache-path)"

  seed_profile_data '{"version":1,"base":{"deep":{"model":"full-reasoner","params":{"reasoning_effort":"high"}}},"variants":{}}'

  run model:profile:validate deep
  is "$status" 0
}

@test "model:profile:validate detects unknown profile name" {
  seed_profile_data "$(sample_profile_data)"
  run model:profile:validate ghost
  is "$status" 1
  [[ "$output" == *"not found"* ]]
}
