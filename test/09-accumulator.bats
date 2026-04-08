#!/usr/bin/env bats

# vim: set ft=bash
# shellcheck disable=SC2016
set -euo pipefail

#-------------------------------------------------------------------------------
# Tests for lib/accumulator.sh - text-handling layer
#
# Covers the four private text helpers:
#   _accumulate:_token-count
#   _accumulate:_max-chars
#   _accumulate:_split
#   _accumulate:_inject-line-numbers
#
# The chat-layer wrappers (process-chunk, finalize, the reduce loop, and
# the public accumulate:run / accumulate:run-profile entry points) land
# in a follow-up commit and get their own tests.
#-------------------------------------------------------------------------------

setup() {
  SCRIPTDIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" > /dev/null 2>&1 && pwd)"
  SCRATCH_HOME="$(cd "${SCRIPTDIR}/.." && pwd)"
  source "${SCRIPTDIR}/helpers.sh"
  source "${SCRATCH_HOME}/lib/accumulator.sh"

  export HOME="${BATS_TEST_TMPDIR}/home"
  mkdir -p "$HOME"
}

# ---------------------------------------------------------------------------
# _accumulate:_token-count
# ---------------------------------------------------------------------------

@test "_accumulate:_token-count: literal string with default 4.0 ratio" {
  # 16 chars / 4 = 4 tokens
  run _accumulate:_token-count "sixteen chars!!!" 4.0
  is "$status" 0
  is "$output" "4"
}

@test "_accumulate:_token-count: literal string with denser 3.0 ratio" {
  # 12 chars / 3 = 4 tokens
  run _accumulate:_token-count "twelve chars" 3.0
  is "$output" "4"
}

@test "_accumulate:_token-count: 1-char input rounds up to 1 token" {
  run _accumulate:_token-count "x" 4.0
  is "$output" "1"
}

@test "_accumulate:_token-count: empty string is 0 tokens" {
  run _accumulate:_token-count "" 4.0
  is "$output" "0"
}

@test "_accumulate:_token-count: reads char count from a file path" {
  printf 'eight!!!' > "${BATS_TEST_TMPDIR}/in.txt"
  run _accumulate:_token-count "${BATS_TEST_TMPDIR}/in.txt" 4.0
  is "$output" "2"
}

@test "_accumulate:_token-count: empty file is 0 tokens" {
  : > "${BATS_TEST_TMPDIR}/empty.txt"
  run _accumulate:_token-count "${BATS_TEST_TMPDIR}/empty.txt" 4.0
  is "$output" "0"
}

@test "_accumulate:_token-count: ceiling rounds 5 chars / 4 up to 2 tokens" {
  run _accumulate:_token-count "fives" 4.0
  is "$output" "2"
}

# ---------------------------------------------------------------------------
# _accumulate:_max-chars
# ---------------------------------------------------------------------------

@test "_accumulate:_max-chars: typical case 8000 * 4 * 0.7 = 22400" {
  run _accumulate:_max-chars 8000 4.0 0.7
  is "$status" 0
  is "$output" "22400"
}

@test "_accumulate:_max-chars: long-context case 1000000 * 4 * 0.7 = 2800000" {
  run _accumulate:_max-chars 1000000 4.0 0.7
  is "$output" "2800000"
}

@test "_accumulate:_max-chars: floors to int" {
  # 100 * 3.5 * 0.5 = 175 exactly, but try a fractional case
  # 100 * 3.3 * 0.5 = 165.0 - still int
  # Use one that produces a fraction: 100 * 3.5 * 0.33 = 115.5 -> 115
  run _accumulate:_max-chars 100 3.5 0.33
  is "$output" "115"
}

@test "_accumulate:_max-chars: respects denser ratio" {
  # 8000 * 3.0 * 0.7 = 16800
  run _accumulate:_max-chars 8000 3.0 0.7
  is "$output" "16800"
}

# ---------------------------------------------------------------------------
# _accumulate:_split
# ---------------------------------------------------------------------------

@test "_accumulate:_split: input fitting one chunk produces a single 0001 file" {
  printf 'short input\n' > "${BATS_TEST_TMPDIR}/in.txt"
  _accumulate:_split "${BATS_TEST_TMPDIR}/in.txt" 1000 "${BATS_TEST_TMPDIR}/out"
  run ls "${BATS_TEST_TMPDIR}/out"
  is "$output" "0001"
  run cat "${BATS_TEST_TMPDIR}/out/0001"
  is "$output" "short input"
}

@test "_accumulate:_split: multi-line input requiring multiple chunks" {
  # Each line is 11 chars + newline = 12 bytes. With max=20 we should
  # get one line per chunk (line 2 would push the chunk to 24 > 20).
  printf 'aaaaaaaaaaa\nbbbbbbbbbbb\nccccccccccc\n' > "${BATS_TEST_TMPDIR}/in.txt"
  _accumulate:_split "${BATS_TEST_TMPDIR}/in.txt" 20 "${BATS_TEST_TMPDIR}/out"
  run ls "${BATS_TEST_TMPDIR}/out"
  is "$output" "0001
0002
0003"
  run cat "${BATS_TEST_TMPDIR}/out/0001"
  is "$output" "aaaaaaaaaaa"
  run cat "${BATS_TEST_TMPDIR}/out/0002"
  is "$output" "bbbbbbbbbbb"
  run cat "${BATS_TEST_TMPDIR}/out/0003"
  is "$output" "ccccccccccc"
}

@test "_accumulate:_split: chunk packs multiple lines until budget hits" {
  # Five 5-char lines (6 bytes each with newline). Max=20 fits 3 lines
  # (18 bytes); the 4th would push to 24, so it starts chunk 2.
  printf 'aaaaa\nbbbbb\nccccc\nddddd\neeeee\n' > "${BATS_TEST_TMPDIR}/in.txt"
  _accumulate:_split "${BATS_TEST_TMPDIR}/in.txt" 20 "${BATS_TEST_TMPDIR}/out"
  run cat "${BATS_TEST_TMPDIR}/out/0001"
  is "$output" "aaaaa
bbbbb
ccccc"
  run cat "${BATS_TEST_TMPDIR}/out/0002"
  is "$output" "ddddd
eeeee"
}

@test "_accumulate:_split: a single line longer than max gets its own chunk" {
  printf 'short\nthisisaveryverylonglinethatexceedsthebudget\nshort\n' > "${BATS_TEST_TMPDIR}/in.txt"
  _accumulate:_split "${BATS_TEST_TMPDIR}/in.txt" 10 "${BATS_TEST_TMPDIR}/out"
  # Expected: chunk 1 = "short", chunk 2 = the long line, chunk 3 = "short"
  run ls "${BATS_TEST_TMPDIR}/out"
  is "$output" "0001
0002
0003"
  run cat "${BATS_TEST_TMPDIR}/out/0002"
  is "$output" "thisisaveryverylonglinethatexceedsthebudget"
}

@test "_accumulate:_split: input not ending in a newline preserves the last line" {
  printf 'first\nsecond' > "${BATS_TEST_TMPDIR}/in.txt"
  _accumulate:_split "${BATS_TEST_TMPDIR}/in.txt" 1000 "${BATS_TEST_TMPDIR}/out"
  run cat "${BATS_TEST_TMPDIR}/out/0001"
  is "$output" "first
second"
}

@test "_accumulate:_split: empty input produces zero chunk files" {
  : > "${BATS_TEST_TMPDIR}/empty.txt"
  _accumulate:_split "${BATS_TEST_TMPDIR}/empty.txt" 1000 "${BATS_TEST_TMPDIR}/out"
  run bash -c "ls '${BATS_TEST_TMPDIR}/out' | wc -l | tr -d ' '"
  is "$output" "0"
}

@test "_accumulate:_split: chunk boundaries fall on line endings (no half-lines)" {
  printf 'line1\nline2\nline3\n' > "${BATS_TEST_TMPDIR}/in.txt"
  _accumulate:_split "${BATS_TEST_TMPDIR}/in.txt" 10 "${BATS_TEST_TMPDIR}/out"
  # Each chunk file should end with a newline. Use od on the last byte
  # because bash command substitution strips trailing newlines from
  # $(tail -c 1) output.
  for f in "${BATS_TEST_TMPDIR}/out"/*; do
    local last
    last="$(tail -c 1 "$f" | od -An -c | tr -d ' ')"
    is "$last" '\n'
  done
}

# ---------------------------------------------------------------------------
# _accumulate:_inject-line-numbers
# ---------------------------------------------------------------------------

@test "_accumulate:_inject-line-numbers: prefixes every line with <n>:<hash>|" {
  printf 'first line\nsecond line\nthird line\n' > "${BATS_TEST_TMPDIR}/in.txt"
  _accumulate:_inject-line-numbers "${BATS_TEST_TMPDIR}/in.txt" "${BATS_TEST_TMPDIR}/out.txt"

  run cat "${BATS_TEST_TMPDIR}/out.txt"
  # Three lines, each matching <num>:<8 hex>|<original>
  local line1 line2 line3
  line1="$(sed -n '1p' "${BATS_TEST_TMPDIR}/out.txt")"
  line2="$(sed -n '2p' "${BATS_TEST_TMPDIR}/out.txt")"
  line3="$(sed -n '3p' "${BATS_TEST_TMPDIR}/out.txt")"

  [[ "$line1" =~ ^1:[0-9a-f]{8}\|first\ line$ ]]
  [[ "$line2" =~ ^2:[0-9a-f]{8}\|second\ line$ ]]
  [[ "$line3" =~ ^3:[0-9a-f]{8}\|third\ line$ ]]
}

@test "_accumulate:_inject-line-numbers: numbers are 1-based and sequential" {
  printf 'a\nb\nc\nd\ne\n' > "${BATS_TEST_TMPDIR}/in.txt"
  _accumulate:_inject-line-numbers "${BATS_TEST_TMPDIR}/in.txt" "${BATS_TEST_TMPDIR}/out.txt"

  run bash -c "cut -d: -f1 '${BATS_TEST_TMPDIR}/out.txt'"
  is "$output" "1
2
3
4
5"
}

@test "_accumulate:_inject-line-numbers: hashes differ across distinct content" {
  printf 'apple\nbanana\n' > "${BATS_TEST_TMPDIR}/in.txt"
  _accumulate:_inject-line-numbers "${BATS_TEST_TMPDIR}/in.txt" "${BATS_TEST_TMPDIR}/out.txt"

  local h1 h2
  h1="$(sed -n '1p' "${BATS_TEST_TMPDIR}/out.txt" | cut -d: -f2 | cut -d'|' -f1)"
  h2="$(sed -n '2p' "${BATS_TEST_TMPDIR}/out.txt" | cut -d: -f2 | cut -d'|' -f1)"

  [[ "$h1" != "$h2" ]]
}

@test "_accumulate:_inject-line-numbers: identical content gets identical hash" {
  printf 'same\nsame\n' > "${BATS_TEST_TMPDIR}/in.txt"
  _accumulate:_inject-line-numbers "${BATS_TEST_TMPDIR}/in.txt" "${BATS_TEST_TMPDIR}/out.txt"

  local h1 h2
  h1="$(sed -n '1p' "${BATS_TEST_TMPDIR}/out.txt" | cut -d: -f2 | cut -d'|' -f1)"
  h2="$(sed -n '2p' "${BATS_TEST_TMPDIR}/out.txt" | cut -d: -f2 | cut -d'|' -f1)"

  is "$h1" "$h2"
}

@test "_accumulate:_inject-line-numbers: handles input not ending in a newline" {
  printf 'first\nlast' > "${BATS_TEST_TMPDIR}/in.txt"
  _accumulate:_inject-line-numbers "${BATS_TEST_TMPDIR}/in.txt" "${BATS_TEST_TMPDIR}/out.txt"

  # Both lines should be present in the output
  run bash -c "wc -l < '${BATS_TEST_TMPDIR}/out.txt' | tr -d ' '"
  is "$output" "2"

  local last
  last="$(sed -n '2p' "${BATS_TEST_TMPDIR}/out.txt")"
  [[ "$last" =~ ^2:[0-9a-f]{8}\|last$ ]]
}

# ===========================================================================
# CHAT-LAYER TESTS
#
# These tests stub chat:completion as a bash function that reads canned
# responses from a queue under BATS_TEST_TMPDIR. The accumulator's contract
# is "calls chat:completion N times in order, each call gets the next
# canned response", so the queue lets us script multi-round scenarios
# without touching the venice HTTP layer.
#
# A canned "response" file looks like a real chat:completion response:
#   {"choices":[{"message":{"content":"<json string>"}}]}
# where the inner string is the model's structured-output object as
# encoded JSON. queue_round_response and queue_final_response wrap that
# shape so tests can specify just the meaningful fields.
# ===========================================================================

# Initialize the queue and override chat:completion + supporting helpers.
setup_chat_stub() {
  CHAT_QUEUE_DIR="${BATS_TEST_TMPDIR}/chat-queue"
  mkdir -p "$CHAT_QUEUE_DIR"
  printf '0' > "${CHAT_QUEUE_DIR}/n"
  CHAT_LOG_FILE="${BATS_TEST_TMPDIR}/chat-calls.log"
  : > "$CHAT_LOG_FILE"

  # Override chat:completion. Each invocation increments the counter and
  # returns the matching canned response (or exit code).
  chat:completion() {
    local model="$1"
    local messages="$2"
    local extras="${3:-}"

    local n
    n="$(cat "${CHAT_QUEUE_DIR}/n")"
    n=$((n + 1))
    printf '%s' "$n" > "${CHAT_QUEUE_DIR}/n"

    # Log the call so tests can introspect what was sent
    {
      printf '=== call %s ===\n' "$n"
      printf 'model: %s\n' "$model"
      printf 'messages: %s\n' "$messages"
      printf 'extras: %s\n' "$extras"
    } >> "$CHAT_LOG_FILE"

    if [[ -f "${CHAT_QUEUE_DIR}/exit-${n}" ]]; then
      return "$(cat "${CHAT_QUEUE_DIR}/exit-${n}")"
    fi
    if [[ -f "${CHAT_QUEUE_DIR}/response-${n}" ]]; then
      cat "${CHAT_QUEUE_DIR}/response-${n}"
      return 0
    fi
    printf 'chat-stub: no canned response for call %s\n' "$n" >&2
    return 1
  }
  export -f chat:completion

  # Stub model:jq so accumulate:run can resolve a context window without
  # hitting the registry cache or the network.
  model:jq() {
    printf '8000'
  }
  export -f model:jq

  # Stub model:profile:resolve for accumulate:run-profile tests.
  model:profile:resolve() {
    cat "${CHAT_QUEUE_DIR}/profile.json"
  }
  export -f model:profile:resolve
}

# Append a canned round response to the queue. The argument is the
# accumulated_notes value the model should "return".
queue_round_response() {
  local notes="$1"
  local current_chunk="${2:-processed a chunk}"
  local n=1
  while [[ -e "${CHAT_QUEUE_DIR}/response-${n}" || -e "${CHAT_QUEUE_DIR}/exit-${n}" ]]; do
    n=$((n + 1))
  done
  local content
  content="$(jq -c -n --arg c "$current_chunk" --arg n "$notes" \
    '{current_chunk: $c, accumulated_notes: $n}')"
  jq -c -n --arg content "$content" \
    '{choices:[{message:{content: $content}}]}' \
    > "${CHAT_QUEUE_DIR}/response-${n}"
}

# Append a canned final response. The argument is the .result value.
queue_final_response() {
  local result="$1"
  local n=1
  while [[ -e "${CHAT_QUEUE_DIR}/response-${n}" || -e "${CHAT_QUEUE_DIR}/exit-${n}" ]]; do
    n=$((n + 1))
  done
  local content
  content="$(jq -c -n --arg r "$result" '{result: $r}')"
  jq -c -n --arg content "$content" \
    '{choices:[{message:{content: $content}}]}' \
    > "${CHAT_QUEUE_DIR}/response-${n}"
}

# Append a non-zero exit code to the queue (for backoff tests).
queue_exit_code() {
  local code="$1"
  local n=1
  while [[ -e "${CHAT_QUEUE_DIR}/response-${n}" || -e "${CHAT_QUEUE_DIR}/exit-${n}" ]]; do
    n=$((n + 1))
  done
  printf '%s' "$code" > "${CHAT_QUEUE_DIR}/exit-${n}"
}

# ---------------------------------------------------------------------------
# accumulate:run - happy paths
# ---------------------------------------------------------------------------

@test "accumulate:run: one-chunk input runs one round + finalize" {
  setup_chat_stub
  queue_round_response "extracted: hi"
  queue_final_response "the final answer"

  run accumulate:run llama-3-large "describe this" "hello world"
  is "$status" 0
  is "$output" "the final answer"

  # Two calls total: one round + one finalize
  is "$(cat "${CHAT_QUEUE_DIR}/n")" "2"
}

@test "accumulate:run: multi-chunk input accumulates notes across rounds" {
  setup_chat_stub
  # max_context tiny so the input definitely splits.
  # 32 tokens * 4 cpt * 0.7 fraction = ~89 chars per chunk
  queue_round_response "saw alpha"
  queue_round_response "saw alpha and beta"
  queue_round_response "saw alpha, beta, gamma"
  queue_final_response "all three"

  # Three lines, each ~80 chars, will produce three chunks at the
  # tiny max_context.
  local input
  input="$(printf 'alpha %.0s' {1..15})
$(printf 'beta %.0s' {1..15})
$(printf 'gamma %.0s' {1..15})"

  run accumulate:run llama-3-large "extract" "$input" '{"max_context":32}'
  is "$status" 0
  is "$output" "all three"

  # Four calls: three rounds + one finalize
  is "$(cat "${CHAT_QUEUE_DIR}/n")" "4"

  # Verify the second round saw the first round's notes in its system prompt
  grep -q "saw alpha" "$CHAT_LOG_FILE"
}

@test "accumulate:run: empty input runs only finalize" {
  setup_chat_stub
  queue_final_response "nothing to see"

  run accumulate:run llama-3-large "describe" ""
  is "$status" 0
  is "$output" "nothing to see"
  is "$(cat "${CHAT_QUEUE_DIR}/n")" "1"
}

@test "accumulate:run: injects the rendered system prompt into the round messages" {
  setup_chat_stub
  queue_round_response "ok"
  queue_final_response "done"

  run accumulate:run llama-3-large "MY_USER_PROMPT" "hi"
  is "$status" 0
  grep -q 'MY_USER_PROMPT' "$CHAT_LOG_FILE"
  # The system prompt should also have the accumulator's meta language
  grep -q 'accumulated_notes' "$CHAT_LOG_FILE"
}

@test "accumulate:run: line_numbers mode transforms input and appends LN prompt section" {
  setup_chat_stub
  queue_round_response "ok"
  queue_final_response "done"

  run accumulate:run llama-3-large "extract" "first
second" '{"line_numbers":true}'
  is "$status" 0

  # Round message body should contain the <n>:<hash>|<content> format
  grep -qE '1:[0-9a-f]{8}\\\|first' "$CHAT_LOG_FILE" || grep -qE '1:[0-9a-f]{8}\|first' "$CHAT_LOG_FILE"
  # The line-numbers prompt section should have been appended to the system prompt
  grep -q 'content_hash' "$CHAT_LOG_FILE"
}

@test "accumulate:run: extras are passed through to chat:completion" {
  setup_chat_stub
  queue_round_response "ok"
  queue_final_response "done"

  run accumulate:run llama-3-large "extract" "hi" '{"extras":{"temperature":0.42}}'
  is "$status" 0
  grep -q '"temperature":0.42' "$CHAT_LOG_FILE"
}

@test "accumulate:run: schema is injected into extras as response_format" {
  setup_chat_stub
  queue_round_response "ok"
  queue_final_response "done"

  run accumulate:run llama-3-large "extract" "hi"
  is "$status" 0
  grep -q '"response_format"' "$CHAT_LOG_FILE"
  grep -q '"accumulator_round"' "$CHAT_LOG_FILE"
  grep -q '"accumulator_final"' "$CHAT_LOG_FILE"
}

@test "accumulate:run: caller-supplied response_format is overridden with a warn" {
  setup_chat_stub
  queue_round_response "ok"
  queue_final_response "done"

  run --separate-stderr accumulate:run llama-3-large "extract" "hi" \
    '{"extras":{"response_format":{"type":"text"}}}'
  is "$status" 0
  [[ "$stderr" == *"overriding"* ]]
  # The accumulator's schema should win
  grep -q '"accumulator_round"' "$CHAT_LOG_FILE"
}

# ---------------------------------------------------------------------------
# accumulate:run - reactive backoff
# ---------------------------------------------------------------------------

@test "accumulate:run: context overflow triggers shave-and-retry on the failing chunk" {
  setup_chat_stub
  # First call (the only original chunk) overflows; the chunk gets re-split,
  # and the resulting sub-chunk(s) succeed.
  queue_exit_code 9
  queue_round_response "ok after shave"
  queue_final_response "done"

  run --separate-stderr accumulate:run llama-3-large "x" "small input"
  is "$status" 0
  is "$output" "done"
  [[ "$stderr" == *"shaving to fraction"* ]]
}

@test "accumulate:run: walking the floor dies with a clear message" {
  setup_chat_stub
  # Every attempt overflows. With start=0.7 step=0.1 floor=0.3:
  # tries 0.7, 0.6, 0.5, 0.4, then next would be 0.3 which is NOT < 0.3,
  # so it tries 0.3, then next would be 0.2 < 0.3 -> die.
  local _i
  for _i in 1 2 3 4 5 6; do
    queue_exit_code 9
  done

  run accumulate:run llama-3-large "x" "small input"
  is "$status" 1
  [[ "$output" == *"too dense"* ]]
}

# ---------------------------------------------------------------------------
# accumulate:run-profile
# ---------------------------------------------------------------------------

@test "accumulate:run-profile: resolves profile and forwards to accumulate:run" {
  setup_chat_stub
  cat > "${CHAT_QUEUE_DIR}/profile.json" << 'EOF'
{
  "model": "llama-3-large",
  "chars_per_token": 4.0,
  "params": {"temperature": 0.3},
  "venice_parameters": {}
}
EOF
  queue_round_response "ok"
  queue_final_response "done"

  run accumulate:run-profile long-context "extract" "hi"
  is "$status" 0
  is "$output" "done"
  # The profile's params should have been merged into extras
  grep -q '"temperature":0.3' "$CHAT_LOG_FILE"
}

@test "accumulate:run-profile: caller extras override profile params" {
  setup_chat_stub
  cat > "${CHAT_QUEUE_DIR}/profile.json" << 'EOF'
{
  "model": "llama-3-large",
  "chars_per_token": 4.0,
  "params": {"temperature": 0.3},
  "venice_parameters": {}
}
EOF
  queue_round_response "ok"
  queue_final_response "done"

  run accumulate:run-profile long-context "extract" "hi" '{"extras":{"temperature":0.99}}'
  is "$status" 0
  grep -q '"temperature":0.99' "$CHAT_LOG_FILE"
}

@test "accumulate:run-profile: defaults chars_per_token to 4.0 when profile omits it" {
  setup_chat_stub
  cat > "${CHAT_QUEUE_DIR}/profile.json" << 'EOF'
{
  "model": "llama-3-large",
  "params": {},
  "venice_parameters": {}
}
EOF
  queue_round_response "ok"
  queue_final_response "done"

  run accumulate:run-profile some-profile "extract" "hi"
  is "$status" 0
}
