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
  source "$_ACCUMULATOR_SCRIPTDIR/prompt.sh"
  source "$_ACCUMULATOR_SCRIPTDIR/chat.sh"
  source "$_ACCUMULATOR_SCRIPTDIR/model.sh"
}

has-commands bc awk shasum jq

#-------------------------------------------------------------------------------
# Structured-output schemas
#
# Both schemas use OpenAI-compatible json_schema format. Venice accepts the
# same shape. strict:true tells the model to refuse to generate output that
# violates the schema, which gives the accumulator durable structured state
# instead of a free-form buffer the next round has to re-parse.
#
# Field names are deliberately verbose ("current_chunk", "accumulated_notes",
# "result") because the model has no shared context with scratch and short
# names ("buffer", "out") would be ambiguous on first read.
#-------------------------------------------------------------------------------
_ACCUMULATOR_ROUND_SCHEMA='{
  "type": "json_schema",
  "json_schema": {
    "name": "accumulator_round",
    "strict": true,
    "schema": {
      "type": "object",
      "additionalProperties": false,
      "required": ["current_chunk", "accumulated_notes"],
      "properties": {
        "current_chunk": {
          "type": "string",
          "description": "A brief one-sentence acknowledgement of what was just processed."
        },
        "accumulated_notes": {
          "type": "string",
          "description": "The running structured-or-prose state being built up across rounds. Will be fed back as input on the next round."
        }
      }
    }
  }
}'

_ACCUMULATOR_FINAL_SCHEMA='{
  "type": "json_schema",
  "json_schema": {
    "name": "accumulator_final",
    "strict": true,
    "schema": {
      "type": "object",
      "additionalProperties": false,
      "required": ["result"],
      "properties": {
        "result": {
          "type": "string",
          "description": "The final user-facing answer assembled from accumulated_notes."
        }
      }
    }
  }
}'

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

#-------------------------------------------------------------------------------
# _accumulate:_build-round-system-prompt USER_PROMPT QUESTION NOTES LINE_NUMBERS
#
# (Private) Render the per-chunk system prompt by loading the
# accumulator/system.md template and substituting the three placeholder
# variables. If LINE_NUMBERS is "true", the line-numbers prompt section
# is appended.
#-------------------------------------------------------------------------------
_accumulate:_build-round-system-prompt() {
  local user_prompt="$1"
  local question="$2"
  local notes="$3"
  local line_numbers="$4"
  local rendered

  rendered="$(prompt:render accumulator/system \
    "user_prompt=$user_prompt" \
    "question=$question" \
    "notes=$notes")" || return 1

  if [[ "$line_numbers" == "true" ]]; then
    local ln_section
    ln_section="$(prompt:load accumulator/line-numbers)" || return 1
    rendered="${rendered}"$'\n\n'"${ln_section}"
  fi

  printf '%s' "$rendered"
}

#-------------------------------------------------------------------------------
# _accumulate:_build-final-system-prompt USER_PROMPT QUESTION NOTES
#
# (Private) Render the finalize system prompt by loading the
# accumulator/finalize.md template and substituting the three placeholder
# variables.
#-------------------------------------------------------------------------------
_accumulate:_build-final-system-prompt() {
  local user_prompt="$1"
  local question="$2"
  local notes="$3"

  prompt:render accumulator/finalize \
    "user_prompt=$user_prompt" \
    "question=$question" \
    "notes=$notes"
}

#-------------------------------------------------------------------------------
# _accumulate:_merge-extras EXTRAS SCHEMA
#
# (Private) Merge a structured-output response_format into the caller's
# extras object. The schema (round or final) goes under .response_format.
# If the caller already supplied a response_format, override it - the
# accumulator's contract trumps the caller - and warn so the caller knows
# their request was modified.
#-------------------------------------------------------------------------------
_accumulate:_merge-extras() {
  local extras="$1"
  local schema="$2"

  [[ -n "$extras" ]] || extras='{}'

  if jq -e 'has("response_format")' <<< "$extras" > /dev/null 2>&1; then
    warn "accumulator: overriding caller-supplied response_format with the accumulator's schema"
  fi

  jq -c --argjson schema "$schema" '. + {response_format: $schema}' <<< "$extras"
}

#-------------------------------------------------------------------------------
# _accumulate:_process-chunk MODEL USER_PROMPT QUESTION NOTES CHUNK_FILE EXTRAS LINE_NUMBERS
#
# (Private) Run one accumulator round. Builds the messages array (system
# prompt with rendered placeholders, user message with the chunk content),
# calls chat:completion with the round schema in extras, parses the model's
# response for accumulated_notes, and prints just that field on stdout.
#
# Returns the chat:completion exit code on failure. In particular, exit
# code 9 (context overflow from venice:curl) is passed through so the
# caller can drive the shave-and-retry backoff loop.
#-------------------------------------------------------------------------------
_accumulate:_process-chunk() {
  local model="$1"
  local user_prompt="$2"
  local question="$3"
  local notes="$4"
  local chunk_file="$5"
  local extras="$6"
  local line_numbers="$7"

  local system_prompt
  system_prompt="$(_accumulate:_build-round-system-prompt "$user_prompt" "$question" "$notes" "$line_numbers")" || return 1

  local chunk_content
  chunk_content="$(cat "$chunk_file")"

  local messages
  messages="$(jq -c -n \
    --arg system "$system_prompt" \
    --arg user "$chunk_content" \
    '[{role:"system",content:$system},{role:"user",content:$user}]')"

  local merged_extras
  merged_extras="$(_accumulate:_merge-extras "$extras" "$_ACCUMULATOR_ROUND_SCHEMA")"

  local response
  local rc
  response="$(chat:completion "$model" "$messages" "$merged_extras")"
  rc=$?
  ((rc == 0)) || return "$rc"

  # The model returns the response_format as a JSON string in
  # .choices[0].message.content. Parse twice: once to extract the
  # content string, once to read accumulated_notes from inside it.
  printf '%s' "$response" | jq -r '.choices[0].message.content | fromjson | .accumulated_notes'
}

#-------------------------------------------------------------------------------
# _accumulate:_finalize MODEL USER_PROMPT QUESTION NOTES EXTRAS
#
# (Private) Run the cleanup pass after all chunks have been processed.
# Builds the finalize system prompt, sends an empty user message (the
# notes are already in the system prompt), parses the model's response
# for the .result field, and prints it on stdout as plain text.
#
# Unlike round responses, finalize is allowed to return whatever format
# the user's prompt requested - the schema only constrains the wrapper
# field, not the content of .result itself.
#-------------------------------------------------------------------------------
_accumulate:_finalize() {
  local model="$1"
  local user_prompt="$2"
  local question="$3"
  local notes="$4"
  local extras="$5"

  local system_prompt
  system_prompt="$(_accumulate:_build-final-system-prompt "$user_prompt" "$question" "$notes")" || return 1

  local messages
  messages="$(jq -c -n \
    --arg system "$system_prompt" \
    '[{role:"system",content:$system},{role:"user",content:"Produce the final answer."}]')"

  local merged_extras
  merged_extras="$(_accumulate:_merge-extras "$extras" "$_ACCUMULATOR_FINAL_SCHEMA")"

  local response
  response="$(chat:completion "$model" "$messages" "$merged_extras")" || return 1

  printf '%s' "$response" | jq -r '.choices[0].message.content | fromjson | .result'
}

#-------------------------------------------------------------------------------
# _accumulate:_process-chunk-with-backoff MODEL USER_PROMPT QUESTION NOTES
#                                          CHUNK_FILE EXTRAS LINE_NUMBERS
#                                          MAX_TOKENS CHARS_PER_TOKEN
#                                          START_FRACTION FLOOR_FRACTION BACKOFF_STEP
#
# (Private) Wrap _accumulate:_process-chunk with the per-chunk shave-10%
# backoff loop. On context-overflow (exit code 9 from venice:curl bubbling
# through chat:completion), re-split THIS chunk at a smaller fraction and
# process the resulting sub-chunks sequentially against the same notes.
#
# Recurses through the sub-chunks: each sub-chunk gets its own backoff
# attempt at the further-shaved fraction. Bottoms out when the fraction
# drops below FLOOR_FRACTION and we still hit overflow - dies with a clear
# message identifying the failing chunk.
#
# The backoff fraction is reset by the OUTER reduce loop on the next
# (parent) chunk; this function does not carry the smaller fraction
# forward across sibling chunks.
#-------------------------------------------------------------------------------
_accumulate:_process-chunk-with-backoff() {
  local model="$1"
  local user_prompt="$2"
  local question="$3"
  local notes="$4"
  local chunk_file="$5"
  local extras="$6"
  local line_numbers="$7"
  local max_tokens="$8"
  local cpt="$9"
  local fraction="${10}"
  local floor="${11}"
  local step="${12}"

  local result
  local rc
  result="$(_accumulate:_process-chunk "$model" "$user_prompt" "$question" "$notes" "$chunk_file" "$extras" "$line_numbers")"
  rc=$?

  if ((rc == 0)); then
    printf '%s' "$result"
    return 0
  fi

  if ((rc != 9)); then
    return "$rc"
  fi

  # Context overflow. Compute the shaved fraction; if it walks the floor,
  # die loudly so the caller knows which chunk failed.
  local next_fraction
  next_fraction="$(bc -l <<< "$fraction - $step")"
  local below_floor
  below_floor="$(bc -l <<< "$next_fraction < $floor")"
  if [[ "$below_floor" == "1" ]]; then
    die "accumulator: chunk $(basename "$chunk_file") is too dense to fit even at fraction ${fraction} (below floor ${floor}). Reduce the input or increase the model's context."
    return 1
  fi

  warn "accumulator: chunk $(basename "$chunk_file") overflowed context; shaving to fraction ${next_fraction}"

  # Re-split THIS chunk at the smaller budget.
  local sub_max_chars
  sub_max_chars="$(_accumulate:_max-chars "$max_tokens" "$cpt" "$next_fraction")"

  local sub_dir
  sub_dir="$(mktemp -d -t scratch-acc-sub-XXXXXX)"
  _accumulate:_split "$chunk_file" "$sub_max_chars" "$sub_dir"

  # Process each sub-chunk sequentially. Each starts at the new (already
  # shaved) fraction and may further shave from there if it overflows.
  local sub_chunk
  local current_notes="$notes"
  for sub_chunk in "$sub_dir"/*; do
    [[ -f "$sub_chunk" ]] || continue
    current_notes="$(_accumulate:_process-chunk-with-backoff \
      "$model" "$user_prompt" "$question" "$current_notes" \
      "$sub_chunk" "$extras" "$line_numbers" \
      "$max_tokens" "$cpt" "$next_fraction" "$floor" "$step")" || {
      local sub_rc=$?
      rm -rf "$sub_dir"
      return "$sub_rc"
    }
  done

  rm -rf "$sub_dir"
  printf '%s' "$current_notes"
}

#-------------------------------------------------------------------------------
# accumulate:run MODEL PROMPT INPUT [OPTIONS_JSON]
#
# Public entry point. Process INPUT against MODEL by chunking it according
# to the model's context window, running a chat:completion round per chunk
# that builds up structured `accumulated_notes`, then a final cleanup pass
# that returns the user-facing answer on stdout.
#
# OPTIONS_JSON is a JSON object with these optional keys:
#   question         string, the user's overarching question/goal
#   extras           object, chat completion extras to pass through
#   max_context      int, override the model's context window in tokens
#   chars_per_token  float, override the per-call ratio (default 4.0)
#   line_numbers     bool, default false
#   start_fraction   float, default 0.7
#   floor_fraction   float, default 0.3
#   backoff_step     float, default 0.1
#
# Dies on validation failure. Propagates die from chat:completion if
# the API errors during a round.
#-------------------------------------------------------------------------------
accumulate:run() {
  local model="$1"
  local user_prompt="$2"
  local input="$3"
  local options="${4:-}"
  [[ -n "$options" ]] || options='{}'

  local question
  question="$(jq -r '.question // ""' <<< "$options")"
  local extras
  extras="$(jq -c '.extras // {}' <<< "$options")"
  local max_tokens
  max_tokens="$(jq -r '.max_context // empty' <<< "$options")"
  local cpt
  cpt="$(jq -r '.chars_per_token // 4' <<< "$options")"
  local line_numbers
  line_numbers="$(jq -r '.line_numbers // false' <<< "$options")"
  local start_fraction
  start_fraction="$(jq -r '.start_fraction // 0.7' <<< "$options")"
  local floor_fraction
  floor_fraction="$(jq -r '.floor_fraction // 0.3' <<< "$options")"
  local backoff_step
  backoff_step="$(jq -r '.backoff_step // 0.1' <<< "$options")"

  # Resolve max_tokens from the model registry if not overridden.
  if [[ -z "$max_tokens" ]]; then
    max_tokens="$(model:jq "$model" '.model_spec.availableContextTokens // 8000')"
  fi

  # Pre-allocate working files in the parent shell. tmp:make registers
  # cleanup in the parent process; calling it from a subshell loses the
  # registration.
  local input_file
  tmp:make input_file /tmp/scratch-acc-input.XXXXXX
  printf '%s' "$input" > "$input_file"

  # Optionally inject line numbers BEFORE splitting so chunk boundaries
  # fall on numbered-line boundaries.
  local working_input="$input_file"
  if [[ "$line_numbers" == "true" ]]; then
    local numbered_file
    tmp:make numbered_file /tmp/scratch-acc-numbered.XXXXXX
    _accumulate:_inject-line-numbers "$input_file" "$numbered_file"
    working_input="$numbered_file"
  fi

  # Pre-split at start_fraction.
  local chunks_dir
  chunks_dir="$(mktemp -d -t scratch-acc-chunks-XXXXXX)"
  local max_chars
  max_chars="$(_accumulate:_max-chars "$max_tokens" "$cpt" "$start_fraction")"
  _accumulate:_split "$working_input" "$max_chars" "$chunks_dir"

  # Reduce. The fraction is reset to start_fraction at every chunk; the
  # backoff loop only shaves WITHIN a single failing chunk.
  local notes=""
  local chunk_file
  for chunk_file in "$chunks_dir"/*; do
    [[ -f "$chunk_file" ]] || continue
    notes="$(_accumulate:_process-chunk-with-backoff \
      "$model" "$user_prompt" "$question" "$notes" \
      "$chunk_file" "$extras" "$line_numbers" \
      "$max_tokens" "$cpt" "$start_fraction" "$floor_fraction" "$backoff_step")" || {
      local rc=$?
      rm -rf "$chunks_dir"
      return "$rc"
    }
  done

  rm -rf "$chunks_dir"

  # Final cleanup pass.
  _accumulate:_finalize "$model" "$user_prompt" "$question" "$notes" "$extras"
}

export -f accumulate:run

#-------------------------------------------------------------------------------
# accumulate:run-profile PROFILE PROMPT INPUT [OPTIONS_JSON]
#
# Convenience wrapper around accumulate:run. Resolves PROFILE via
# model:profile:resolve, reads chars_per_token (default 4.0), merges the
# profile's params/venice_parameters into OPTIONS_JSON.extras, then calls
# accumulate:run with the resolved model id.
#
# Caller-supplied options take precedence over the profile's defaults
# for chars_per_token. Caller-supplied extras keys also win over the
# profile's params (deep merge with the caller as the rightmost operand).
#-------------------------------------------------------------------------------
accumulate:run-profile() {
  local profile="$1"
  local user_prompt="$2"
  local input="$3"
  local options="${4:-}"
  [[ -n "$options" ]] || options='{}'

  local resolved
  resolved="$(model:profile:resolve "$profile")" || return 1

  local model_id
  model_id="$(jq -r '.model' <<< "$resolved")"

  # If the caller did not specify chars_per_token, take the profile's.
  if ! jq -e 'has("chars_per_token")' <<< "$options" > /dev/null 2>&1; then
    local profile_cpt
    profile_cpt="$(jq -r '.chars_per_token // 4' <<< "$resolved")"
    options="$(jq -c --argjson cpt "$profile_cpt" '. + {chars_per_token: $cpt}' <<< "$options")"
  fi

  # Merge the profile's params + venice_parameters into options.extras.
  # The profile's keys are the base; the caller's extras override.
  local profile_extras
  profile_extras="$(jq -c '
    .params + (
      if (.venice_parameters | length) > 0
      then {venice_parameters: .venice_parameters}
      else {}
      end
    )
  ' <<< "$resolved")"

  options="$(jq -c \
    --argjson p "$profile_extras" \
    '. + {extras: ($p + (.extras // {}))}' <<< "$options")"

  accumulate:run "$model_id" "$user_prompt" "$input" "$options"
}

export -f accumulate:run-profile
