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

  printf '%d' "$seconds"
}

export -f _venice:_backoff-seconds

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
# Transient errors (429 rate-limited, 503 at capacity, 504 timeout) are
# retried up to SCRATCH_VENICE_MAX_ATTEMPTS times (default 3) with a
# log10 backoff sleep between attempts. Each retry logs a warning to
# stderr so the caller knows what's happening during the pause.
#
# Non-retryable errors (401, 402, 415, other 4xx) die immediately with
# a user-targeted message. Retries exhausted dies with a message that
# says how many attempts were made.
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
  local body_content
  local status_code
  local wait_s
  local -a curl_args

  key="$(venice:api-key)"
  url="$(venice:base-url)${path}"
  body_file="$(mktemp -t venice-curl.XXXXXX)"

  # -sS: silent progress, show errors. -o: body to file. -w: status to stdout.
  curl_args=(
    -sS
    -X "$method"
    -H "Authorization: Bearer ${key}"
    -H "Content-Type: application/json"
    -H "Accept: application/json"
    -o "$body_file"
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
    # Fresh file each iteration - previous body contents would confuse
    # a retry that returns a different status.
    : > "$body_file"

    if [[ -n "$body" ]]; then
      if ! status_code="$(printf '%s' "$body" | curl "${curl_args[@]}" -d @- "$url" 2>&1)"; then
        local err="$status_code"
        rm -f "$body_file"
        die "venice: curl failed for $method $path: $err"
      fi
    else
      if ! status_code="$(curl "${curl_args[@]}" "$url" 2>&1)"; then
        local err="$status_code"
        rm -f "$body_file"
        die "venice: curl failed for $method $path: $err"
      fi
    fi

    # Success - return the body and break out
    if [[ "$status_code" =~ ^2 ]]; then
      body_content="$(cat "$body_file")"
      rm -f "$body_file"
      printf '%s' "$body_content"
      return 0
    fi

    # Transient errors are retryable if we still have attempts left
    case "$status_code" in
      429 | 503 | 504)
        if ((attempt < max_attempts)); then
          wait_s="$(_venice:_backoff-seconds "$attempt")"
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
    rm -f "$body_file"

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
