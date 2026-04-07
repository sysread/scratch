#!/usr/bin/env bash

#-------------------------------------------------------------------------------
# Venice models: registry + profiles
#
# This file contains two related but distinct concept groups, namespaced
# to make the distinction visible at every call site:
#
#   1. Model registry (model:*)
#      The cached, validated copy of Venice's GET /models response.
#      This is the canonical truth about what models exist and what
#      they support. Functions: model:fetch, model:list, model:get,
#      model:exists, model:jq, model:cache-path.
#
#   2. Model profiles (model:profile:*)
#      Our internal "use this model in this configuration for this role"
#      definitions, sourced from data/models.json (repo-internal config,
#      not user settings). Profiles reference registry models and are
#      validated against them. Functions: model:profile:list,
#      model:profile:resolve, model:profile:model, model:profile:extras,
#      model:profile:exists, model:profile:validate.
#
# The two groups live in one file because they are tightly coupled
# (profile validation requires registry data) and small enough that
# splitting would add directory boilerplate without commensurate clarity
# gain. The double-colon namespace conveys the relationship without
# forcing it into the filesystem.
#
# REGISTRY DETAILS
#
# The cache is the raw response from GET /models?type=all, stored at
# ~/.config/scratch/venice/models.json. All registry read functions
# lazy-load the cache: if it is missing, they trigger a fetch before
# proceeding.
#
# Lazy loading means first use from a fresh install "just works" - the
# first lookup pulls the list from Venice. Cache refresh is always
# explicit: call model:fetch to re-pull. There is no TTL; stale entries
# persist until the user asks.
#
# PROFILE DETAILS
#
# Profiles live in data/models.json (tracked in the repo). The file has
# two top-level groups: "base" (smart, balanced, fast) and "variants"
# (coding, web, etc.) which each "extends" a base. Profile resolution
# does a recursive deep-merge so a variant inherits its base's params
# and venice_parameters, with variant-specific values taking precedence.
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
# model:exists ID
#
# Return 0 if ID exists in the cached model list, 1 otherwise. Silent;
# suitable for use in conditionals. Lazy-loads the cache if missing.
#
# Note: this is an existence check, not "validation" in any deeper sense -
# it does not verify capabilities or features. Profile validation lives
# under model:profile:validate.
#-------------------------------------------------------------------------------
model:exists() {
  local id="$1"
  local cache
  local found

  _model:ensure-cache
  cache="$(model:cache-path)"

  found="$(jq -r --arg id "$id" '.data[] | select(.id == $id) | .id' "$cache")"

  [[ -n "$found" ]]
}

export -f model:exists

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

  # Check existence first so the error message is clear, instead of
  # getting jq's null-output behavior for missing models.
  if ! model:exists "$id"; then
    die "model: not found: $id (try: model:fetch to refresh the cache)"
  fi

  result="$(jq -r --arg id "$id" ".data[] | select(.id == \$id) | $expr" "$cache")"
  printf '%s\n' "$result"
}

export -f model:jq
