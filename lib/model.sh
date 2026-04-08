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

#===============================================================================
# MODEL PROFILES (model:profile:*)
#
# See the file header for the conceptual split. Profiles are sourced from
# data/models.json (repo-internal config, not user settings) and resolved
# via recursive object merge (jq `*`) so variants inherit their base.
#===============================================================================

#-------------------------------------------------------------------------------
# Param-to-capability mapping for profile validation.
#
# Top-level params: each key is a chat completion request parameter name,
# the value is a comma-separated list of model capability flags that must
# all be true for the model to support that parameter.
#
# Venice-specific params: same shape, but the keys are venice_parameters
# field names.
#
# Adding a new mapping here teaches model:profile:validate about a new
# parameter without changing the validation logic.
#-------------------------------------------------------------------------------
declare -gA _MODEL_PARAM_CAPABILITIES=(
  [reasoning_effort]="supportsReasoning,supportsReasoningEffort"
  [tools]="supportsFunctionCalling"
  [tool_choice]="supportsFunctionCalling"
  [logprobs]="supportsLogProbs"
)

declare -gA _MODEL_VENICE_PARAM_CAPABILITIES=(
  [enable_web_search]="supportsWebSearch"
  [enable_web_scraping]="supportsWebSearch"
  [enable_web_citations]="supportsWebSearch"
)

#-------------------------------------------------------------------------------
# model:profile:data-path
#
# Print the absolute path to the profile data file (data/models.json).
# Resolves relative to this library's location, so it works regardless of
# where the caller invoked it from.
#-------------------------------------------------------------------------------
model:profile:data-path() {
  printf '%s/../data/models.json\n' "$_MODEL_SCRIPTDIR"
}

export -f model:profile:data-path

#-------------------------------------------------------------------------------
# model:profile:list
#
# Print all profile names (base + variants), sorted, one per line.
#-------------------------------------------------------------------------------
model:profile:list() {
  local data_path
  data_path="$(model:profile:data-path)"
  if [[ ! -f "$data_path" ]]; then
    die "model:profile: data file missing: $data_path"
    return 1
  fi

  jq -r '(.base // {} | keys[]), (.variants // {} | keys[])' "$data_path" | sort
}

export -f model:profile:list

#-------------------------------------------------------------------------------
# model:profile:exists NAME
#
# Return 0 if NAME is defined as either a base or a variant, 1 otherwise.
# Silent; suitable for use in conditionals.
#-------------------------------------------------------------------------------
model:profile:exists() {
  local name="$1"
  local data_path
  data_path="$(model:profile:data-path)"
  [[ -f "$data_path" ]] || return 1

  # Merge base and variants into one keyspace and check via has(). Returns
  # boolean true/false; jq -e exits 0 for true and 1 for false.
  jq -e --arg n "$name" '((.base // {}) + (.variants // {})) | has($n)' "$data_path" > /dev/null 2>&1
}

export -f model:profile:exists

#-------------------------------------------------------------------------------
# model:profile:resolve NAME
#
# Print the fully-resolved JSON for a profile. For a base profile, this is
# the base entry as-is. For a variant, the base is recursively resolved
# first and then merged with the variant's overrides via jq's `*`
# operator (deep recursive merge).
#
# The resolved object always has these top-level fields:
#   model              - the model id string
#   params             - object of top-level chat completion params
#   venice_parameters  - object of venice-specific params (may be empty)
#
# Variants extending other variants work transitively because resolve
# calls itself recursively to resolve the parent. Cycles are not detected
# (would stack overflow); don't write cyclic profile definitions.
#-------------------------------------------------------------------------------
model:profile:resolve() {
  local name="$1"
  local data_path
  local data
  local entry
  local extends
  local base_resolved

  data_path="$(model:profile:data-path)"
  if [[ ! -f "$data_path" ]]; then
    die "model:profile: data file missing: $data_path"
    return 1
  fi

  data="$(cat "$data_path")"

  # Try base first
  entry="$(jq -c --arg n "$name" '.base[$n] // empty' <<< "$data")"
  if [[ -n "$entry" ]]; then
    # Normalize: ensure params and venice_parameters are present, even if empty
    jq -c '. + {params: (.params // {}), venice_parameters: (.venice_parameters // {})}' <<< "$entry"
    return 0
  fi

  # Try variant
  entry="$(jq -c --arg n "$name" '.variants[$n] // empty' <<< "$data")"
  if [[ -z "$entry" ]]; then
    die "model:profile: not found: $name"
    return 1
  fi

  extends="$(jq -r '.extends // empty' <<< "$entry")"
  if [[ -z "$extends" ]]; then
    die "model:profile: variant '$name' missing 'extends' field"
    return 1
  fi

  base_resolved="$(model:profile:resolve "$extends")" || return 1

  # Recursive merge: base * variant. The variant's keys win where they
  # collide, and nested objects (params, venice_parameters) are merged
  # rather than replaced. The 'extends' field is dropped from the output.
  jq -c -n \
    --argjson base "$base_resolved" \
    --argjson var "$entry" \
    '$base * ($var | del(.extends) | . + {params: (.params // {}), venice_parameters: (.venice_parameters // {})})'
}

export -f model:profile:resolve

#-------------------------------------------------------------------------------
# model:profile:model NAME
#
# Convenience: print just the .model field of the resolved profile.
#-------------------------------------------------------------------------------
model:profile:model() {
  local name="$1"
  model:profile:resolve "$name" | jq -r '.model'
}

export -f model:profile:model

#-------------------------------------------------------------------------------
# model:profile:extras NAME
#
# Print the JSON object that should be passed as chat:completion's third
# argument (EXTRA_JSON). The shape is the resolved profile's params
# flattened to top-level, with venice_parameters kept as a nested object.
#
# Example output:
#   {"reasoning_effort":"medium","venice_parameters":{"enable_web_search":"auto"}}
#
# Empty venice_parameters are omitted from the output entirely so the
# request body stays clean.
#-------------------------------------------------------------------------------
model:profile:extras() {
  local name="$1"
  model:profile:resolve "$name" | jq -c '
    .params + (
      if (.venice_parameters | length) > 0
      then {venice_parameters: .venice_parameters}
      else {}
      end
    )
  '
}

export -f model:profile:extras

#-------------------------------------------------------------------------------
# model:profile:validate NAME
#
# Validate that a profile is internally consistent against the Venice
# model registry. Three checks, in order:
#
#   1. The profile exists in data/models.json.
#   2. The model id named by the profile exists in the registry cache.
#      (Lazy-loads the registry if missing.)
#   3. Every param and venice_parameter in the resolved profile is
#      supported by the model's declared capabilities.
#
# On failure, dies with a message naming the specific problem.
# On success, returns 0 silently.
#
# Capability mapping comes from _MODEL_PARAM_CAPABILITIES and
# _MODEL_VENICE_PARAM_CAPABILITIES at the top of the profile section.
# Unknown params (not in the mapping) are skipped - we cannot validate
# what we do not know about, and Venice's API will reject them at
# request time anyway.
#
# Top-level tooling-metadata fields like `chars_per_token` are not
# validated either: they never reach the Venice API, they live entirely
# inside scratch (consumed by lib/accumulator.sh and similar), and the
# validator only walks .params and .venice_parameters. See data/models.md
# for the full schema reference.
#-------------------------------------------------------------------------------
model:profile:validate() {
  local name="$1"

  # 1. Profile exists in our config?
  if ! model:profile:exists "$name"; then
    die "model:profile: not found: $name"
    return 1
  fi

  local resolved
  resolved="$(model:profile:resolve "$name")" || return 1

  local model_id
  model_id="$(jq -r '.model' <<< "$resolved")"

  # 2. Model exists in the registry?
  if ! model:exists "$model_id"; then
    die "model:profile: '$name' references unknown model '$model_id' (run: model:fetch to refresh the registry)"
    return 1
  fi

  # 3. For each param in the profile, check the corresponding capability.
  #
  # Capability failures don't abort early - we set a `failed` flag, finish
  # walking the params (so the user sees ALL the problems at once instead
  # of fixing them one by one), then return 1 at the end if anything failed.
  local param
  local caps
  local cap
  local cap_value
  local failed=0

  while IFS= read -r param; do
    [[ -z "$param" ]] && continue
    caps="${_MODEL_PARAM_CAPABILITIES[$param]:-}"
    [[ -z "$caps" ]] && continue # unknown param, skip

    while IFS= read -r cap; do
      [[ -z "$cap" ]] && continue
      cap_value="$(model:jq "$model_id" ".model_spec.capabilities.${cap} // false")"
      if [[ "$cap_value" != "true" ]]; then
        warn "model:profile: '$name' uses param '$param' which requires capability '$cap', but model '$model_id' does not support it"
        failed=1
      fi
    done < <(printf '%s\n' "${caps//,/$'\n'}")
  done < <(jq -r '.params | keys[]' <<< "$resolved")

  # Same for venice_parameters
  while IFS= read -r param; do
    [[ -z "$param" ]] && continue
    caps="${_MODEL_VENICE_PARAM_CAPABILITIES[$param]:-}"
    [[ -z "$caps" ]] && continue

    while IFS= read -r cap; do
      [[ -z "$cap" ]] && continue
      cap_value="$(model:jq "$model_id" ".model_spec.capabilities.${cap} // false")"
      if [[ "$cap_value" != "true" ]]; then
        warn "model:profile: '$name' uses venice_parameters.$param which requires capability '$cap', but model '$model_id' does not support it"
        failed=1
      fi
    done < <(printf '%s\n' "${caps//,/$'\n'}")
  done < <(jq -r '.venice_parameters | keys[]' <<< "$resolved")

  if ((failed != 0)); then
    return 1
  fi

  return 0
}

export -f model:profile:validate
