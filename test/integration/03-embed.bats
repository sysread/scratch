#!/usr/bin/env bats

# vim: set ft=bash
set -euo pipefail

#-------------------------------------------------------------------------------
# Integration tests for lib/embed.sh - REAL LOCAL MODEL
#
# These exercise the Bumblebee/EXLA embedding pipeline against the real
# all-MiniLM-L12-v2 model. They download the model on first run (~134MB)
# and cache it under the test HOME. Subsequent runs use the cache.
#
# Run via `mise run test:integration` or `helpers/run-integration-tests`.
#-------------------------------------------------------------------------------

setup() {
  SCRIPTDIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" > /dev/null 2>&1 && pwd)"
  SCRATCH_HOME="$(cd "${SCRIPTDIR}/../.." && pwd)"
  source "${SCRIPTDIR}/../helpers.sh"
  source "${SCRATCH_HOME}/lib/embed.sh"

  export HOME="${BATS_TEST_TMPDIR}/home"
  mkdir -p "$HOME"
}

@test "embed:text produces a 384-dimensional vector" {
  local output
  output="$(embed:text "hello world" 2> /dev/null)"

  local dim
  dim="$(printf '%s' "$output" | jq 'length')"
  is "$dim" "384"

  # Values should be floats, not nulls
  local first
  first="$(printf '%s' "$output" | jq '.[0] | type')"
  is "$first" '"number"'
}

@test "embed:pool processes JSONL and returns embeddings" {
  local output
  output="$(printf '{"id":"a","text":"hello world"}\n{"id":"b","text":"goodbye"}\n' \
    | embed:pool 2 2> /dev/null)"

  # Should have 2 lines
  local count
  count="$(printf '%s\n' "$output" | wc -l | tr -d ' ')"
  is "$count" "2"

  # Each line should have id and 384-dim embedding
  local dim_a dim_b
  dim_a="$(printf '%s\n' "$output" | jq -s '.[0].embedding | length')"
  dim_b="$(printf '%s\n' "$output" | jq -s '.[1].embedding | length')"
  is "$dim_a" "384"
  is "$dim_b" "384"
}

@test "embed:pool exits cleanly when stdin closes" {
  local output
  output="$(printf '{"id":"1","text":"test"}\n' | embed:pool 2 2> /dev/null)"

  # Should produce one result and exit
  local id
  id="$(printf '%s' "$output" | jq -r '.id')"
  is "$id" "1"

  # No orphaned elixir process
  ! pgrep -f "embed.exs.*-n" || {
    echo "orphaned embed.exs process found"
    return 1
  }
}
