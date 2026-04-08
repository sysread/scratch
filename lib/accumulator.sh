#!/usr/bin/env bash

#-------------------------------------------------------------------------------
# Accumulator completions
#
# Process inputs that exceed a model's context window by chunking the input,
# running a sequence of completions that build up a structured `notes` value,
# then a final cleanup pass over the accumulated state. The chunk-by-chunk
# response is constrained via response_format (json_schema), so the buffer
# is durable structured data instead of free-form prose the next round has
# to re-parse out of context.
#
# This file currently holds only the pure text-handling layer:
#   _accumulate:_token-count        approximate tokens via chars / chars_per_token
#   _accumulate:_max-chars          floor(max_tokens * chars_per_token * fraction)
#   _accumulate:_split              line-aware pre-split into numbered chunk files
#   _accumulate:_inject-line-numbers prefix every line with <n>:<hash>|<content>
#
# The chat-layer wrappers (chat:completion driver, reduce loop, public
# accumulate:run / accumulate:run-profile entry points) land in a follow-up
# commit. The text helpers ship first because they need no model awareness
# and can be tested in isolation.
#
# Token approximation: bash has no real tokenizer, so we estimate via
# (chars / chars_per_token) where chars_per_token is a per-profile float
# stored on the model profile (default 4.0). See data/models.md for the
# field's rationale and defaults.
#-------------------------------------------------------------------------------

[[ "${_INCLUDED_ACCUMULATOR:-}" == "1" ]] && return 0
_INCLUDED_ACCUMULATOR=1

_ACCUMULATOR_SCRIPTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source-path=SCRIPTDIR/lib
# shellcheck disable=SC1091
{
  source "$_ACCUMULATOR_SCRIPTDIR/base.sh"
  source "$_ACCUMULATOR_SCRIPTDIR/tempfiles.sh"
}

has-commands bc awk shasum

#-------------------------------------------------------------------------------
# _accumulate:_token-count TEXT_OR_FILE CHARS_PER_TOKEN
#
# (Private) Estimate token count for a text by dividing its character
# count by CHARS_PER_TOKEN, rounded up. The first argument may be either
# a literal string or a file path; auto-detected via [[ -f ]].
#
# Uses bc -l because bash has no floating-point support and the divisor
# is a fractional float. Same scale-and-ceiling trick already used in
# _venice:_backoff-seconds.
#
# A 1-character input with the default 4.0 ratio returns 1, not 0 - the
# ceiling is intentional so callers always reserve at least one token
# for non-empty content.
#-------------------------------------------------------------------------------
_accumulate:_token-count() {
  local input="$1"
  local cpt="$2"
  local chars

  if [[ -f "$input" ]]; then
    chars="$(wc -c < "$input" | tr -d '[:space:]')"
  else
    chars="${#input}"
  fi

  # Empty input is 0 tokens, not 1.
  ((chars == 0)) && {
    printf '0'
    return 0
  }

  bc -l << EOF
scale = 4
raw = $chars / $cpt
scale = 0
(raw + 0.9999) / 1
EOF
}

#-------------------------------------------------------------------------------
# _accumulate:_max-chars MAX_TOKENS CHARS_PER_TOKEN FRACTION
#
# (Private) Compute the integer character budget for a chunk:
#
#   floor(max_tokens * chars_per_token * fraction)
#
# All three inputs may be fractional; the output is a whole number of
# characters because file offsets and string lengths are integer.
#
# FRACTION is the conservative pre-split ratio (typically 0.7) that
# leaves headroom for the system prompt and the accumulated buffer.
# Reactive backoff drops it further on context overflow; see the parent
# accumulator design doc for the shave-and-retry rationale.
#-------------------------------------------------------------------------------
_accumulate:_max-chars() {
  local max_tokens="$1"
  local cpt="$2"
  local fraction="$3"

  bc -l << EOF
scale = 4
raw = $max_tokens * $cpt * $fraction
scale = 0
raw / 1
EOF
}

#-------------------------------------------------------------------------------
# _accumulate:_split INPUT_FILE MAX_CHARS OUT_DIR
#
# (Private) Pre-split INPUT_FILE into numbered files (0001, 0002, ...)
# under OUT_DIR. Line-aware: walks the input line by line, accumulating
# lines into the current chunk until adding another would exceed
# MAX_CHARS. Then closes the chunk and starts a new one.
#
# A single line longer than MAX_CHARS gets its own chunk (no truncation).
# The reduce loop will see that chunk and either succeed against the
# model anyway, or trigger context-overflow backoff which can shave the
# fraction further until the chunk fits or hits the floor.
#
# Empty input produces zero output files - the for loop in the reduce
# layer guards via [[ -f ]] so this falls through cleanly.
#
# Handles input that does not end with a newline via the standard
# `|| [[ -n "$line" ]]` trick on the read loop.
#
# Line-number injection (_accumulate:_inject-line-numbers) must happen
# BEFORE this function is called, not after - otherwise chunk boundaries
# could split a numbered line in half and break the prefix format.
#-------------------------------------------------------------------------------
_accumulate:_split() {
  local input_file="$1"
  local max_chars="$2"
  local out_dir="$3"

  mkdir -p "$out_dir"

  local chunk_num=0
  local chunk_path=""
  local chunk_size=0
  local line
  local line_size

  while IFS= read -r line || [[ -n "$line" ]]; do
    line_size=$((${#line} + 1)) # +1 for the newline we re-emit

    # Open the first chunk lazily so empty input produces zero files.
    if [[ -z "$chunk_path" ]]; then
      chunk_num=1
      chunk_path="$(printf '%s/%04d' "$out_dir" "$chunk_num")"
      : > "$chunk_path"
      chunk_size=0
    fi

    # Roll over to a new chunk if adding this line would overflow,
    # unless the current chunk is empty (in which case the line is
    # oversized on its own and gets the chunk to itself - splitting it
    # would corrupt content).
    if ((chunk_size > 0 && chunk_size + line_size > max_chars)); then
      chunk_num=$((chunk_num + 1))
      chunk_path="$(printf '%s/%04d' "$out_dir" "$chunk_num")"
      : > "$chunk_path"
      chunk_size=0
    fi

    printf '%s\n' "$line" >> "$chunk_path"
    chunk_size=$((chunk_size + line_size))
  done < "$input_file"
}

#-------------------------------------------------------------------------------
# _accumulate:_inject-line-numbers INPUT_FILE OUT_FILE
#
# (Private) Transform every line of INPUT_FILE into the format:
#
#   <line_number>:<content_hash>|<content>
#
# Line numbers are 1-based and sequential. The content hash is the first
# 8 hex chars of shasum -a 256 over the original line content (no newline).
# Eight chars is enough to disambiguate lines for downstream edit tooling
# without bloating token usage.
#
# The hash is stable across identical content - two lines with the same
# text get the same hash, by design. Downstream agents use the hash to
# verify a line's identity at edit time even if the user shifted line
# numbers around between rounds.
#
# Handles input that does not end with a newline (last partial line is
# still emitted with the prefix).
#
# Used by accumulate:run when line_numbers mode is enabled. Must run
# BEFORE _accumulate:_split so chunk boundaries fall on numbered-line
# boundaries.
#-------------------------------------------------------------------------------
_accumulate:_inject-line-numbers() {
  local input_file="$1"
  local out_file="$2"
  local n=0
  local line
  local hash

  : > "$out_file"
  while IFS= read -r line || [[ -n "$line" ]]; do
    n=$((n + 1))
    hash="$(printf '%s' "$line" | shasum -a 256 | cut -c1-8)"
    printf '%s:%s|%s\n' "$n" "$hash" "$line" >> "$out_file"
  done < "$input_file"
}
