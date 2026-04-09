#!/usr/bin/env bash

#-------------------------------------------------------------------------------
# Agent layer
#
# An agent in scratch is a self-contained directory under agents/ with three
# required files:
#
#   agents/<name>/spec.json    - metadata: name, description, optional
#                               input/output hints. Not executable.
#   agents/<name>/run          - the executable entrypoint; any language.
#                               Receives the user input on stdin and prints
#                               the final response to stdout. Stderr is logs.
#   agents/<name>/is-available - bash script. Two purposes:
#                               1. Runtime gate: exit 0 if the agent is usable
#                                  in the current environment, non-zero (with
#                                  reason on stderr) if not. May check env
#                                  vars, repo state, project context, edit
#                                  mode, etc. - not just dependencies.
#                               2. Dependency manifest: must source lib/base.sh
#                                  and call has-commands for any external
#                                  programs the agent or its libs need. The
#                                  doctor scanner picks up these declarations
#                                  textually and attributes them to "agent:<name>".
#
# Unlike tools (which the LLM calls during a chat completion), an agent is
# the unit of reusable LLM workflow. A simple agent might be a 5-line wrapper
# around chat:complete-with-tools via agent:simple-completion. A complex agent
# might orchestrate multiple phases: accumulate over a huge input, fan out
# parallel sub-completions via workers:run-parallel, synthesize the results,
# and branch on a structured-output boolean.
#
# The agent IS the run script. There is no JSON config that names a model or
# a system prompt - the run script picks both per-phase, freely. This is the
# main difference from the tool layer (where the spec.json IS the contract).
#
# Environment contract for agent run scripts:
#
#   stdin                = the user input
#   stdout               = the final response (plain text)
#   stderr               = logs / progress (use tui:info / tui:warn)
#
#   SCRATCH_AGENT_DIR    absolute path to agents/<name>/ (so the script can
#                        find sibling files - but prompts live under
#                        data/prompts/<name>/, not in the agent dir)
#   SCRATCH_HOME         absolute path to the scratch repo root (so the
#                        script can `source "$SCRATCH_HOME/lib/..."`)
#   SCRATCH_PROJECT      current project name from project:detect, only set
#                        if a project is detected
#   SCRATCH_PROJECT_ROOT current project root path, only set if detected
#   SCRATCH_AGENT_DEPTH  current recursion depth (incremented by agent:run
#                        before forking the child). Dies if the new depth
#                        exceeds SCRATCH_AGENT_MAX_DEPTH (default 8) so a
#                        runaway sub-agent chain burns out fast.
#-------------------------------------------------------------------------------

[[ "${_INCLUDED_AGENT:-}" == "1" ]] && return 0
_INCLUDED_AGENT=1

_AGENT_SCRIPTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source-path=SCRIPTDIR/lib
# shellcheck disable=SC1091
{
  source "$_AGENT_SCRIPTDIR/base.sh"
  source "$_AGENT_SCRIPTDIR/project.sh"
  source "$_AGENT_SCRIPTDIR/prompt.sh"
  source "$_AGENT_SCRIPTDIR/model.sh"
  source "$_AGENT_SCRIPTDIR/chat.sh"
  source "$_AGENT_SCRIPTDIR/tool.sh"
}

has-commands jq

#-------------------------------------------------------------------------------
# Globals (set by agent:available)
#
# Same pattern as the tool layer: stderr capture goes through a global so
# the function's return value can be the exit code.
#-------------------------------------------------------------------------------
# shellcheck disable=SC2034
_AGENT_AVAILABILITY_ERR=""

# Default recursion cap. Override via SCRATCH_AGENT_MAX_DEPTH in the env.
_AGENT_DEFAULT_MAX_DEPTH=8

#-------------------------------------------------------------------------------
# agent:agents-dir
#
# Print the absolute path to the agents directory. Honors SCRATCH_AGENTS_DIR
# for tests; defaults to <repo>/agents.
#-------------------------------------------------------------------------------
agent:agents-dir() {
  if [[ -n "${SCRATCH_AGENTS_DIR:-}" ]]; then
    printf '%s\n' "$SCRATCH_AGENTS_DIR"
  else
    printf '%s\n' "$(cd "$_AGENT_SCRIPTDIR/../agents" 2> /dev/null && pwd -P || echo "$_AGENT_SCRIPTDIR/../agents")"
  fi
}

export -f agent:agents-dir

#-------------------------------------------------------------------------------
# agent:list
#
# Print the names of all agents (sorted, one per line). An agent is a
# directory under agent:agents-dir that contains at least a spec.json file.
# Directories missing spec.json are silently skipped, which keeps test
# fixture setup easy.
#-------------------------------------------------------------------------------
agent:list() {
  local agents_dir
  local d
  local name

  agents_dir="$(agent:agents-dir)"
  [[ -d "$agents_dir" ]] || return 0

  for d in "$agents_dir"/*/; do
    [[ -d "$d" ]] || continue
    [[ -f "${d}spec.json" ]] || continue
    name="$(basename "$d")"
    printf '%s\n' "$name"
  done | sort
}

export -f agent:list

#-------------------------------------------------------------------------------
# agent:exists NAME
#
# Return 0 if agents/NAME/ has all three required files (spec.json, run,
# is-available). Return 1 otherwise. Silent. Does NOT check executable
# bits; that's the contract test's job at structural-validation time.
#-------------------------------------------------------------------------------
agent:exists() {
  local name="$1"
  local agents_dir
  agents_dir="$(agent:agents-dir)"

  [[ -f "${agents_dir}/${name}/spec.json" ]] || return 1
  [[ -f "${agents_dir}/${name}/run" ]] || return 1
  [[ -f "${agents_dir}/${name}/is-available" ]] || return 1
  return 0
}

export -f agent:exists

#-------------------------------------------------------------------------------
# agent:dir NAME
#
# Print the absolute path to agents/NAME/. Dies if the directory does not
# exist or is missing the required files.
#-------------------------------------------------------------------------------
agent:dir() {
  local name="$1"
  if ! agent:exists "$name"; then
    die "agent: not found: $name (expected agents/$name/ with spec.json + run + is-available)"
    return 1
  fi
  printf '%s\n' "$(agent:agents-dir)/$name"
}

export -f agent:dir

#-------------------------------------------------------------------------------
# agent:spec NAME
#
# Print the raw spec.json contents for NAME. Does not validate the JSON
# shape - that's the contract test's job. Dies if the agent doesn't exist.
#-------------------------------------------------------------------------------
agent:spec() {
  local name="$1"
  if ! agent:exists "$name"; then
    die "agent: not found: $name"
    return 1
  fi
  cat "$(agent:agents-dir)/$name/spec.json"
}

export -f agent:spec

#-------------------------------------------------------------------------------
# agent:available NAME
#
# Run agents/NAME/is-available with the env contract set up. Return its
# exit code. Stderr from the script is captured into _AGENT_AVAILABILITY_ERR
# (a global) for the caller to inspect on failure.
#
# Honors SCRATCH_AGENT_SKIP_AVAILABILITY=1 by always returning 0 without
# running anything. Useful in tests that don't want the gate.
#-------------------------------------------------------------------------------
agent:available() {
  local name="$1"
  local script
  local err_file
  local rc

  if [[ "${SCRATCH_AGENT_SKIP_AVAILABILITY:-}" == "1" ]]; then
    _AGENT_AVAILABILITY_ERR=""
    return 0
  fi

  if ! agent:exists "$name"; then
    _AGENT_AVAILABILITY_ERR="agent: not found: $name"
    return 1
  fi

  script="$(agent:agents-dir)/$name/is-available"

  err_file="$(mktemp -t scratch-agent-avail-err.XXXXXX)"

  # Subshell so SCRATCH_HOME export does not leak into the caller, and
  # so a die() inside the script (via has-commands) propagates as a real
  # exit code rather than aborting the calling test or function.
  # SC2030/SC2031: subshell-local modification is intentional here.
  # shellcheck disable=SC2030,SC2031
  (
    export SCRATCH_HOME
    SCRATCH_HOME="$(cd "$_AGENT_SCRIPTDIR/.." && pwd -P)"
    "$script"
  ) 2> "$err_file"
  rc=$?

  _AGENT_AVAILABILITY_ERR="$(cat "$err_file")"
  rm -f "$err_file"
  return "$rc"
}

export -f agent:available

#-------------------------------------------------------------------------------
# agent:run NAME
#
# Execute agents/NAME/run with the env contract. Stdin is piped through
# from the caller; stdout is the agent's response (printed directly to
# the caller's stdout, not captured); stderr is the agent's log output.
# Returns the run script's exit code.
#
# Refuses to run if agent:available fails - dies with the captured error
# from is-available so the operator knows what precondition failed (it
# might be a missing dep, or it might be a policy gate like
# "edit mode required").
#
# Increments SCRATCH_AGENT_DEPTH and dies if the new depth exceeds
# SCRATCH_AGENT_MAX_DEPTH (default 8) BEFORE forking the child. This
# prevents runaway sub-agent recursion from burning API credits.
#-------------------------------------------------------------------------------
agent:run() {
  local name="$1"
  local run_script
  local current_depth
  local max_depth
  local new_depth

  if ! agent:exists "$name"; then
    die "agent: not found: $name"
    return 1
  fi

  if ! agent:available "$name"; then
    die "agent: '$name' is not available: $_AGENT_AVAILABILITY_ERR"
    return 1
  fi

  current_depth="${SCRATCH_AGENT_DEPTH:-0}"
  max_depth="${SCRATCH_AGENT_MAX_DEPTH:-$_AGENT_DEFAULT_MAX_DEPTH}"
  new_depth=$((current_depth + 1))
  if ((new_depth > max_depth)); then
    die "agent: recursion limit reached (SCRATCH_AGENT_DEPTH=$current_depth, max=$max_depth) while invoking '$name'"
    return 1
  fi

  run_script="$(agent:agents-dir)/$name/run"

  # Subshell so the env exports do not leak into the caller. Stdin is
  # not redirected, so the agent inherits whatever stdin the caller has
  # (file, pipe, terminal). Stdout is also not redirected, so the
  # agent's output flows straight through.
  # SC2030/SC2031: env modifications are intentionally subshell-local.
  # shellcheck disable=SC2030,SC2031
  (
    export SCRATCH_AGENT_DIR
    SCRATCH_AGENT_DIR="$(agent:agents-dir)/$name"
    export SCRATCH_HOME
    SCRATCH_HOME="$(cd "$_AGENT_SCRIPTDIR/.." && pwd -P)"
    export SCRATCH_AGENT_DEPTH="$new_depth"

    # Populate project env vars only when project:detect succeeds. Same
    # plain-assignment trick as tool:invoke - `local` inside a subshell
    # under set -u trips on the nameref before it gets assigned.
    _scratch_proj_name=""
    _scratch_proj_worktree=""
    if project:detect _scratch_proj_name _scratch_proj_worktree 2> /dev/null; then
      export SCRATCH_PROJECT="$_scratch_proj_name"
      # Resolve the configured root via project:load rather than using
      # pwd, which would be wrong if invoked from a subdirectory.
      _scratch_proj_root=""
      _scratch_proj_is_git=""
      _scratch_proj_exclude=""
      if project:load "$_scratch_proj_name" _scratch_proj_root _scratch_proj_is_git _scratch_proj_exclude 2> /dev/null \
        && [[ -n "$_scratch_proj_root" ]]; then
        export SCRATCH_PROJECT_ROOT="$_scratch_proj_root"
      fi
    fi

    "$run_script"
  )
}

export -f agent:run

#-------------------------------------------------------------------------------
# agent:simple-completion PROFILE PROMPT_NAME [TOOLS_JSON] [EXTRAS_JSON]
#
# Common-case helper for single-shot agents.
#
# Reduces a trivial agent's run script to roughly:
#
#   #!/usr/bin/env bash
#   set -euo pipefail
#   source "$SCRATCH_HOME/lib/agent.sh"
#   agent:simple-completion balanced "echo/system"
#
# Resolves PROFILE via model:profile:resolve, loads PROMPT_NAME via
# prompt:load, reads stdin once for the user input, builds a 2-message
# array (system prompt + user input), merges the profile's extras with
# the caller's EXTRAS_JSON (caller wins), and calls either
# chat:complete-with-tools (if TOOLS_JSON is a non-empty array) or
# chat:completion (if TOOLS_JSON is omitted, empty, or "[]"). Pipes the
# final response through chat:extract-content so the agent's stdout is
# the model's text content, not the full response envelope.
#
# PROMPT_NAME is passed verbatim to prompt:load, so the same naming
# convention applies (e.g. "echo/system" -> data/prompts/echo/system.md).
#
# Reads stdin once at the top of the function. The agent's run script
# must NOT also read stdin via cat before calling this helper.
#
# All errors propagate via die from the underlying primitives. The
# helper itself does no extra error wrapping.
#-------------------------------------------------------------------------------
agent:simple-completion() {
  local profile="$1"
  local prompt_name="$2"
  local tools_json="${3:-}"
  local extras_json="${4:-}"

  # Read the user input once. The whole point of stdin-as-input is that
  # this happens here, not in every agent's run script.
  local user_input
  user_input="$(cat)"

  local system_prompt
  system_prompt="$(prompt:load "$prompt_name")" || return 1

  local model
  model="$(model:profile:model "$profile")" || return 1

  local profile_extras
  profile_extras="$(model:profile:extras "$profile")" || return 1

  # Merge the caller's extras over the profile's extras (caller wins).
  local merged_extras
  if [[ -n "$extras_json" ]]; then
    merged_extras="$(jq -c -n \
      --argjson p "$profile_extras" \
      --argjson c "$extras_json" \
      '$p + $c')"
  else
    merged_extras="$profile_extras"
  fi

  local messages
  messages="$(jq -c -n \
    --arg system "$system_prompt" \
    --arg user "$user_input" \
    '[{role:"system",content:$system},{role:"user",content:$user}]')"

  # Branch on whether tools were requested. tools_json is non-empty
  # AND a non-empty JSON array -> use chat:complete-with-tools.
  # Otherwise -> chat:completion directly (no tools, no recursion).
  local tool_count=0
  if [[ -n "$tools_json" ]]; then
    tool_count="$(jq 'length' <<< "$tools_json" 2> /dev/null || echo 0)"
  fi

  if ((tool_count > 0)); then
    chat:complete-with-tools "$model" "$messages" "$tools_json" "$merged_extras" \
      | chat:extract-content
  else
    chat:completion "$model" "$messages" "$merged_extras" \
      | chat:extract-content
  fi
}

export -f agent:simple-completion
