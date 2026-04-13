#!/usr/bin/env bash

#-------------------------------------------------------------------------------
# Conversation persistence library
#
# Manages multi-turn chat conversations stored as flat files under each
# project's config directory:
#
#   ~/.config/scratch/projects/<project>/chats/<slug>/
#     messages.jsonl     one JSON message object per line (OpenAI format)
#     metadata.json      timestamps and rounds tracking
#
# The messages.jsonl file is append-only during a conversation. Metadata
# is updated atomically (write to tmp, then mv) on each mutation.
#
# Rounds track logical user-assistant exchanges. Each round records its
# starting line offset in messages.jsonl and the number of messages in
# the exchange. A null size means the round is in progress (user message
# saved, awaiting LLM response). Tool call cycles within a single round
# are counted in the size but do not create additional rounds.
#
# This library handles persistence only. The Venice API layer lives in
# lib/chat.sh; bin/scratch-chat orchestrates completions and tool
# calling. This library calls neither - it is pure file I/O.
#
# Deferred (v2):
#   - Venice per-message metadata field for tagging app-injected
#     messages. When added, chats show and the resume display should
#     filter these out unless --verbose is passed.
#-------------------------------------------------------------------------------

[[ "${_INCLUDED_CONVERSATIONS:-}" == "1" ]] && return 0
_INCLUDED_CONVERSATIONS=1

_CONVERSATIONS_SCRIPTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source-path=SCRIPTDIR/lib
# shellcheck disable=SC1091
{
  source "$_CONVERSATIONS_SCRIPTDIR/base.sh"
  source "$_CONVERSATIONS_SCRIPTDIR/project.sh"
}

has-commands jq uuidgen

#-------------------------------------------------------------------------------
# conversation:chats-dir PROJECT
#
# Print the chats directory path for a project. Creates the directory if
# it does not already exist.
#-------------------------------------------------------------------------------
conversation:chats-dir() {
  local project="$1"
  local dir="${SCRATCH_PROJECTS_DIR}/${project}/chats"
  mkdir -p "$dir"
  printf '%s\n' "$dir"
}

export -f conversation:chats-dir

#-------------------------------------------------------------------------------
# conversation:chat-dir PROJECT SLUG
#
# Print the path to a specific conversation's directory. Does not create
# it - that is conversation:create's job.
#-------------------------------------------------------------------------------
conversation:chat-dir() {
  local project="$1"
  local slug="$2"
  printf '%s\n' "${SCRATCH_PROJECTS_DIR}/${project}/chats/${slug}"
}

export -f conversation:chat-dir

#-------------------------------------------------------------------------------
# conversation:create PROJECT
#
# Start a new conversation. Generates a UUID slug, creates the directory,
# initializes empty messages.jsonl and metadata.json with timestamps and
# an empty rounds array. Prints the slug to stdout.
#-------------------------------------------------------------------------------
conversation:create() {
  local project="$1"
  local slug
  slug="$(uuidgen | tr '[:upper:]' '[:lower:]')"

  _conversation:init-dir "$project" "$slug"
  printf '%s\n' "$slug"
}

export -f conversation:create

#-------------------------------------------------------------------------------
# conversation:create-with-slug PROJECT SLUG
#
# Like conversation:create but uses a caller-provided slug instead of
# generating one. Used for deferred creation where the slug is chosen
# early (for display) but the files are created later (on first message).
#-------------------------------------------------------------------------------
conversation:create-with-slug() {
  local project="$1"
  local slug="$2"

  _conversation:init-dir "$project" "$slug"
}

export -f conversation:create-with-slug

#-------------------------------------------------------------------------------
# _conversation:init-dir PROJECT SLUG
#
# (Private) Create the conversation directory, empty messages.jsonl, and
# initial metadata.json. Shared by conversation:create and
# conversation:create-with-slug.
#-------------------------------------------------------------------------------
_conversation:init-dir() {
  local project="$1"
  local slug="$2"

  local chats_dir
  chats_dir="$(conversation:chats-dir "$project")"

  local chat_dir="${chats_dir}/${slug}"
  mkdir -p "$chat_dir"

  # Empty message log
  : > "${chat_dir}/messages.jsonl"

  # Initial metadata with timestamps and empty rounds
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  jq -c -n \
    --arg slug "$slug" \
    --arg created "$now" \
    --arg updated "$now" \
    '{slug: $slug, created: $created, updated: $updated, rounds: []}' \
    > "${chat_dir}/metadata.json"
}

export -f _conversation:init-dir

#-------------------------------------------------------------------------------
# conversation:exists PROJECT SLUG
#
# Return 0 if the conversation directory contains both messages.jsonl and
# metadata.json, 1 otherwise.
#-------------------------------------------------------------------------------
conversation:exists() {
  local project="$1"
  local slug="$2"
  local dir
  dir="$(conversation:chat-dir "$project" "$slug")"
  [[ -f "${dir}/messages.jsonl" && -f "${dir}/metadata.json" ]]
}

export -f conversation:exists

#-------------------------------------------------------------------------------
# conversation:list PROJECT
#
# Print JSONL to stdout with one object per conversation:
#   {slug, created, updated, round_count}
#
# Sorted by updated timestamp descending (most recent first).
# Returns 0 with no output if the project has no conversations.
#-------------------------------------------------------------------------------
conversation:list() {
  local project="$1"
  local chats_dir="${SCRATCH_PROJECTS_DIR}/${project}/chats"

  [[ -d "$chats_dir" ]] || return 0

  local dir

  for dir in "$chats_dir"/*/; do
    [[ -d "$dir" ]] || continue
    [[ -f "${dir}/metadata.json" ]] || continue

    jq -c '{slug: .slug, created: .created, updated: .updated, round_count: (.rounds | length)}' \
      < "${dir}/metadata.json"
  done | jq -s -c 'sort_by(.updated) | reverse | .[]'

  return 0
}

export -f conversation:list

#-------------------------------------------------------------------------------
# conversation:load-messages PROJECT SLUG
#
# Print the raw contents of messages.jsonl to stdout (one JSON object per
# line). Dies if the conversation does not exist.
#-------------------------------------------------------------------------------
conversation:load-messages() {
  local project="$1"
  local slug="$2"
  local dir
  dir="$(conversation:chat-dir "$project" "$slug")"

  if [[ ! -f "${dir}/messages.jsonl" ]]; then
    die "conversation not found: ${project}/${slug}"
    return 1
  fi

  cat "${dir}/messages.jsonl"
}

export -f conversation:load-messages

#-------------------------------------------------------------------------------
# conversation:messages-as-array PROJECT SLUG
#
# Print all messages as a JSON array (the format chat:completion expects).
# An empty conversation produces an empty array [].
#-------------------------------------------------------------------------------
conversation:messages-as-array() {
  local project="$1"
  local slug="$2"
  local dir
  dir="$(conversation:chat-dir "$project" "$slug")"

  if [[ ! -f "${dir}/messages.jsonl" ]]; then
    die "conversation not found: ${project}/${slug}"
    return 1
  fi

  local messages_file="${dir}/messages.jsonl"

  # Empty file produces empty array; -s slurps lines into array
  if [[ ! -s "$messages_file" ]]; then
    printf '[]'
  else
    jq -s '.' < "$messages_file"
  fi
}

export -f conversation:messages-as-array

#-------------------------------------------------------------------------------
# conversation:append-message PROJECT SLUG MESSAGE_JSON
#
# Append a single message to messages.jsonl and update the metadata
# timestamp. MESSAGE_JSON must be a compact single-line JSON object.
#-------------------------------------------------------------------------------
conversation:append-message() {
  local project="$1"
  local slug="$2"
  local message="$3"
  local dir
  dir="$(conversation:chat-dir "$project" "$slug")"

  if [[ ! -f "${dir}/messages.jsonl" ]]; then
    die "conversation not found: ${project}/${slug}"
    return 1
  fi

  printf '%s\n' "$message" >> "${dir}/messages.jsonl"

  _conversation:touch-metadata "$project" "$slug"
}

export -f conversation:append-message

#-------------------------------------------------------------------------------
# conversation:load-metadata PROJECT SLUG
#
# Print the raw metadata.json to stdout.
#-------------------------------------------------------------------------------
conversation:load-metadata() {
  local project="$1"
  local slug="$2"
  local dir
  dir="$(conversation:chat-dir "$project" "$slug")"

  if [[ ! -f "${dir}/metadata.json" ]]; then
    die "conversation not found: ${project}/${slug}"
    return 1
  fi

  cat "${dir}/metadata.json"
}

export -f conversation:load-metadata

#-------------------------------------------------------------------------------
# conversation:update-metadata PROJECT SLUG JQ_EXPR
#
# Read metadata.json, pipe through jq with the given expression, and
# write back atomically (tmp file + mv). Also updates the "updated"
# timestamp.
#-------------------------------------------------------------------------------
conversation:update-metadata() {
  local project="$1"
  local slug="$2"
  local jq_expr="$3"
  local dir
  dir="$(conversation:chat-dir "$project" "$slug")"

  local meta_path="${dir}/metadata.json"
  if [[ ! -f "$meta_path" ]]; then
    die "conversation not found: ${project}/${slug}"
    return 1
  fi

  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  local tmp_path="${dir}/.metadata.json.tmp"
  jq -c --arg now "$now" "${jq_expr} | .updated = \$now" < "$meta_path" > "$tmp_path"
  mv "$tmp_path" "$meta_path"
}

export -f conversation:update-metadata

#-------------------------------------------------------------------------------
# conversation:delete PROJECT SLUG
#
# Remove a conversation's directory entirely.
#-------------------------------------------------------------------------------
conversation:delete() {
  local project="$1"
  local slug="$2"
  local dir
  dir="$(conversation:chat-dir "$project" "$slug")"

  if [[ ! -d "$dir" ]]; then
    die "conversation not found: ${project}/${slug}"
    return 1
  fi

  rm -rf "$dir"
}

export -f conversation:delete

#-------------------------------------------------------------------------------
# conversation:begin-round PROJECT SLUG
#
# Start a new round. Reads the current message count from messages.jsonl
# and appends a round entry with {start: <count>, size: null} to the
# metadata rounds array. The null size signals "round in progress."
#-------------------------------------------------------------------------------
conversation:begin-round() {
  local project="$1"
  local slug="$2"
  local dir
  dir="$(conversation:chat-dir "$project" "$slug")"

  local count
  count="$(_conversation:message-count "$dir")"

  conversation:update-metadata "$project" "$slug" \
    ".rounds += [{start: ${count}, size: null}]"
}

export -f conversation:begin-round

#-------------------------------------------------------------------------------
# conversation:end-round PROJECT SLUG
#
# Finalize the current round. Computes the size as (current message count
# minus round start) and replaces the null size in the last round entry.
#-------------------------------------------------------------------------------
conversation:end-round() {
  local project="$1"
  local slug="$2"
  local dir
  dir="$(conversation:chat-dir "$project" "$slug")"

  local count
  count="$(_conversation:message-count "$dir")"

  conversation:update-metadata "$project" "$slug" \
    ".rounds[-1].size = (${count} - .rounds[-1].start)"
}

export -f conversation:end-round

#-------------------------------------------------------------------------------
# conversation:build-message ROLE CONTENT
#
# Print a compact JSON message object to stdout. Convenience wrapper so
# callers don't need to hand-roll jq for the common {role, content} shape.
#-------------------------------------------------------------------------------
conversation:build-message() {
  local role="$1"
  local content="$2"
  jq -c -n --arg role "$role" --arg content "$content" \
    '{role: $role, content: $content}'
}

export -f conversation:build-message

#-------------------------------------------------------------------------------
# conversation:rewrite PROJECT SLUG MESSAGES_ARRAY_JSON
#
# Replace the entire messages.jsonl file with the given JSON array.
# Used after a tool-calling round where intermediate messages (assistant
# tool_calls + tool results) were appended to an in-memory array and
# need to be flushed to disk. Write is atomic (tmp + mv).
#-------------------------------------------------------------------------------
conversation:rewrite() {
  local project="$1"
  local slug="$2"
  local messages_json="$3"
  local dir
  dir="$(conversation:chat-dir "$project" "$slug")"

  if [[ ! -d "$dir" ]]; then
    die "conversation not found: ${project}/${slug}"
    return 1
  fi

  jq -c '.[]' <<< "$messages_json" > "${dir}/.messages.jsonl.tmp"
  mv "${dir}/.messages.jsonl.tmp" "${dir}/messages.jsonl"
}

export -f conversation:rewrite

#-------------------------------------------------------------------------------
# Internal helpers
#-------------------------------------------------------------------------------

# _conversation:message-count DIR
#
# Print the number of lines in messages.jsonl. Returns 0 for an empty file.
_conversation:message-count() {
  local dir="$1"
  local file="${dir}/messages.jsonl"

  if [[ ! -s "$file" ]]; then
    printf '0'
  else
    wc -l < "$file" | tr -d ' '
  fi
}

# _conversation:touch-metadata PROJECT SLUG
#
# Update the "updated" timestamp in metadata.json without changing
# anything else. Uses the same atomic write pattern.
_conversation:touch-metadata() {
  local project="$1"
  local slug="$2"

  conversation:update-metadata "$project" "$slug" "."
}
