#!/usr/bin/env bats

# vim: set ft=bash
# shellcheck disable=SC2016
set -euo pipefail

#-------------------------------------------------------------------------------
# Tests for lib/venice.sh
#
# venice:api-key resolution tests are pure (no curl involved).
# venice:curl tests install a curl stub that writes a pre-canned body to the
# file specified via -o and prints a pre-canned status code to stdout. The
# stub reads those from files under $BATS_TEST_TMPDIR so the test body can
# configure them per case.
#-------------------------------------------------------------------------------

setup() {
  SCRIPTDIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" > /dev/null 2>&1 && pwd)"
  SCRATCH_HOME="$(cd "${SCRIPTDIR}/.." && pwd)"
  source "${SCRIPTDIR}/helpers.sh"
  source "${SCRATCH_HOME}/lib/venice.sh"

  # Per-test HOME so anything resolving under $HOME/.config/scratch/...
  # is fresh for every test.
  export HOME="${BATS_TEST_TMPDIR}/home"
  mkdir -p "$HOME"

  # Defaults used by venice:curl tests
  export SCRATCH_VENICE_API_KEY="test-key"

  # Disable retry by default so non-retry tests assert single-shot
  # behavior. Retry-specific tests override this to a higher value.
  export SCRATCH_VENICE_MAX_ATTEMPTS=1

  # Override sleep so retry tests never actually wait. Exported so it
  # propagates into subshells created by bats `run`. Tests that need
  # real sleep (none currently) can `unset -f sleep` locally.
  # shellcheck disable=SC2329 # called indirectly by venice:curl after it's sourced
  sleep() { :; }
  export -f sleep
}

# Install a curl stub that replays canned body + status for venice:curl tests.
# Writes:
#   BATS_TEST_TMPDIR/curl-response.body    (body content)
#   BATS_TEST_TMPDIR/curl-response.status  (status code)
install_curl_stub() {
  local body="$1"
  local status="$2"

  printf '%s' "$body" > "${BATS_TEST_TMPDIR}/curl-response.body"
  printf '%s' "$status" > "${BATS_TEST_TMPDIR}/curl-response.status"

  make_stub curl "$(
    cat << STUB
#!/usr/bin/env bash
# Find -o FILE and -D FILE in args
body_file=""
headers_file=""
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    -o) body_file="\$2"; shift 2 ;;
    -D) headers_file="\$2"; shift 2 ;;
    *) shift ;;
  esac
done
if [[ -n "\$body_file" ]]; then
  cat '${BATS_TEST_TMPDIR}/curl-response.body' > "\$body_file"
fi
if [[ -n "\$headers_file" && -f '${BATS_TEST_TMPDIR}/curl-response.headers' ]]; then
  cat '${BATS_TEST_TMPDIR}/curl-response.headers' > "\$headers_file"
fi
cat '${BATS_TEST_TMPDIR}/curl-response.status'
STUB
  )" > /dev/null

  prepend_stub_path
}

# ---------------------------------------------------------------------------
# venice:api-key
# ---------------------------------------------------------------------------

@test "venice:api-key prefers SCRATCH_VENICE_API_KEY when both are set" {
  export SCRATCH_VENICE_API_KEY="from-scratch"
  export VENICE_API_KEY="from-venice"
  run venice:api-key
  is "$status" 0
  is "$output" "from-scratch"
}

@test "venice:api-key falls back to VENICE_API_KEY" {
  unset SCRATCH_VENICE_API_KEY
  export VENICE_API_KEY="from-venice"
  run venice:api-key
  is "$status" 0
  is "$output" "from-venice"
}

@test "venice:api-key dies when neither is set" {
  unset SCRATCH_VENICE_API_KEY
  unset VENICE_API_KEY
  run bash -c 'set -e; source '"${SCRATCH_HOME}"'/lib/venice.sh; venice:api-key 2>&1'
  is "$status" 1
  [[ "$output" == *"no API key found"* ]]
  [[ "$output" == *"SCRATCH_VENICE_API_KEY"* ]]
  [[ "$output" == *"VENICE_API_KEY"* ]]
}

@test "venice:api-key dies when both are empty strings" {
  export SCRATCH_VENICE_API_KEY=""
  export VENICE_API_KEY=""
  run bash -c 'set -e; export SCRATCH_VENICE_API_KEY=""; export VENICE_API_KEY=""; source '"${SCRATCH_HOME}"'/lib/venice.sh; venice:api-key 2>&1'
  is "$status" 1
  [[ "$output" == *"no API key found"* ]]
}

# ---------------------------------------------------------------------------
# venice:base-url
# ---------------------------------------------------------------------------

@test "venice:base-url returns the hard-coded API root" {
  run venice:base-url
  is "$status" 0
  is "$output" "https://api.venice.ai/api/v1"
}

# ---------------------------------------------------------------------------
# venice:config-dir
# ---------------------------------------------------------------------------

@test "venice:config-dir returns and creates the config dir under HOME" {
  run venice:config-dir
  is "$status" 0
  is "$output" "${HOME}/.config/scratch/venice"
  [[ -d "$output" ]]
}

# ---------------------------------------------------------------------------
# venice:curl - success paths
# ---------------------------------------------------------------------------

@test "venice:curl returns body on 200" {
  install_curl_stub '{"ok":true}' "200"
  run venice:curl GET /models
  is "$status" 0
  is "$output" '{"ok":true}'
}

@test "venice:curl handles 201 success" {
  install_curl_stub '{"created":true}' "201"
  run venice:curl POST /foo '{"x":1}'
  is "$status" 0
  is "$output" '{"created":true}'
}

@test "venice:curl sends the body when provided" {
  # We can't directly verify stdin bytes without a more elaborate stub,
  # but we can verify the call succeeds end-to-end with a body argument.
  install_curl_stub '{"echoed":"ok"}' "200"
  run venice:curl POST /chat/completions '{"model":"x","messages":[]}'
  is "$status" 0
  is "$output" '{"echoed":"ok"}'
}

# ---------------------------------------------------------------------------
# venice:curl - documented error codes get friendly messages
# ---------------------------------------------------------------------------

@test "venice:curl dies with credit message on 402" {
  install_curl_stub '{"error":"payment required"}' "402"
  run bash -c 'set -e; export SCRATCH_VENICE_API_KEY=test-key; export PATH="'"${BATS_TEST_TMPDIR}"'/stubbin:$PATH"; source '"${SCRATCH_HOME}"'/lib/venice.sh; venice:curl GET /models 2>&1'
  is "$status" 1
  [[ "$output" == *"insufficient credits"* ]]
  [[ "$output" == *"402"* ]]
}

@test "venice:curl dies with auth message on 401" {
  install_curl_stub '{"error":"unauthorized"}' "401"
  run bash -c 'set -e; export SCRATCH_VENICE_API_KEY=test-key; export PATH="'"${BATS_TEST_TMPDIR}"'/stubbin:$PATH"; source '"${SCRATCH_HOME}"'/lib/venice.sh; venice:curl GET /models 2>&1'
  is "$status" 1
  [[ "$output" == *"authentication failed"* ]]
  [[ "$output" == *"401"* ]]
}

@test "venice:curl dies with rate-limit message on 429 (single attempt)" {
  install_curl_stub '{"error":"rate limited"}' "429"
  # MAX_ATTEMPTS=1 from setup() - single shot, no retry
  run bash -c 'set -e; export SCRATCH_VENICE_API_KEY=test-key; export SCRATCH_VENICE_MAX_ATTEMPTS=1; export PATH="'"${BATS_TEST_TMPDIR}"'/stubbin:$PATH"; source '"${SCRATCH_HOME}"'/lib/venice.sh; venice:curl GET /models 2>&1'
  is "$status" 1
  [[ "$output" == *"rate limited"* ]]
  [[ "$output" == *"429"* ]]
  [[ "$output" == *"exhausted"* ]]
}

@test "venice:curl dies with capacity message on 503 (single attempt)" {
  install_curl_stub '{"error":"busy"}' "503"
  run bash -c 'set -e; export SCRATCH_VENICE_API_KEY=test-key; export SCRATCH_VENICE_MAX_ATTEMPTS=1; export PATH="'"${BATS_TEST_TMPDIR}"'/stubbin:$PATH"; source '"${SCRATCH_HOME}"'/lib/venice.sh; venice:curl GET /models 2>&1'
  is "$status" 1
  [[ "$output" == *"at capacity"* ]]
  [[ "$output" == *"503"* ]]
  [[ "$output" == *"exhausted"* ]]
}

@test "venice:curl dies with unknown-status message on 418" {
  install_curl_stub '{"error":"teapot"}' "418"
  run bash -c 'set -e; export SCRATCH_VENICE_API_KEY=test-key; export PATH="'"${BATS_TEST_TMPDIR}"'/stubbin:$PATH"; source '"${SCRATCH_HOME}"'/lib/venice.sh; venice:curl GET /models 2>&1'
  is "$status" 1
  [[ "$output" == *"418"* ]]
  [[ "$output" == *"teapot"* ]]
}

# ---------------------------------------------------------------------------
# _venice:_backoff-seconds - log10 curve math
#
# Verify the expected curve at the default base. These assertions lock in
# the specific values from the design table in lib/venice.sh so any
# accidental change to the formula or base is caught immediately.
# ---------------------------------------------------------------------------

@test "_venice:_backoff-seconds: attempt 1 is 2 seconds" {
  run _venice:_backoff-seconds 1
  is "$status" 0
  is "$output" "2"
}

@test "_venice:_backoff-seconds: attempt 2 is 3 seconds" {
  run _venice:_backoff-seconds 2
  is "$output" "3"
}

@test "_venice:_backoff-seconds: attempt 5 is 4 seconds" {
  run _venice:_backoff-seconds 5
  is "$output" "4"
}

@test "_venice:_backoff-seconds: attempt 10 is 4 seconds" {
  run _venice:_backoff-seconds 10
  is "$output" "4"
}

@test "_venice:_backoff-seconds: attempt 100 is 6 seconds (self-capping)" {
  run _venice:_backoff-seconds 100
  is "$output" "6"
}

@test "_venice:_backoff-seconds: attempt 1000 is 8 seconds (still capped)" {
  run _venice:_backoff-seconds 1000
  is "$output" "8"
}

# ---------------------------------------------------------------------------
# venice:curl retry behavior
#
# Uses a multi-response curl stub that reads a counter file and returns
# different status/body pairs per attempt. Tests override sleep (already
# done in setup) so retries are instant.
# ---------------------------------------------------------------------------

# Install a curl stub that returns different responses per call attempt.
# Pass pairs of "STATUS:BODY" arguments in order. The stub increments a
# counter file to track which pair to return on each call.
install_multi_curl_stub() {
  local counter_file="${BATS_TEST_TMPDIR}/curl-attempt.counter"
  printf '0' > "$counter_file"

  local i=1
  local pair
  for pair in "$@"; do
    local status="${pair%%:*}"
    local body="${pair#*:}"
    printf '%s' "$status" > "${BATS_TEST_TMPDIR}/curl-response.status.${i}"
    printf '%s' "$body" > "${BATS_TEST_TMPDIR}/curl-response.body.${i}"
    i=$((i + 1))
  done

  make_stub curl "$(
    cat << STUB
#!/usr/bin/env bash
# Increment the attempt counter
counter_file='${BATS_TEST_TMPDIR}/curl-attempt.counter'
n=\$(cat "\$counter_file")
n=\$((n + 1))
printf '%s' "\$n" > "\$counter_file"

# Find -o FILE and -D FILE in args
body_file=""
headers_file=""
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    -o) body_file="\$2"; shift 2 ;;
    -D) headers_file="\$2"; shift 2 ;;
    *) shift ;;
  esac
done

# Write the body and (optionally) headers for this attempt, print the status
body_src='${BATS_TEST_TMPDIR}/curl-response.body.'"\${n}"
status_src='${BATS_TEST_TMPDIR}/curl-response.status.'"\${n}"
headers_src='${BATS_TEST_TMPDIR}/curl-response.headers.'"\${n}"
if [[ -n "\$body_file" && -f "\$body_src" ]]; then
  cat "\$body_src" > "\$body_file"
fi
if [[ -n "\$headers_file" && -f "\$headers_src" ]]; then
  cat "\$headers_src" > "\$headers_file"
fi
if [[ -f "\$status_src" ]]; then
  cat "\$status_src"
else
  printf '500'
fi
STUB
  )" > /dev/null

  prepend_stub_path
}

@test "venice:curl retries on 429 then succeeds on second attempt" {
  install_multi_curl_stub "429:{\"err\":\"slow down\"}" "200:{\"ok\":true}"
  export SCRATCH_VENICE_MAX_ATTEMPTS=3

  run --separate-stderr venice:curl GET /models
  is "$status" 0
  is "$output" '{"ok":true}'
  # stderr should contain the retry warning for the first attempt
  [[ "$stderr" == *"retrying"* ]]
  [[ "$stderr" == *"429"* ]]
}

@test "venice:curl retries on 503 then succeeds on second attempt" {
  install_multi_curl_stub "503:{\"err\":\"busy\"}" "200:{\"ok\":true}"
  export SCRATCH_VENICE_MAX_ATTEMPTS=3

  run --separate-stderr venice:curl GET /models
  is "$status" 0
  is "$output" '{"ok":true}'
  [[ "$stderr" == *"retrying"* ]]
  [[ "$stderr" == *"503"* ]]
}

@test "venice:curl retries on 504 then succeeds on third attempt" {
  install_multi_curl_stub "504:{}" "504:{}" "200:{\"ok\":true}"
  export SCRATCH_VENICE_MAX_ATTEMPTS=3

  run --separate-stderr venice:curl GET /models
  is "$status" 0
  is "$output" '{"ok":true}'
  # Two retry warnings expected (attempts 1 and 2 both failed with 504)
  [[ "$stderr" == *"attempt 1/3"* ]]
  [[ "$stderr" == *"attempt 2/3"* ]]
}

@test "venice:curl dies with exhausted message after max attempts of 429" {
  install_multi_curl_stub "429:{}" "429:{}" "429:{}"
  export SCRATCH_VENICE_MAX_ATTEMPTS=3

  run bash -c '
    set -e
    export SCRATCH_VENICE_API_KEY=test-key
    export SCRATCH_VENICE_MAX_ATTEMPTS=3
    export PATH="'"${BATS_TEST_TMPDIR}"'/stubbin:$PATH"
    sleep() { :; }
    export -f sleep
    source '"${SCRATCH_HOME}"'/lib/venice.sh
    venice:curl GET /models 2>&1
  '
  is "$status" 1
  [[ "$output" == *"exhausted 3 attempts"* ]]
  [[ "$output" == *"rate limited"* ]]
}

@test "venice:curl does NOT retry on 401 (non-retryable)" {
  install_multi_curl_stub "401:{\"err\":\"bad key\"}" "200:{\"ok\":true}"
  export SCRATCH_VENICE_MAX_ATTEMPTS=3

  run bash -c '
    set -e
    export SCRATCH_VENICE_API_KEY=test-key
    export SCRATCH_VENICE_MAX_ATTEMPTS=3
    export PATH="'"${BATS_TEST_TMPDIR}"'/stubbin:$PATH"
    sleep() { :; }
    export -f sleep
    source '"${SCRATCH_HOME}"'/lib/venice.sh
    venice:curl GET /models 2>&1
  '
  # Should die on first attempt, never reach the "200" second response
  is "$status" 1
  [[ "$output" == *"authentication failed"* ]]
  [[ "$output" != *"exhausted"* ]]
}

@test "venice:curl retries on 500 then succeeds (Venice docs say 500 is retryable)" {
  install_multi_curl_stub "500:{\"err\":\"oops\"}" "200:{\"ok\":true}"
  export SCRATCH_VENICE_MAX_ATTEMPTS=3

  run --separate-stderr venice:curl GET /models
  is "$status" 0
  is "$output" '{"ok":true}'
  [[ "$stderr" == *"500"* ]]
  [[ "$stderr" == *"retrying"* ]]
}

@test "venice:curl dies with server-error message after exhausting 500 retries" {
  install_multi_curl_stub "500:{}" "500:{}" "500:{}"
  export SCRATCH_VENICE_MAX_ATTEMPTS=3

  run bash -c '
    set -e
    export SCRATCH_VENICE_API_KEY=test-key
    export SCRATCH_VENICE_MAX_ATTEMPTS=3
    export PATH="'"${BATS_TEST_TMPDIR}"'/stubbin:$PATH"
    sleep() { :; }
    export -f sleep
    source '"${SCRATCH_HOME}"'/lib/venice.sh
    venice:curl GET /models 2>&1
  '
  is "$status" 1
  [[ "$output" == *"server error"* ]]
  [[ "$output" == *"500"* ]]
  [[ "$output" == *"exhausted 3 attempts"* ]]
}

@test "venice:curl does NOT retry on 402 (non-retryable)" {
  install_multi_curl_stub "402:{\"err\":\"broke\"}" "200:{\"ok\":true}"
  export SCRATCH_VENICE_MAX_ATTEMPTS=3

  run bash -c '
    set -e
    export SCRATCH_VENICE_API_KEY=test-key
    export SCRATCH_VENICE_MAX_ATTEMPTS=3
    export PATH="'"${BATS_TEST_TMPDIR}"'/stubbin:$PATH"
    sleep() { :; }
    export -f sleep
    source '"${SCRATCH_HOME}"'/lib/venice.sh
    venice:curl GET /models 2>&1
  '
  is "$status" 1
  [[ "$output" == *"insufficient credits"* ]]
  [[ "$output" != *"exhausted"* ]]
}

# ---------------------------------------------------------------------------
# _venice:_reset-wait - parses x-ratelimit-reset-requests
# ---------------------------------------------------------------------------

@test "_venice:_reset-wait returns empty when headers file is missing" {
  run _venice:_reset-wait "${BATS_TEST_TMPDIR}/no-such-file"
  is "$status" 0
  is "$output" ""
}

@test "_venice:_reset-wait returns empty when header is absent" {
  printf 'HTTP/1.1 429\r\ncontent-type: application/json\r\n\r\n' > "${BATS_TEST_TMPDIR}/h"
  run _venice:_reset-wait "${BATS_TEST_TMPDIR}/h"
  is "$output" ""
}

@test "_venice:_reset-wait returns seconds-until-reset for a future timestamp" {
  local future
  future=$(($(date +%s) + 7))
  printf 'HTTP/1.1 429\r\nx-ratelimit-reset-requests: %s\r\n\r\n' "$future" > "${BATS_TEST_TMPDIR}/h"
  run _venice:_reset-wait "${BATS_TEST_TMPDIR}/h"
  is "$status" 0
  # Allow off-by-one for clock tick during the call
  [[ "$output" == "6" || "$output" == "7" ]]
}

@test "_venice:_reset-wait returns empty when reset is in the past (stale)" {
  local past
  past=$(($(date +%s) - 30))
  printf 'HTTP/1.1 429\r\nx-ratelimit-reset-requests: %s\r\n\r\n' "$past" > "${BATS_TEST_TMPDIR}/h"
  run _venice:_reset-wait "${BATS_TEST_TMPDIR}/h"
  is "$output" ""
}

@test "_venice:_reset-wait caps at _VENICE_MAX_RESET_WAIT" {
  local far_future
  far_future=$(($(date +%s) + 9999))
  printf 'HTTP/1.1 429\r\nx-ratelimit-reset-requests: %s\r\n\r\n' "$far_future" > "${BATS_TEST_TMPDIR}/h"
  run _venice:_reset-wait "${BATS_TEST_TMPDIR}/h"
  is "$output" "60"
}

@test "_venice:_reset-wait is case-insensitive on the header name" {
  local future
  future=$(($(date +%s) + 5))
  printf 'HTTP/1.1 429\r\nX-RateLimit-Reset-Requests: %s\r\n\r\n' "$future" > "${BATS_TEST_TMPDIR}/h"
  run _venice:_reset-wait "${BATS_TEST_TMPDIR}/h"
  [[ "$output" == "4" || "$output" == "5" ]]
}

@test "_venice:_reset-wait rejects a non-numeric value" {
  printf 'HTTP/1.1 429\r\nx-ratelimit-reset-requests: soon\r\n\r\n' > "${BATS_TEST_TMPDIR}/h"
  run _venice:_reset-wait "${BATS_TEST_TMPDIR}/h"
  is "$output" ""
}

# ---------------------------------------------------------------------------
# venice:curl honors x-ratelimit-reset-requests on 429
#
# We can't directly assert the sleep duration (sleep is stubbed to a
# noop), but we can prove the wait calculation went through the reset
# header path by capturing what venice:curl would have slept on. Replace
# sleep with a function that records its argument, and assert it.
# ---------------------------------------------------------------------------

# Install a multi-response curl stub that ALSO writes per-attempt headers.
# Pass triples of "STATUS|HEADERS|BODY".
install_multi_curl_stub_with_headers() {
  local counter_file="${BATS_TEST_TMPDIR}/curl-attempt.counter"
  printf '0' > "$counter_file"

  local i=1
  local triple
  for triple in "$@"; do
    local status="${triple%%|*}"
    local rest="${triple#*|}"
    local headers="${rest%%|*}"
    local body="${rest#*|}"
    printf '%s' "$status" > "${BATS_TEST_TMPDIR}/curl-response.status.${i}"
    printf '%s' "$body" > "${BATS_TEST_TMPDIR}/curl-response.body.${i}"
    # Reconstruct CRLF line endings from literal \r\n in the input
    printf '%b' "$headers" > "${BATS_TEST_TMPDIR}/curl-response.headers.${i}"
    i=$((i + 1))
  done

  make_stub curl "$(
    cat << STUB
#!/usr/bin/env bash
counter_file='${BATS_TEST_TMPDIR}/curl-attempt.counter'
n=\$(cat "\$counter_file")
n=\$((n + 1))
printf '%s' "\$n" > "\$counter_file"

body_file=""
headers_file=""
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    -o) body_file="\$2"; shift 2 ;;
    -D) headers_file="\$2"; shift 2 ;;
    *) shift ;;
  esac
done

body_src='${BATS_TEST_TMPDIR}/curl-response.body.'"\${n}"
status_src='${BATS_TEST_TMPDIR}/curl-response.status.'"\${n}"
headers_src='${BATS_TEST_TMPDIR}/curl-response.headers.'"\${n}"
[[ -n "\$body_file" && -f "\$body_src" ]] && cat "\$body_src" > "\$body_file"
[[ -n "\$headers_file" && -f "\$headers_src" ]] && cat "\$headers_src" > "\$headers_file"
cat "\$status_src"
STUB
  )" > /dev/null

  prepend_stub_path
}

@test "venice:curl uses x-ratelimit-reset-requests when retrying on 429" {
  local future
  future=$(($(date +%s) + 5))

  install_multi_curl_stub_with_headers \
    "429|HTTP/1.1 429\r\nx-ratelimit-reset-requests: ${future}\r\n\r\n|{\"err\":\"slow\"}" \
    "200||{\"ok\":true}"
  export SCRATCH_VENICE_MAX_ATTEMPTS=3

  run --separate-stderr venice:curl GET /models
  is "$status" 0
  is "$output" '{"ok":true}'
  # The retry warning's wait value should be 4 or 5 (the reset window),
  # NOT the log10 backoff value (2 for attempt 1).
  [[ "$stderr" == *"retrying in 4s"* || "$stderr" == *"retrying in 5s"* ]]
}

@test "venice:curl falls back to log10 backoff when 429 has no reset header" {
  install_multi_curl_stub_with_headers \
    "429|HTTP/1.1 429\r\ncontent-type: application/json\r\n\r\n|{\"err\":\"slow\"}" \
    "200||{\"ok\":true}"
  export SCRATCH_VENICE_MAX_ATTEMPTS=3

  run --separate-stderr venice:curl GET /models
  is "$status" 0
  # Attempt 1 fallback is _venice:_backoff-seconds 1 = 2
  [[ "$stderr" == *"retrying in 2s"* ]]
}

@test "venice:curl falls back to log10 backoff when 429 reset is stale" {
  local past
  past=$(($(date +%s) - 30))
  install_multi_curl_stub_with_headers \
    "429|HTTP/1.1 429\r\nx-ratelimit-reset-requests: ${past}\r\n\r\n|{\"err\":\"slow\"}" \
    "200||{\"ok\":true}"
  export SCRATCH_VENICE_MAX_ATTEMPTS=3

  run --separate-stderr venice:curl GET /models
  is "$status" 0
  [[ "$stderr" == *"retrying in 2s"* ]]
}
