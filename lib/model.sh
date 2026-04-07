#!/usr/bin/env bash

#-------------------------------------------------------------------------------
# Venice model registry
#
# Caches the Venice model list locally and provides lookup + validation.
# The cache is the raw response from GET /models?type=all, stored at
# ~/.config/scratch/venice/models.json. All read functions lazy-load the
# cache: if it is missing, they trigger a fetch before proceeding.
#
# Lazy loading means first use from a fresh install "just works" - the
# first validation or lookup pulls the list from Venice. It also means
# network errors surface at read time, which is usually the right place
# to deal with them (the caller is about to act on the result).
#
# Cache refresh is always explicit: call model:fetch to re-pull. There is
# no TTL; stale entries persist until the user asks.
#-------------------------------------------------------------------------------

[[ "${_INCLUDED_MODEL:-}" == "1" ]] && return 0
_INCLUDED_MODEL=1

_MODEL_SCRIPTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source-path=SCRIPTDIR/lib
# shellcheck disable=SC1091
{
  source "$_MODEL_SCRIPTDIR/base.sh"
  source "$_MODEL_SCRIPTDIR/venice.sh"
}

has-commands jq

#-------------------------------------------------------------------------------
# model:cache-path
#
# Print the absolute path to the cached model list. Resolves under
# venice:config-dir so tests running with an isolated HOME get an isolated
# cache path automatically.
#-------------------------------------------------------------------------------
model:cache-path() {
  printf '%s/models.json' "$(venice:config-dir)"
}

export -f model:cache-path

#-------------------------------------------------------------------------------
# model:fetch
#
# Pull the full model list from Venice and write it atomically to the cache.
# The atomic write (tmp file + mv) ensures a failed fetch never leaves a
# partially-written cache file behind.
#
# Always requests ?type=all so one fetch populates everything.
#-------------------------------------------------------------------------------
model:fetch() {
  local response
  local cache
  local tmp

  response="$(venice:curl GET '/models?type=all')"

  cache="$(model:cache-path)"
  tmp="${cache}.tmp"

  printf '%s' "$response" > "$tmp"
  mv "$tmp" "$cache"
}

export -f model:fetch

#-------------------------------------------------------------------------------
# _model:ensure-cache
#
# (Private) Guarantee the cache exists. If missing, trigger a fetch.
# Called by every read function so callers do not have to remember.
#-------------------------------------------------------------------------------
_model:ensure-cache() {
  local cache
  cache="$(model:cache-path)"
  [[ -f "$cache" ]] || model:fetch
}

#-------------------------------------------------------------------------------
# model:list [TYPE]
#
# Print the ids of all cached models, one per line, sorted. If TYPE is
# given, only models whose top-level .type field matches are printed
# (e.g. "text", "image", "embedding").
#-------------------------------------------------------------------------------
model:list() {
  local type="${1:-}"
  local cache

  _model:ensure-cache
  cache="$(model:cache-path)"

  if [[ -z "$type" ]]; then
    jq -r '.data[].id' "$cache" | sort
  else
    jq -r --arg t "$type" '.data[] | select(.type == $t) | .id' "$cache" | sort
  fi
}

export -f model:list

#-------------------------------------------------------------------------------
# model:get ID
#
# Print the full JSON object for a single model by id. Dies if not found.
#-------------------------------------------------------------------------------
model:get() {
  local id="$1"
  local cache
  local result

  _model:ensure-cache
  cache="$(model:cache-path)"

  result="$(jq --arg id "$id" '.data[] | select(.id == $id)' "$cache")"

  if [[ -z "$result" ]]; then
    die "model: not found: $id (try: model:fetch to refresh the cache)"
  fi

  printf '%s\n' "$result"
}

export -f model:get

#-------------------------------------------------------------------------------
# model:validate ID
#
# Return 0 if ID exists in the cached model list, 1 otherwise. Silent;
# suitable for use in conditionals. Lazy-loads the cache if missing.
#-------------------------------------------------------------------------------
model:validate() {
  local id="$1"
  local cache
  local found

  _model:ensure-cache
  cache="$(model:cache-path)"

  found="$(jq -r --arg id "$id" '.data[] | select(.id == $id) | .id' "$cache")"

  [[ -n "$found" ]]
}

export -f model:validate

#-------------------------------------------------------------------------------
# model:jq ID JQ_EXPR
#
# Run an arbitrary jq expression against a single model's object and print
# the result. The expression is rooted at the model object, so you can
# write ".model_spec.capabilities.supportsFunctionCalling" without prefixing.
#
# Returns jq's -r (raw) output, so strings come out unquoted. Dies if the
# model is not found.
#
# Example:
#   model:jq llama-3-large '.model_spec.capabilities.supportsFunctionCalling // false'
#-------------------------------------------------------------------------------
model:jq() {
  local id="$1"
  local expr="$2"
  local cache
  local result

  _model:ensure-cache
  cache="$(model:cache-path)"

  # Validate existence first so the error message is clear, instead of
  # getting jq's null-output behavior for missing models.
  if ! model:validate "$id"; then
    die "model: not found: $id (try: model:fetch to refresh the cache)"
  fi

  result="$(jq -r --arg id "$id" ".data[] | select(.id == \$id) | $expr" "$cache")"
  printf '%s\n' "$result"
}

export -f model:jq
