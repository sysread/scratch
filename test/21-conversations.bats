#!/usr/bin/env bats

# vim: set ft=bash
set -euo pipefail

#-------------------------------------------------------------------------------
# Tests for lib/conversations.sh
#
# Each test gets its own SCRATCH_PROJECTS_DIR under BATS_TEST_TMPDIR so
# tests don't interfere with each other or the user's real config.
#-------------------------------------------------------------------------------

setup() {
  SCRIPTDIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" > /dev/null 2>&1 && pwd)"
  SCRATCH_HOME="$(cd "${SCRIPTDIR}/.." && pwd)"
  source "${SCRIPTDIR}/helpers.sh"
  source "${SCRATCH_HOME}/lib/conversations.sh"

  # Isolate from real config
  export SCRATCH_CONFIG_DIR="${BATS_TEST_TMPDIR}/config"
  export SCRATCH_PROJECTS_DIR="${SCRATCH_CONFIG_DIR}/projects"
  mkdir -p "$SCRATCH_PROJECTS_DIR"

  # Create a project to hold conversations
  source "${SCRATCH_HOME}/lib/project.sh"
  project:save "testproj" "/tmp/testproj" "false"
}

# ---------------------------------------------------------------------------
# conversation:create / conversation:exists
# ---------------------------------------------------------------------------

@test "conversation:create generates a UUID slug and creates files" {
  local slug
  slug="$(conversation:create "testproj")"

  # Slug looks like a UUID (lowercase, dashes)
  [[ "$slug" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]

  # Both files exist
  local dir
  dir="$(conversation:chat-dir "testproj" "$slug")"
  [[ -f "${dir}/messages.jsonl" ]]
  [[ -f "${dir}/metadata.json" ]]
}

@test "conversation:create writes valid metadata" {
  local slug
  slug="$(conversation:create "testproj")"

  local dir
  dir="$(conversation:chat-dir "testproj" "$slug")"

  run jq -r '.slug' "${dir}/metadata.json"
  is "$output" "$slug"

  run jq -r '.rounds | length' "${dir}/metadata.json"
  is "$output" "0"

  # Timestamps are ISO8601-ish
  run jq -r '.created' "${dir}/metadata.json"
  [[ "$output" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]]
}

@test "conversation:create starts with empty messages" {
  local slug
  slug="$(conversation:create "testproj")"

  local dir
  dir="$(conversation:chat-dir "testproj" "$slug")"
  [[ ! -s "${dir}/messages.jsonl" ]]
}

@test "conversation:exists returns 0 for valid conversation" {
  local slug
  slug="$(conversation:create "testproj")"
  run conversation:exists "testproj" "$slug"
  is "$status" 0
}

@test "conversation:exists returns 1 for nonexistent slug" {
  run conversation:exists "testproj" "no-such-slug"
  is "$status" 1
}

# ---------------------------------------------------------------------------
# conversation:list
# ---------------------------------------------------------------------------

@test "conversation:list returns empty for project with no conversations" {
  run conversation:list "testproj"
  is "$status" 0
  is "$output" ""
}

@test "conversation:list returns one entry per conversation" {
  conversation:create "testproj" > /dev/null
  conversation:create "testproj" > /dev/null

  run conversation:list "testproj"
  is "$status" 0

  local count
  count="$(wc -l <<< "$output" | tr -d ' ')"
  is "$count" "2"
}

@test "conversation:list entries have expected fields" {
  local slug
  slug="$(conversation:create "testproj")"

  local line
  line="$(conversation:list "testproj")"

  run jq -r '.slug' <<< "$line"
  is "$output" "$slug"

  run jq -r '.round_count' <<< "$line"
  is "$output" "0"

  # created and updated are present
  run jq -r '.created' <<< "$line"
  [[ "$output" =~ ^[0-9]{4}- ]]

  run jq -r '.updated' <<< "$line"
  [[ "$output" =~ ^[0-9]{4}- ]]
}

# ---------------------------------------------------------------------------
# conversation:append-message / conversation:load-messages
# ---------------------------------------------------------------------------

@test "conversation:append-message adds a line and updates timestamp" {
  local slug
  slug="$(conversation:create "testproj")"

  local msg='{"role":"user","content":"hello"}'
  conversation:append-message "testproj" "$slug" "$msg"

  local dir
  dir="$(conversation:chat-dir "testproj" "$slug")"

  # One line in messages.jsonl
  local count
  count="$(wc -l < "${dir}/messages.jsonl" | tr -d ' ')"
  is "$count" "1"

  # Content matches
  run jq -r '.content' "${dir}/messages.jsonl"
  is "$output" "hello"
}

@test "conversation:load-messages returns all messages" {
  local slug
  slug="$(conversation:create "testproj")"

  conversation:append-message "testproj" "$slug" '{"role":"user","content":"one"}'
  conversation:append-message "testproj" "$slug" '{"role":"assistant","content":"two"}'

  run conversation:load-messages "testproj" "$slug"
  is "$status" 0

  local count
  count="$(wc -l <<< "$output" | tr -d ' ')"
  is "$count" "2"
}

@test "conversation:load-messages dies for nonexistent conversation" {
  run bash -c 'set -e; source '"${SCRATCH_HOME}"'/lib/conversations.sh; export SCRATCH_PROJECTS_DIR='"${SCRATCH_PROJECTS_DIR}"'; conversation:load-messages "testproj" "nope" 2>&1'
  is "$status" 1
  [[ "$output" == *"conversation not found"* ]]
}

# ---------------------------------------------------------------------------
# conversation:messages-as-array
# ---------------------------------------------------------------------------

@test "conversation:messages-as-array returns empty array for new conversation" {
  local slug
  slug="$(conversation:create "testproj")"

  run conversation:messages-as-array "testproj" "$slug"
  is "$status" 0
  is "$output" "[]"
}

@test "conversation:messages-as-array returns valid JSON array" {
  local slug
  slug="$(conversation:create "testproj")"

  conversation:append-message "testproj" "$slug" '{"role":"user","content":"hi"}'
  conversation:append-message "testproj" "$slug" '{"role":"assistant","content":"hello"}'

  local arr
  arr="$(conversation:messages-as-array "testproj" "$slug")"

  run jq 'length' <<< "$arr"
  is "$output" "2"

  run jq -r '.[0].role' <<< "$arr"
  is "$output" "user"

  run jq -r '.[1].content' <<< "$arr"
  is "$output" "hello"
}

# ---------------------------------------------------------------------------
# conversation:delete
# ---------------------------------------------------------------------------

@test "conversation:delete removes the conversation directory" {
  local slug
  slug="$(conversation:create "testproj")"

  conversation:delete "testproj" "$slug"
  run conversation:exists "testproj" "$slug"
  is "$status" 1
}

@test "conversation:delete dies for nonexistent conversation" {
  run bash -c 'set -e; source '"${SCRATCH_HOME}"'/lib/conversations.sh; export SCRATCH_PROJECTS_DIR='"${SCRATCH_PROJECTS_DIR}"'; conversation:delete "testproj" "nope" 2>&1'
  is "$status" 1
  [[ "$output" == *"conversation not found"* ]]
}

# ---------------------------------------------------------------------------
# Round tracking
# ---------------------------------------------------------------------------

@test "conversation:begin-round adds a round with null size" {
  local slug
  slug="$(conversation:create "testproj")"

  conversation:append-message "testproj" "$slug" '{"role":"user","content":"hi"}'
  conversation:begin-round "testproj" "$slug"

  local meta
  meta="$(conversation:load-metadata "testproj" "$slug")"

  run jq '.rounds | length' <<< "$meta"
  is "$output" "1"

  run jq '.rounds[0].start' <<< "$meta"
  is "$output" "1"

  run jq '.rounds[0].size' <<< "$meta"
  is "$output" "null"
}

@test "conversation:end-round computes correct size" {
  local slug
  slug="$(conversation:create "testproj")"

  # Simulate a round: user sends, then assistant replies
  conversation:begin-round "testproj" "$slug"
  conversation:append-message "testproj" "$slug" '{"role":"user","content":"hi"}'
  conversation:append-message "testproj" "$slug" '{"role":"assistant","content":"hello"}'
  conversation:end-round "testproj" "$slug"

  local meta
  meta="$(conversation:load-metadata "testproj" "$slug")"

  run jq '.rounds[0].start' <<< "$meta"
  is "$output" "0"

  run jq '.rounds[0].size' <<< "$meta"
  is "$output" "2"
}

@test "multiple rounds accumulate correctly" {
  local slug
  slug="$(conversation:create "testproj")"

  # Round 1
  conversation:begin-round "testproj" "$slug"
  conversation:append-message "testproj" "$slug" '{"role":"user","content":"first"}'
  conversation:append-message "testproj" "$slug" '{"role":"assistant","content":"reply1"}'
  conversation:end-round "testproj" "$slug"

  # Round 2
  conversation:begin-round "testproj" "$slug"
  conversation:append-message "testproj" "$slug" '{"role":"user","content":"second"}'
  conversation:append-message "testproj" "$slug" '{"role":"assistant","content":"reply2"}'
  conversation:end-round "testproj" "$slug"

  local meta
  meta="$(conversation:load-metadata "testproj" "$slug")"

  run jq '.rounds | length' <<< "$meta"
  is "$output" "2"

  run jq '.rounds[0].start' <<< "$meta"
  is "$output" "0"

  run jq '.rounds[0].size' <<< "$meta"
  is "$output" "2"

  run jq '.rounds[1].start' <<< "$meta"
  is "$output" "2"

  run jq '.rounds[1].size' <<< "$meta"
  is "$output" "2"
}

# ---------------------------------------------------------------------------
# conversation:update-metadata
# ---------------------------------------------------------------------------

@test "conversation:update-metadata applies jq expression atomically" {
  local slug
  slug="$(conversation:create "testproj")"

  conversation:update-metadata "testproj" "$slug" '. + {custom: "value"}'

  local meta
  meta="$(conversation:load-metadata "testproj" "$slug")"

  run jq -r '.custom' <<< "$meta"
  is "$output" "value"

  # Updated timestamp was refreshed
  run jq -r '.updated' <<< "$meta"
  [[ "$output" =~ ^[0-9]{4}- ]]
}

# ---------------------------------------------------------------------------
# conversation:chats-dir / conversation:chat-dir
# ---------------------------------------------------------------------------

@test "conversation:chats-dir creates directory if missing" {
  local dir
  dir="$(conversation:chats-dir "testproj")"
  [[ -d "$dir" ]]
  [[ "$dir" == *"/testproj/chats" ]]
}

@test "conversation:chat-dir returns expected path" {
  local dir
  dir="$(conversation:chat-dir "testproj" "abc-123")"
  [[ "$dir" == *"/testproj/chats/abc-123" ]]
}
