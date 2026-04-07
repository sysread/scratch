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

has-commands curl jq

#-------------------------------------------------------------------------------
# Constants
#
# Base URL is hard-coded. If Venice ever moves the API, change it here.
# No env var override; tests that need a different URL override venice:curl
# as a bash function or stub curl itself.
#-------------------------------------------------------------------------------
_VENICE_BASE_URL="https://api.venice.ai/api/v1"

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
# On known Venice error codes (401, 402, 429, 503, 504), dies with a
# user-targeted message explaining what happened.
# On other non-2xx codes, dies with the code and the response body.
#-------------------------------------------------------------------------------
venice:curl() {
  local method="$1"
  local path="$2"
  local body="${3:-}"

  local key
  local url
  local body_file
  local body_content
  local status_code
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

  # Pipe the body via stdin when present, to avoid argv length limits.
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

  body_content="$(cat "$body_file")"
  rm -f "$body_file"

  case "$status_code" in
    2*)
      printf '%s' "$body_content"
      return 0
      ;;
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
      die "venice: rate limited (429). Wait and retry."
      ;;
    503)
      die "venice: model at capacity (503). Try a different model or retry."
      ;;
    504)
      die "venice: request timed out (504). For long requests, use streaming (not yet supported here)."
      ;;
    *)
      die "venice: ${method} ${path} returned ${status_code}: ${body_content}"
      ;;
  esac
}

export -f venice:curl
