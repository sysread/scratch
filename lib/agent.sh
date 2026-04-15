#!/usr/bin/env bash

#-------------------------------------------------------------------------------
# Agent layer
#
# An agent in scratch is a self-contained directory under agents/ with four
# required files:
#
#   agents/<name>/spec.json    - metadata: name, description. Optional fields:
#                                profile (model profile name), toolbox or
#                                tools (tool access), extras (additional
#                                completion params).
#   agents/<name>/pre-fill     - executable; transforms the messages array
#                                before completion. Reads a JSON messages
#                                array from stdin, prints the transformed
#                                array to stdout. Common use: prepend a
#                                system prompt. Passthrough (cat) for agents
#                                that manage prompts internally.
#   agents/<name>/run          - executable entrypoint for standalone mode;
#                                any language. Reads user input on stdin,
#                                prints final response to stdout. Optional
#                                for agents that only need agent:complete.
#   agents/<name>/is-available - bash script. Runtime gate AND dependency
#                                manifest (see conventions doc).
#
# Two invocation modes:
#
#   agent:complete NAME MESSAGES_VAR
#     Multi-turn entry point. Pipes messages through pre-fill, resolves
#     model/tools from spec.json, runs the completion+tool-call loop,
#     appends intermediate messages to MESSAGES_VAR, prints final text
#     to stdout. The caller owns display and persistence.
#
#   agent:run NAME
#     Standalone mode. Execs the run script with stdin/stdout piped
#     through. The agent owns everything internally. Used by complex
#     multi-phase agents (intuition, summary) that manage their own
#     completion lifecycle.
#
# Environment contract for run/pre-fill scripts:
#
#   SCRATCH_AGENT_DIR    absolute path to agents/<name>/
#   SCRATCH_HOME         absolute path to the scratch repo root
#   SCRATCH_PROJECT      current project name (if detected)
#   SCRATCH_PROJECT_ROOT current project root path (if detected)
#   SCRATCH_AGENT_DEPTH  current recursion depth
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

#-------------------------------------------------------------------------------
# Availability memoization
#
# agent:available is called once per agent:run and again from agent:list-
# level walks. Each call forks a bash shell to run is-available. Session-
# scoped memo elides the fork on repeated calls.
#
# Same contract as lib/tool.sh: task-boundary callers invoke
# agent:reset-avail-memo to force a re-check. SCRATCH_AVAIL_MEMO=0
# disables memoization entirely.
declare -gA _AGENT_AVAIL_MEMO=()
declare -gA _AGENT_AVAIL_ERR_MEMO=()

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
# Return 0 if agents/NAME/ has all required files (spec.json, pre-fill,
# is-available). The run script is optional (agents that only use
# agent:complete don't need it). Does NOT check executable bits; that's
# the contract test's job at structural-validation time.
#-------------------------------------------------------------------------------
agent:exists() {
  local name="$1"
  local agents_dir
  agents_dir="$(agent:agents-dir)"

  [[ -f "${agents_dir}/${name}/spec.json" ]] || return 1
  [[ -f "${agents_dir}/${name}/pre-fill" ]] || return 1
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
    die "agent: not found: $name (expected agents/$name/ with spec.json + pre-fill + is-available)"
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

  # Memo hit: restore the captured error and return the cached rc without
  # forking. See the memo header comment for the invalidation contract.
  if [[ "${SCRATCH_AVAIL_MEMO:-1}" != "0" && -n "${_AGENT_AVAIL_MEMO[$name]:-}" ]]; then
    _AGENT_AVAILABILITY_ERR="${_AGENT_AVAIL_ERR_MEMO[$name]:-}"
    return "${_AGENT_AVAIL_MEMO[$name]}"
  fi

  script="$(agent:agents-dir)/$name/is-available"

  err_file="$(mktemp -t scratch-agent-avail-err.XXXXXX)"

  # Subshell so SCRATCH_HOME export does not leak into the caller, and
  # so a die() or set -e abort inside the script stays contained. Source
  # rather than exec to skip bash startup on every call - see the
  # matching note in lib/tool.sh tool:available for the rationale.
  # SC2030/SC2031: subshell-local modification is intentional here.
  # shellcheck disable=SC2030,SC2031
  (
    export SCRATCH_HOME
    SCRATCH_HOME="$(cd "$_AGENT_SCRIPTDIR/.." && pwd -P)"
    # shellcheck source=/dev/null
    source "$script"
  ) 2> "$err_file"
  rc=$?

  _AGENT_AVAILABILITY_ERR="$(cat "$err_file")"
  rm -f "$err_file"

  if [[ "${SCRATCH_AVAIL_MEMO:-1}" != "0" ]]; then
    _AGENT_AVAIL_MEMO[$name]="$rc"
    _AGENT_AVAIL_ERR_MEMO[$name]="$_AGENT_AVAILABILITY_ERR"
  fi
  return "$rc"
}

export -f agent:available

#-------------------------------------------------------------------------------
# agent:reset-avail-memo
#
# Clear the availability memo and the captured error. Call this at task
# boundaries (start of a new user turn, before a test that pins rc
# sequences) to force the next agent:available call to re-run is-available.
#-------------------------------------------------------------------------------
agent:reset-avail-memo() {
  _AGENT_AVAIL_MEMO=()
  _AGENT_AVAIL_ERR_MEMO=()
  _AGENT_AVAILABILITY_ERR=""
}

export -f agent:reset-avail-memo

#-------------------------------------------------------------------------------
# agent:recheck-failed-avail-memo
#
# Walk the memo and re-run is-available for every entry whose cached rc
# is non-zero. Successful entries stay cached. See the matching note on
# tool:recheck-failed-avail-memo for the call-site rationale.
#-------------------------------------------------------------------------------
agent:recheck-failed-avail-memo() {
  local name
  local -a failed=()
  for name in "${!_AGENT_AVAIL_MEMO[@]}"; do
    [[ "${_AGENT_AVAIL_MEMO[$name]}" != "0" ]] && failed+=("$name")
  done
  for name in "${failed[@]}"; do
    unset '_AGENT_AVAIL_MEMO[$name]'
    unset '_AGENT_AVAIL_ERR_MEMO[$name]'
    agent:available "$name" || true
  done
}

export -f agent:recheck-failed-avail-memo

#-------------------------------------------------------------------------------
# agent:preload-avail-memo
#
# Eagerly run is-available for every agent (or just the named agents) and
# populate the memo. Individual failures are recorded in the memo. Use
# from scratch-dispatch at startup to shift the fork cost off the first
# agent-using request.
#-------------------------------------------------------------------------------
# Named-arg form exists for scoped warm-ups; see the matching note on
# tool:preload-avail-memo.
# shellcheck disable=SC2120
agent:preload-avail-memo() {
  local -a names
  local name
  if (($# == 0)); then
    mapfile -t names < <(agent:list)
  else
    names=("$@")
  fi
  for name in "${names[@]}"; do
    [[ -z "$name" ]] && continue
    agent:available "$name" || true
  done
}

export -f agent:preload-avail-memo

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
    #
    # Fast path: if the caller already exported SCRATCH_PROJECT and
    # SCRATCH_PROJECT_ROOT, trust them and skip the detect. Avoids three
    # git subprocess calls and a jq pass on the project settings per
    # agent invocation.
    if [[ -z "${SCRATCH_PROJECT:-}" || -z "${SCRATCH_PROJECT_ROOT:-}" ]]; then
      _scratch_proj_name=""
      _scratch_proj_worktree=""
      if project:detect _scratch_proj_name _scratch_proj_worktree 2> /dev/null; then
        export SCRATCH_PROJECT="$_scratch_proj_name"
        # Resolve the configured root via project:load rather than pwd.
        # pwd would be wrong if invoked from a subdirectory. If load fails
        # or returns an empty root, SCRATCH_PROJECT_ROOT stays unset —
        # downstream code checks [[ -n ${SCRATCH_PROJECT_ROOT:-} ]].
        _scratch_proj_root=""
        _scratch_proj_is_git=""
        _scratch_proj_exclude=""
        if project:load "$_scratch_proj_name" _scratch_proj_root _scratch_proj_is_git _scratch_proj_exclude 2> /dev/null \
          && [[ -n "$_scratch_proj_root" ]]; then
          export SCRATCH_PROJECT_ROOT="$_scratch_proj_root"
        fi
      fi
    fi

    "$run_script"
  )
}

export -f agent:run

#-------------------------------------------------------------------------------
# agent:profile NAME
#
# Print the model profile name for the agent (from spec.json .profile).
# Dies if the agent has no profile declared.
#-------------------------------------------------------------------------------
agent:profile() {
  local name="$1"
  local profile
  profile="$(agent:spec "$name" | jq -r '.profile // empty')"
  if [[ -z "$profile" ]]; then
    die "agent: '$name' has no profile in spec.json"
    return 1
  fi
  printf '%s' "$profile"
}

export -f agent:profile

#-------------------------------------------------------------------------------
# agent:tools NAME
#
# Print a JSON array of tool names for the agent. Resolves from spec.json:
# if .toolbox is set, reads the toolbox; if .tools is set, uses the array
# directly. Returns "[]" if neither is declared.
#-------------------------------------------------------------------------------
agent:tools() {
  local name="$1"
  local spec
  spec="$(agent:spec "$name")"

  local toolbox
  toolbox="$(jq -r '.toolbox // empty' <<< "$spec")"
  if [[ -n "$toolbox" ]]; then
    tool:box "$toolbox" | jq -c '.tools'
    return 0
  fi

  local tools
  tools="$(jq -c '.tools // empty' <<< "$spec")"
  if [[ -n "$tools" ]]; then
    printf '%s' "$tools"
    return 0
  fi

  printf '[]'
}

export -f agent:tools

#-------------------------------------------------------------------------------
# agent:pre-fill NAME MESSAGES_VAR
#
# Pipe the messages array through the agent's pre-fill script and assign
# the result back to MESSAGES_VAR. The pre-fill script receives the JSON
# messages array on stdin and prints the transformed array to stdout.
#
# Runs in a subshell with the agent env contract so pre-fill can source
# scratch libraries via SCRATCH_HOME.
#-------------------------------------------------------------------------------
agent:pre-fill() {
  local name="$1"
  local -n _apf_messages="$2"

  local pre_fill_script
  pre_fill_script="$(agent:agents-dir)/$name/pre-fill"

  if [[ ! -x "$pre_fill_script" ]]; then
    die "agent: '$name' has no executable pre-fill script"
    return 1
  fi

  # shellcheck disable=SC2034
  # SC2030/SC2031: env modifications are intentionally subshell-local.
  # shellcheck disable=SC2030,SC2031
  _apf_messages="$(
    (
      export SCRATCH_AGENT_DIR
      SCRATCH_AGENT_DIR="$(agent:agents-dir)/$name"
      export SCRATCH_HOME
      SCRATCH_HOME="$(cd "$_AGENT_SCRIPTDIR/.." && pwd -P)"
      printf '%s' "$_apf_messages" | "$pre_fill_script"
    )
  )"
}

export -f agent:pre-fill

#-------------------------------------------------------------------------------
# agent:complete NAME MESSAGES_VAR RESPONSE_VAR [EXTRAS_JSON]
#
# Multi-turn completion entry point. Pipes messages through the agent's
# pre-fill script, resolves model and tools from spec.json, runs the
# completion loop (including tool calls), and assigns the final assistant
# text response to RESPONSE_VAR.
#
# Both MESSAGES_VAR and RESPONSE_VAR are namerefs. Using namerefs for
# both outputs (instead of printing text to stdout) is required because
# $(...) subshells would discard the nameref modifications to the
# messages array - the classic bash subshell variable-loss gotcha.
#
# MESSAGES_VAR is modified in place: intermediate messages (assistant
# tool_calls, tool results) are appended as the loop runs. The caller
# can diff the array before/after to see what happened. The final
# assistant text message is NOT appended - the caller owns that.
#
# The pre-filled messages (with system prompt) are used for API calls but
# NOT written back to MESSAGES_VAR. The caller's array stays free of the
# system prompt so it reflects what the user sees, not what the API sees.
#-------------------------------------------------------------------------------
agent:complete() {
  local name="$1"
  local -n _ac_messages="$2"
  local -n _ac_response="$3"
  local caller_extras="${4:-}"

  if ! agent:available "$name"; then
    die "agent: '$name' is not available: $_AGENT_AVAILABILITY_ERR"
    return 1
  fi

  # Resolve agent configuration from spec.json
  local profile
  profile="$(agent:profile "$name")"

  local model
  model="$(model:profile:model "$profile")"

  local profile_extras
  profile_extras="$(model:profile:extras "$profile")"

  # Merge caller extras over profile extras (caller wins)
  local merged_extras
  if [[ -n "$caller_extras" ]]; then
    merged_extras="$(jq -c -n \
      --argjson p "$profile_extras" \
      --argjson c "$caller_extras" \
      '$p + $c')"
  else
    merged_extras="$profile_extras"
  fi

  # Resolve tools
  local tools_json
  tools_json="$(agent:tools "$name")"

  local tool_count=0
  if [[ -n "$tools_json" && "$tools_json" != "[]" ]]; then
    tool_count="$(jq 'length' <<< "$tools_json" 2> /dev/null || echo 0)"
  fi

  # Inject tool specs into extras if tools are available
  if ((tool_count > 0)); then
    local tool_names_args
    mapfile -t tool_names_args < <(jq -r '.[]' <<< "$tools_json")

    local tool_specs
    tool_specs="$(tool:specs-json "${tool_names_args[@]}")"

    merged_extras="$(jq -c --argjson t "$tool_specs" \
      '. + {tools: $t}' <<< "$merged_extras")"
  fi

  # Run pre-fill to get API-ready messages (with system prompt etc.)
  local api_messages="$_ac_messages"
  agent:pre-fill "$name" api_messages

  # Completion loop with tool calling.
  #
  # Local variable names use _ac_ prefix to avoid colliding with the
  # caller's variable names via the namerefs. Bash namerefs resolve to
  # the CURRENT scope first, so a `local response` here would shadow
  # the caller's `response` variable that _ac_response points to.
  local _ac_raw
  local _ac_tool_calls

  while :; do
    _ac_raw="$(chat:completion "$model" "$api_messages" "$merged_extras")"

    # Check for tool calls. Some models return null, some return [],
    # some omit the field entirely. All three mean "no tool calls."
    _ac_tool_calls="$(jq -c '.choices[0].message.tool_calls // empty' <<< "$_ac_raw")"

    if [[ -z "$_ac_tool_calls" || "$_ac_tool_calls" == "null" || "$_ac_tool_calls" == "[]" ]]; then
      # Plain text response - assign to response nameref and return
      # shellcheck disable=SC2034
      _ac_response="$(jq -r '.choices[0].message.content // ""' <<< "$_ac_raw")"
      return 0
    fi

    # Build calls array for tool:invoke-parallel
    local _ac_calls
    _ac_calls="$(jq -c '[.[] | {
      id: .id,
      name: .function.name,
      args: (.function.arguments | (fromjson? // {}))
    }]' <<< "$_ac_tool_calls")"

    # Execute tools
    local _ac_results
    _ac_results="$(tool:invoke-parallel "$_ac_calls")"

    # Build the messages to append: assistant (with tool_calls) + tool results
    local _ac_assistant_msg
    _ac_assistant_msg="$(jq -c '.choices[0].message' <<< "$_ac_raw")"

    local _ac_tool_msgs
    _ac_tool_msgs="$(jq -c \
      '[.[] | {role: "tool", tool_call_id: .tool_call_id, content: .content}]' \
      <<< "$_ac_results")"

    # Append to API messages (includes system prompt)
    api_messages="$(jq -c \
      --argjson assistant "$_ac_assistant_msg" \
      --argjson results "$_ac_tool_msgs" \
      '. + [$assistant] + $results' \
      <<< "$api_messages")"

    # Append to caller's messages (no system prompt)
    _ac_messages="$(jq -c \
      --argjson assistant "$_ac_assistant_msg" \
      --argjson results "$_ac_tool_msgs" \
      '. + [$assistant] + $results' \
      <<< "$_ac_messages")"
  done
}

export -f agent:complete

#-------------------------------------------------------------------------------
# agent:simple-completion NAME INPUT_STRING [EXTRAS_JSON]
#
# Convenience wrapper for one-shot agent invocations. Wraps INPUT_STRING
# as a single user message, calls agent:complete, and returns the text.
#
# Reduces a trivial agent's run script to:
#
#   #!/usr/bin/env bash
#   set -euo pipefail
#   source "$SCRATCH_HOME/lib/agent.sh"
#   agent:simple-completion echo "$(cat)"
#-------------------------------------------------------------------------------
agent:simple-completion() {
  local name="$1"
  local user_input="$2"
  local extras="${3:-}"

  local messages
  # shellcheck disable=SC2034
  messages="$(jq -c -n --arg content "$user_input" \
    '[{role: "user", content: $content}]')"

  local response=""
  agent:complete "$name" messages response "$extras"
  printf '%s' "$response"
}

export -f agent:simple-completion
