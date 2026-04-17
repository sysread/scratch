#!/usr/bin/env bash

#-------------------------------------------------------------------------------
# Venice API primitives
#
# Shared infrastructure for talking to https://api.venice.ai/api/v1.
# This library is the foundation for lib/model.sh and lib/chat.sh - it owns
# API key resolution, the base URL, and the curl wrapper that injects auth
# and translates Venice-specific HTTP status codes into useful errors.
#
# Key resolution: SCRATCH_VENICE_API_KEY takes precedence over VENICE_API_KEY.
# The SCRATCH_ prefix lets users keep a project-scoped key without overriding
# their general-purpose VENICE_API_KEY.
#
# Venice is OpenAI-compatible with extensions. See:
#   https://docs.venice.ai/api-reference/api-spec
#   https://docs.venice.ai/api-reference/endpoint/chat/completions
#-------------------------------------------------------------------------------

[[ "${_INCLUDED_VENICE:-}" == "1" ]] && return 0
_INCLUDED_VENICE=1

_VENICE_SCRIPTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source-path=SCRIPTDIR/lib
# shellcheck disable=SC1091
source "$_VENICE_SCRIPTDIR/base.sh"

has-commands curl jq bc
uses-secret-env-vars SCRATCH_VENICE_API_KEY VENICE_API_KEY
uses-env-vars SCRATCH_VENICE_DISABLE_JITTER SCRATCH_VENICE_MAX_ATTEMPTS
describe-env-var SCRATCH_VENICE_API_KEY "Venice API key (preferred over VENICE_API_KEY)"
describe-env-var VENICE_API_KEY "Venice API key (fallback if SCRATCH_VENICE_API_KEY unset)"
describe-env-var SCRATCH_VENICE_DISABLE_JITTER "disable retry backoff jitter (test use only)"
describe-env-var SCRATCH_VENICE_MAX_ATTEMPTS "max retries on transient Venice errors (default 3)"

#-------------------------------------------------------------------------------
# Constants
#
# Base URL is hard-coded. If Venice ever moves the API, change it here.
# No env var override; tests that need a different URL override venice:curl
# as a bash function or stub curl itself.
#-------------------------------------------------------------------------------
_VENICE_BASE_URL="https://api.venice.ai/api/v1"

# Backoff base - multiplier for the log10 backoff curve. Higher values
# give longer waits per attempt. See _venice:_backoff-seconds below.
_VENICE_BACKOFF_BASE=2

# Cap on reset-derived waits. When a 429 carries an x-ratelimit-reset-requests
# header, we honor it - but only up to this many seconds, so a misconfigured
# or malicious server can't pin us indefinitely. The fallback log10 curve
# kicks in for waits beyond the cap.
_VENICE_MAX_RESET_WAIT=60

#-------------------------------------------------------------------------------
# venice:api-key
#
# Print the Venice API key to stdout. Checks SCRATCH_VENICE_API_KEY first,
# then VENICE_API_KEY. Dies with a clear message if neither is set.
#-------------------------------------------------------------------------------
venice:api-key() {
  if [[ -n "${SCRATCH_VENICE_API_KEY:-}" ]]; then
    printf '%s' "$SCRATCH_VENICE_API_KEY"
    return 0
  fi

  if [[ -n "${VENICE_API_KEY:-}" ]]; then
    printf '%s' "$VENICE_API_KEY"
    return 0
  fi

  die "venice: no API key found. Set SCRATCH_VENICE_API_KEY or VENICE_API_KEY. Get one at https://venice.ai/settings/api"
}

export -f venice:api-key

#-------------------------------------------------------------------------------
# venice:base-url
#
# Print the Venice API base URL (no trailing slash). Callers append the
# endpoint path, e.g. "$(venice:base-url)/models".
#-------------------------------------------------------------------------------
venice:base-url() {
  printf '%s' "$_VENICE_BASE_URL"
}

export -f venice:base-url

#-------------------------------------------------------------------------------
# venice:config-dir
#
# Print the directory where scratch stores Venice-related files
# (cached model list, future credentials, etc.). Creates the directory if
# it does not exist. Resolves against $HOME, so tests running under
# helpers/run-tests get an isolated tmpdir automatically.
#-------------------------------------------------------------------------------
venice:config-dir() {
  local dir="${HOME}/.config/scratch/venice"
  mkdir -p "$dir"
  printf '%s' "$dir"
}

export -f venice:config-dir

#-------------------------------------------------------------------------------
# _venice:_backoff-seconds ATTEMPT
#
# (Private) Compute the number of seconds to sleep before retrying,
# using a log10 curve that self-caps. Returns whole seconds (rounded up).
#
# Formula: ceil(base * (1 + log10(attempt)))
#   where base defaults to _VENICE_BACKOFF_BASE (2).
#
# Curve properties at base=2:
#   attempt 1   ->  2s   (non-trivial first wait)
#   attempt 2   ->  3s
#   attempt 5   ->  4s
#   attempt 10  ->  4s
#   attempt 100 ->  6s
#   attempt 1000-> 8s
#
# The curve "ramps quickly but self-caps" - first retry is a real delay
# (not a fraction of a second), and even 1000 failures doesn't exceed 8s.
# Uses bc(1) because bash has no floating point and log10 needs it.
#
# A small uniform jitter (0..base/2 seconds) is added to break herd
# alignment when many parallel completions hit a 429 simultaneously.
# Without it, all N retries wake at the exact same instant and
# re-collide. Jitter is added AFTER the floor so the floor still holds.
# Disable the jitter (for deterministic tests) by setting
# SCRATCH_VENICE_DISABLE_JITTER=1.
#-------------------------------------------------------------------------------
_venice:_backoff-seconds() {
  local attempt="$1"
  local seconds

  # log10(x) = l(x) / l(10) via bc -l. Compute raw at scale=4, then
  # add <1 and divide by 1 at scale=0 to get ceiling in one bc call.
  seconds="$(
    bc -l << EOF
scale = 4
raw = ${_VENICE_BACKOFF_BASE} * (1 + l($attempt) / l(10))
scale = 0
(raw + 0.9999) / 1
EOF
  )"

  # Floor at 1 second. log10(1) = 0, so attempt 1 gives base=2 naturally,
  # but defensive in case someone lowers the base below 1.
  ((seconds < 1)) && seconds=1

  # Apply jitter unless explicitly disabled. With base=2 the jitter is
  # 0..1; the curve becomes:
  #   attempt 1   -> 2-3s
  #   attempt 10  -> 4-5s
  #   attempt 100 -> 6-7s
  if [[ "${SCRATCH_VENICE_DISABLE_JITTER:-}" != "1" ]]; then
    local jitter
    jitter=$((RANDOM % (_VENICE_BACKOFF_BASE / 2 + 1)))
    seconds=$((seconds + jitter))
  fi

  printf '%d' "$seconds"
}

export -f _venice:_backoff-seconds

#-------------------------------------------------------------------------------
# _venice:_reset-wait HEADERS_FILE
#
# (Private) Read x-ratelimit-reset-requests from a curl header dump and
# return the number of seconds to wait until the rate-limit window resets.
#
# Venice documents this header as a unix timestamp (seconds). On 429
# specifically, it is the canonical signal of "when you may try again";
# our log10 backoff is a fallback for when the header is absent or stale.
#
# Returns:
#   - whole seconds (>= 1) when the header is present and the reset is in
#     the future, capped at _VENICE_MAX_RESET_WAIT to defend against a
#     server pinning us
#   - empty string when the header is missing, malformed, or already in
#     the past
#
# Header matching is case-insensitive (HTTP header names are
# case-insensitive per RFC 7230) and tolerates leading whitespace and
# CRLF line endings.
#-------------------------------------------------------------------------------
_venice:_reset-wait() {
  local headers_file="$1"
  local raw
  local reset_ts
  local now
  local wait_s

  [[ -f "$headers_file" ]] || return 0

  # grep -i for case-insensitive header name; cut to grab the value;
  # tr -d to strip CR (curl emits CRLF line endings) and whitespace.
  raw="$(grep -i '^x-ratelimit-reset-requests:' "$headers_file" 2> /dev/null | tail -n 1 | cut -d: -f2- | tr -d ' \r\n')"
  [[ -n "$raw" ]] || return 0

  # Must be all digits to be a unix timestamp. Reject anything else.
  [[ "$raw" =~ ^[0-9]+$ ]] || return 0
  reset_ts="$raw"

  now="$(date +%s)"
  wait_s=$((reset_ts - now))

  # Header is stale (reset already passed) - let the caller fall back.
  ((wait_s > 0)) || return 0

  # Cap to defend against a misconfigured or hostile server.
  ((wait_s > _VENICE_MAX_RESET_WAIT)) && wait_s="$_VENICE_MAX_RESET_WAIT"

  printf '%d' "$wait_s"
}

export -f _venice:_reset-wait

#-------------------------------------------------------------------------------
# _venice:_is-context-overflow BODY
#
# (Private) Return 0 if BODY is a Venice context-overflow error, 1 otherwise.
#
# Venice uses the OpenAI-compatible error envelope for context-window
# violations:
#
#   {
#     "error": {
#       "message": "This model's maximum context length is ...",
#       "type": "invalid_request_error",
#       "param": "messages",
#       "code": "context_length_exceeded"
#     }
#   }
#
# We match exactly on .error.code so unrelated 400s with different bodies
# (malformed JSON, bad model id, etc.) still die normally. The only
# field we trust is .error.code; we deliberately ignore .error.type and
# the message text because both are friendlier to refactor than codes.
#
# Used by venice:curl's 400 dispatch to translate this specific error
# into exit code 9, which the accumulator catches to drive its
# reactive shave-and-retry backoff.
#-------------------------------------------------------------------------------
_venice:_is-context-overflow() {
  local body="$1"
  # Normalize jq's exit code: jq -e returns 4/5 on parse errors and 1
  # on a falsy result. The helper's contract is binary (0 = matched,
  # 1 = anything else), so collapse the failure cases here rather than
  # leaking jq's internal codes.
  if jq -e '.error.code == "context_length_exceeded"' <<< "$body" > /dev/null 2>&1; then
    return 0
  fi
  return 1
}

export -f _venice:_is-context-overflow

#-------------------------------------------------------------------------------
# venice:curl METHOD PATH [BODY]
#
# Make an authenticated request to the Venice API and print the response
# body to stdout on success. Dies with a clear message on error.
#
# METHOD   HTTP method (GET, POST, etc.)
# PATH     API path starting with /, e.g. /models or /chat/completions
# BODY     optional JSON request body; piped to curl via -d @- so there
#          is no argv length limit
#
# On 2xx, prints the response body and returns 0.
#
# Transient errors (429 rate-limited, 500 server error, 503 at capacity,
# 504 timeout) are retried up to SCRATCH_VENICE_MAX_ATTEMPTS times
# (default 3). For 429, the wait honors Venice's
# x-ratelimit-reset-requests header (capped at _VENICE_MAX_RESET_WAIT
# seconds) when present; otherwise, and for the other transient codes,
# we use a log10 backoff curve. Each retry logs a warning to stderr so
# the caller knows what's happening during the pause.
#
# Non-retryable errors (401, 402, 415, other 4xx) die immediately with
# a user-targeted message. Retries exhausted dies with a message that
# says how many attempts were made.
#
# Special exit code 9: a 400 response whose body is Venice's
# context-overflow error (.error.code == "context_length_exceeded")
# returns exit code 9 instead of dying. The body is written to stderr
# so callers can log it. This lets the accumulator catch context
# overflow and drive a reactive shave-and-retry backoff. All other
# 400s still die immediately.
#
# Tests that want to exercise retry paths without actually sleeping
# can override sleep as a bash function:
#
#   sleep() { :; }
#   export -f sleep
#-------------------------------------------------------------------------------
venice:curl() {
  local method="$1"
  local path="$2"
  local body="${3:-}"

  local max_attempts="${SCRATCH_VENICE_MAX_ATTEMPTS:-3}"
  local attempt=1
  local key
  local url
  local body_file
  local headers_file
  local body_content
  local status_code
  local wait_s
  local reset_wait
  local -a curl_args

  key="$(venice:api-key)"
  url="$(venice:base-url)${path}"
  body_file="$(mktemp -t venice-curl.XXXXXX)"
  headers_file="$(mktemp -t venice-curl-h.XXXXXX)"

  # -sS: silent progress, show errors. -o: body to file. -D: headers
  # to file (so we can read the rate-limit headers Venice returns).
  # -w: status to stdout.
  curl_args=(
    -sS
    -X "$method"
    -H "Authorization: Bearer ${key}"
    -H "Content-Type: application/json"
    -H "Accept: application/json"
    -o "$body_file"
    -D "$headers_file"
    -w '%{http_code}'
  )

  #-----------------------------------------------------------------------------
  # Retry loop
  #
  # One iteration = one HTTP attempt. A 2xx response breaks out with
  # success. A transient error (429/503/504) sleeps and retries if we
  # still have attempts left. Anything else dies immediately.
  #-----------------------------------------------------------------------------
  while :; do
    # Fresh files each iteration - previous body or headers would confuse
    # a retry that returns a different status.
    : > "$body_file"
    : > "$headers_file"

    if [[ -n "$body" ]]; then
      if ! status_code="$(printf '%s' "$body" | curl "${curl_args[@]}" -d @- "$url" 2>&1)"; then
        local err="$status_code"
        rm -f "$body_file" "$headers_file"
        die "venice: curl failed for $method $path: $err"
      fi
    else
      if ! status_code="$(curl "${curl_args[@]}" "$url" 2>&1)"; then
        local err="$status_code"
        rm -f "$body_file" "$headers_file"
        die "venice: curl failed for $method $path: $err"
      fi
    fi

    # Success - return the body and break out
    if [[ "$status_code" =~ ^2 ]]; then
      body_content="$(cat "$body_file")"
      rm -f "$body_file" "$headers_file"
      printf '%s' "$body_content"
      return 0
    fi

    # Transient errors are retryable if we still have attempts left.
    # Venice documents 429/500/503 as retryable. We also retry 504 (gateway
    # timeout) defensively - it isn't in their list, but a timed-out
    # request is by nature worth one more shot.
    case "$status_code" in
      429 | 500 | 503 | 504)
        if ((attempt < max_attempts)); then
          # On 429, prefer the server-provided reset timestamp from
          # x-ratelimit-reset-requests. It tells us exactly when the window
          # opens; sleeping less than that guarantees another 429. Fall
          # back to the log10 curve when the header is missing or stale.
          wait_s=""
          if [[ "$status_code" == "429" ]]; then
            reset_wait="$(_venice:_reset-wait "$headers_file")"
            [[ -n "$reset_wait" ]] && wait_s="$reset_wait"
          fi
          [[ -n "$wait_s" ]] || wait_s="$(_venice:_backoff-seconds "$attempt")"
          warn "venice: ${method} ${path} returned ${status_code}; retrying in ${wait_s}s (attempt ${attempt}/${max_attempts})"
          sleep "$wait_s"
          attempt=$((attempt + 1))
          continue
        fi
        ;;
    esac

    # Non-retryable, or retries exhausted. Read the body for the error
    # message and translate.
    body_content="$(cat "$body_file")"
    rm -f "$body_file" "$headers_file"

    # Context-overflow on 400 is a non-error from venice:curl's caller's
    # perspective: the accumulator wants to know about it so it can
    # shave the chunk and retry. Surface as exit code 9 with the body
    # on stderr; everything else still dies.
    if [[ "$status_code" == "400" ]] && _venice:_is-context-overflow "$body_content"; then
      printf '%s\n' "$body_content" >&2
      return 9
    fi

    case "$status_code" in
      401)
        die "venice: authentication failed (401). Check SCRATCH_VENICE_API_KEY or VENICE_API_KEY. If the key is correct, this model may be Pro-only."
        ;;
      402)
        die "venice: insufficient credits (402). Top up at https://venice.ai/settings/api"
        ;;
      415)
        die "venice: invalid content type (415). This is a bug in lib/venice.sh"
        ;;
      429)
        die "venice: rate limited (429); exhausted ${max_attempts} attempts. Wait and retry later."
        ;;
      500)
        die "venice: server error (500); exhausted ${max_attempts} attempts. Body: ${body_content}"
        ;;
      503)
        die "venice: model at capacity (503); exhausted ${max_attempts} attempts. Try a different model."
        ;;
      504)
        die "venice: request timed out (504); exhausted ${max_attempts} attempts. For long requests, use streaming (not yet supported here)."
        ;;
      *)
        die "venice: ${method} ${path} returned ${status_code}: ${body_content}"
        ;;
    esac
  done
}

export -f venice:curl
