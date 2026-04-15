#!/usr/bin/env bash

#-------------------------------------------------------------------------------
# Tool calling infrastructure
#
# A "tool" in scratch is a self-contained directory under tools/ with three
# required files:
#
#   tools/<name>/spec.json    - OpenAI function-calling JSON spec (the inner
#                               function object: name, description, parameters).
#                               Not executable.
#   tools/<name>/main         - the executable; any language. Receives args
#                               via SCRATCH_TOOL_ARGS_JSON env var. Exit 0 +
#                               stdout = success result; non-zero + stderr =
#                               failure result. Stdout and stderr are kept
#                               STRICTLY separate (unlike fnord which merges).
#   tools/<name>/is-available - bash script. Two purposes:
#                               1. Runtime gate: exit 0 if the tool is usable
#                                  in the current environment, non-zero (with
#                                  reason on stderr) if not.
#                               2. Dependency manifest: must source lib/base.sh
#                                  and call has-commands for any external
#                                  programs the tool needs. The doctor scanner
#                                  picks up these declarations textually and
#                                  attributes them to "tool:<name>".
#
# This library handles tool discovery, schema reading, availability gating,
# and synchronous + parallel invocation. The chat layer (lib/chat.sh) builds
# on this with chat:complete-with-tools, which loops on Venice tool_calls
# responses and feeds tool results back to the model.
#
# Environment contract for tool main scripts:
#
#   SCRATCH_TOOL_ARGS_JSON  the LLM's arguments as a JSON object (always set,
#                           may be "{}" for tools with no parameters)
#   SCRATCH_TOOL_DIR        absolute path to tools/<name>/ (so tools can find
#                           sibling files like fixtures or sub-scripts)
#   SCRATCH_HOME            absolute path to the scratch repo root (so bash
#                           tools can `source "$SCRATCH_HOME/lib/tui.sh"` etc.)
#   SCRATCH_PROJECT         current project name from project:detect, only
#                           set if a project is detected (use [[ -n ${VAR:-} ]])
#   SCRATCH_PROJECT_ROOT    current project root path, only set if detected
#-------------------------------------------------------------------------------

[[ "${_INCLUDED_TOOL:-}" == "1" ]] && return 0
_INCLUDED_TOOL=1

_TOOL_SCRIPTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source-path=SCRIPTDIR/lib
# shellcheck disable=SC1091
{
  source "$_TOOL_SCRIPTDIR/base.sh"
  source "$_TOOL_SCRIPTDIR/tempfiles.sh"
  source "$_TOOL_SCRIPTDIR/project.sh"
  source "$_TOOL_SCRIPTDIR/workers.sh"
  source "$_TOOL_SCRIPTDIR/approvals.sh"
  source "$_TOOL_SCRIPTDIR/approvals/tui/shell.sh"
}

has-commands jq

#-------------------------------------------------------------------------------
# Globals (set by tool:available and tool:invoke)
#
# These are intentionally globals because the alternative - returning multi-
# line content from a function - is fragile in bash, especially when the
# content includes JSON or trailing newlines. Callers read these immediately
# after the function returns.
#-------------------------------------------------------------------------------
# shellcheck disable=SC2034
_TOOL_AVAILABILITY_ERR=""
# shellcheck disable=SC2034
_TOOL_INVOKE_STDOUT=""
# shellcheck disable=SC2034
_TOOL_INVOKE_STDERR=""

# Session-scoped dedup for tool:specs-json's filtered-tool warnings.
# An agent that calls tool:specs-json across multiple phases would
# otherwise log the same "filtering unavailable tool" line per phase.
# Keyed by tool name; presence means we already warned this process.
declare -gA _TOOL_SPECS_WARNED=()

# Same shape, but keyed by toolbox name. tool:box uses this so an
# unavailable toolbox warns on first access and stays silent on every
# subsequent call from the same process.
declare -gA _TOOLBOX_WARNED=()

#-------------------------------------------------------------------------------
# Availability memoization
#
# tool:available is hot: tool:specs-json walks every tool on every call,
# and tool:invoke gates every invocation. Each call forks a bash shell
# running the is-available script. On macOS that's ~20-30ms per tool.
#
# _TOOL_AVAIL_MEMO stores the numeric rc keyed by tool name. A separate
# _TOOL_AVAIL_ERR_MEMO holds the captured stderr so we can restore
# _TOOL_AVAILABILITY_ERR on a memo hit (same contract as a fresh call).
#
# The memo is intentionally session-scoped, not file-mtime-indexed. If an
# operator mutates is-available mid-session or uninstalls a dependency,
# the cached answer goes stale. The reset contract covers this: callers
# at task boundaries (e.g. start of a new user turn in agent:complete)
# call tool:reset-avail-memo, which clears both maps.
#
# SCRATCH_AVAIL_MEMO=0 disables memoization entirely. Useful for
# long-lived processes that want is-available to re-run every call, and
# for tests that pin specific rc sequences.
declare -gA _TOOL_AVAIL_MEMO=()
declare -gA _TOOL_AVAIL_ERR_MEMO=()

#-------------------------------------------------------------------------------
# _tool:approval-class NAME
#
# (Private) Read the approval_class field from a tool's spec.json.
# Returns the class name (e.g. "shell") or empty string if unset.
#-------------------------------------------------------------------------------
_tool:approval-class() {
  local name="$1"
  local tools_dir
  tools_dir="$(tool:tools-dir)"
  jq -r '.approval_class // empty' "${tools_dir}/${name}/spec.json" 2> /dev/null || true
}

export -f _tool:approval-class

#-------------------------------------------------------------------------------
# tool:tools-dir
#
# Print the absolute path to the tools directory. Honors SCRATCH_TOOLS_DIR
# for tests; defaults to <repo>/tools.
#-------------------------------------------------------------------------------
tool:tools-dir() {
  if [[ -n "${SCRATCH_TOOLS_DIR:-}" ]]; then
    printf '%s\n' "$SCRATCH_TOOLS_DIR"
  else
    printf '%s\n' "$(cd "$_TOOL_SCRIPTDIR/../tools" 2> /dev/null && pwd -P || echo "$_TOOL_SCRIPTDIR/../tools")"
  fi
}

export -f tool:tools-dir

#-------------------------------------------------------------------------------
# tool:list
#
# Print the names of all tools (sorted, one per line). A tool is a directory
# under tool:tools-dir that contains at least a spec.json file. Directories
# missing spec.json are silently skipped, which keeps test fixture setup easy.
#-------------------------------------------------------------------------------
tool:list() {
  local tools_dir
  local d
  local name

  tools_dir="$(tool:tools-dir)"
  [[ -d "$tools_dir" ]] || return 0

  for d in "$tools_dir"/*/; do
    [[ -d "$d" ]] || continue
    [[ -f "${d}spec.json" ]] || continue
    name="$(basename "$d")"
    printf '%s\n' "$name"
  done | sort
}

export -f tool:list

#-------------------------------------------------------------------------------
# tool:exists NAME
#
# Return 0 if tools/NAME/ has all three required files (spec.json, main,
# is-available). Return 1 otherwise. Silent. Does NOT check executable bits;
# that's the contract test's job at structural-validation time.
#-------------------------------------------------------------------------------
tool:exists() {
  local name="$1"
  local tools_dir
  tools_dir="$(tool:tools-dir)"

  [[ -f "${tools_dir}/${name}/spec.json" ]] || return 1
  [[ -f "${tools_dir}/${name}/main" ]] || return 1
  [[ -f "${tools_dir}/${name}/is-available" ]] || return 1
  return 0
}

export -f tool:exists

#-------------------------------------------------------------------------------
# tool:dir NAME
#
# Print the absolute path to tools/NAME/. Dies if the directory does not
# exist or is missing the required files.
#-------------------------------------------------------------------------------
tool:dir() {
  local name="$1"
  if ! tool:exists "$name"; then
    die "tool: not found: $name (expected tools/$name/ with spec.json + main + is-available)"
    return 1
  fi
  printf '%s\n' "$(tool:tools-dir)/$name"
}

export -f tool:dir

#-------------------------------------------------------------------------------
# tool:spec NAME
#
# Print the raw spec.json contents for NAME. Does not validate the JSON
# shape - that's the contract test's job. Dies if the tool doesn't exist.
#-------------------------------------------------------------------------------
tool:spec() {
  local name="$1"
  if ! tool:exists "$name"; then
    die "tool: not found: $name"
    return 1
  fi
  cat "$(tool:tools-dir)/$name/spec.json"
}

export -f tool:spec

#-------------------------------------------------------------------------------
# tool:available NAME
#
# Run tools/NAME/is-available with the env contract set up. Return its
# exit code. Stderr from the script is captured into _TOOL_AVAILABILITY_ERR
# (a global) for the caller to inspect on failure.
#
# Honors SCRATCH_TOOL_SKIP_AVAILABILITY=1 by always returning 0 without
# running anything. Useful in tests that don't want the gate.
#-------------------------------------------------------------------------------
tool:available() {
  local name="$1"
  local script
  local err_file
  local rc

  if [[ "${SCRATCH_TOOL_SKIP_AVAILABILITY:-}" == "1" ]]; then
    _TOOL_AVAILABILITY_ERR=""
    return 0
  fi

  if ! tool:exists "$name"; then
    _TOOL_AVAILABILITY_ERR="tool: not found: $name"
    return 1
  fi

  # Memo hit: restore the captured error and return the cached rc without
  # forking. Disabled entirely when SCRATCH_AVAIL_MEMO=0. Callers at task
  # boundaries use tool:reset-avail-memo to invalidate.
  if [[ "${SCRATCH_AVAIL_MEMO:-1}" != "0" && -n "${_TOOL_AVAIL_MEMO[$name]:-}" ]]; then
    _TOOL_AVAILABILITY_ERR="${_TOOL_AVAIL_ERR_MEMO[$name]:-}"
    return "${_TOOL_AVAIL_MEMO[$name]}"
  fi

  script="$(tool:tools-dir)/$name/is-available"

  tmp:make err_file /tmp/scratch-tool-avail-err.XXXXXX
  tmp:install-traps

  # Subshell so SCRATCH_HOME export does not leak into the caller, and
  # so a die() or set -e abort inside the script stays contained. Source
  # rather than exec: is-available scripts are tiny - mostly
  # `source base.sh; has-commands ...` - and paying for bash startup +
  # exec on every call is pure overhead. Sourcing skips the interpreter
  # launch and uses just a fork (~1-2ms vs ~20ms per call on macOS).
  # SC2030/SC2031: subshell-local modification is intentional here.
  # shellcheck disable=SC2030,SC2031
  (
    export SCRATCH_HOME
    SCRATCH_HOME="$(cd "$_TOOL_SCRIPTDIR/.." && pwd -P)"
    # shellcheck source=/dev/null
    source "$script"
  ) 2> "$err_file"
  rc=$?

  _TOOL_AVAILABILITY_ERR="$(cat "$err_file")"
  rm -f "$err_file"

  # Populate the memo so the next call for this tool skips the fork.
  # Memo values are strings; rc=0 stores "0" which is truthy-present.
  if [[ "${SCRATCH_AVAIL_MEMO:-1}" != "0" ]]; then
    _TOOL_AVAIL_MEMO[$name]="$rc"
    _TOOL_AVAIL_ERR_MEMO[$name]="$_TOOL_AVAILABILITY_ERR"
  fi
  return "$rc"
}

export -f tool:available

#-------------------------------------------------------------------------------
# tool:reset-avail-memo
#
# Clear the availability memo and the captured error. Call this at task
# boundaries (start of a new user turn, start of a chat round where tool
# set may have changed, before a test that pins rc sequences) to force
# the next tool:available call to re-run is-available.
#-------------------------------------------------------------------------------
tool:reset-avail-memo() {
  _TOOL_AVAIL_MEMO=()
  _TOOL_AVAIL_ERR_MEMO=()
  _TOOL_AVAILABILITY_ERR=""
}

export -f tool:reset-avail-memo

#-------------------------------------------------------------------------------
# tool:recheck-failed-avail-memo
#
# Walk the memo and re-run is-available for every entry whose cached rc
# is non-zero. Successful entries stay cached. The intended call site is
# the top of each persistent-session round (scratch-chat): most env
# conditions don't change within a session, but a user can install a
# missing dep (e.g. brew install gum) between turns and expect the next
# turn to pick it up.
#
# Implemented by clearing the failed entries and letting tool:available
# re-run and repopulate them naturally. Return is always 0; new failures
# stay recorded in the memo.
#-------------------------------------------------------------------------------
tool:recheck-failed-avail-memo() {
  local name
  local -a failed=()
  for name in "${!_TOOL_AVAIL_MEMO[@]}"; do
    [[ "${_TOOL_AVAIL_MEMO[$name]}" != "0" ]] && failed+=("$name")
  done
  for name in "${failed[@]}"; do
    unset '_TOOL_AVAIL_MEMO[$name]'
    unset '_TOOL_AVAIL_ERR_MEMO[$name]'
    tool:available "$name" || true
  done
}

export -f tool:recheck-failed-avail-memo

#-------------------------------------------------------------------------------
# tool:preload-avail-memo
#
# Eagerly run is-available for every tool (or just the named tools) and
# populate the memo. The return value is always 0; individual failures
# are reflected in the memo and picked up by subsequent tool:available
# calls. Use from scratch-dispatch at startup to shift the fork cost off
# the critical path of the first tool-using request.
#-------------------------------------------------------------------------------
# No-arg call is the common path (preload every tool). Named-arg form
# exists for scoped warm-ups (preload only the tools a given agent
# declares). SC2120 warns about the arg path being unused at some
# callers; suppress because the no-arg path is intentional.
# shellcheck disable=SC2120
tool:preload-avail-memo() {
  local -a names
  local name
  if (($# == 0)); then
    mapfile -t names < <(tool:list)
  else
    names=("$@")
  fi
  for name in "${names[@]}"; do
    [[ -z "$name" ]] && continue
    tool:available "$name" || true
  done
}

export -f tool:preload-avail-memo

#-------------------------------------------------------------------------------
# tool:specs-json [NAMES...]
#
# Print a JSON array of tool specs in OpenAI's wire format:
#
#   [{"type": "function", "function": <spec.json contents>}, ...]
#
# With no NAMES, iterates every tool from tool:list. With one or more NAMES,
# iterates only those (deduplicated, in input order). Tools that fail their
# is-available check are filtered out and logged via tui:debug if available
# (unless SCRATCH_TOOL_SKIP_AVAILABILITY=1). Dies if a named tool does not
# exist (different from being unavailable - "doesn't exist" is a typo, while
# "unavailable" is a runtime condition we silently degrade around).
#-------------------------------------------------------------------------------
tool:specs-json() {
  local -a names
  local -a seen=()
  local name
  local result='[]'
  local spec
  local entry

  if (($# == 0)); then
    mapfile -t names < <(tool:list)
  else
    names=("$@")
  fi

  for name in "${names[@]}"; do
    [[ -z "$name" ]] && continue

    # Dedup
    if [[ " ${seen[*]:-} " == *" ${name} "* ]]; then
      continue
    fi
    seen+=("$name")

    # Existence is fatal (typo case)
    if ! tool:exists "$name"; then
      die "tool:specs-json: not found: $name"
      return 1
    fi

    # Availability is silently filtered. We log via tui:debug, but only
    # ONCE per tool per process, so a multi-phase agent that calls
    # tool:specs-json repeatedly does not get duplicate noise. Reset
    # _TOOL_SPECS_WARNED in tests to start fresh.
    if ! tool:available "$name"; then
      if [[ -z "${_TOOL_SPECS_WARNED[$name]:-}" ]]; then
        _TOOL_SPECS_WARNED[$name]=1
        if type -t tui:debug &> /dev/null; then
          tui:debug "tool:specs-json: filtering unavailable tool" name "$name" reason "${_TOOL_AVAILABILITY_ERR}" || true
        fi
      fi
      continue
    fi

    spec="$(tool:spec "$name")"
    entry="$(jq -c -n --argjson s "$spec" '{type: "function", function: $s}')"
    result="$(jq -c --argjson e "$entry" '. + [$e]' <<< "$result")"
  done

  printf '%s\n' "$result"
}

export -f tool:specs-json

#-------------------------------------------------------------------------------
# tool:invoke NAME ARGS_JSON
#
# Synchronously execute tools/NAME/main with the env contract. Captures
# stdout and stderr into separate global scalars (_TOOL_INVOKE_STDOUT and
# _TOOL_INVOKE_STDERR) and returns the tool's exit code as the function
# return.
#
# If tool:available returns non-zero first, returns 127 with the
# availability error in _TOOL_INVOKE_STDERR (no-command-style exit code).
#
# Does NOT parse ARGS_JSON; passes it through opaquely. Tools are
# responsible for their own input validation.
#
# Tempfile-based stream capture (NOT process substitution) is used so the
# exit code stays clean and we don't risk SIGPIPE or deadlock on large
# stderr output.
#-------------------------------------------------------------------------------
tool:invoke() {
  local name="$1"
  local args_json="$2"
  local main_path
  local out_file
  local err_file
  local rc

  if ! tool:exists "$name"; then
    die "tool: not found: $name"
    return 1
  fi

  if ! tool:available "$name"; then
    _TOOL_INVOKE_STDOUT=""
    _TOOL_INVOKE_STDERR="$_TOOL_AVAILABILITY_ERR"
    return 127
  fi

  # Approval gate: if the tool declares an approval_class in spec.json,
  # check whether the invocation is pre-approved. If not, show the
  # approval TUI. Honors SCRATCH_APPROVALS_SKIP=1 for test bypass.
  local _ti_approval_class
  _ti_approval_class="$(_tool:approval-class "$name")"
  if [[ -n "$_ti_approval_class" && "${SCRATCH_APPROVALS_SKIP:-}" != "1" ]]; then
    case "$_ti_approval_class" in
      shell)
        if ! approvals:check-shell "$args_json"; then
          # Not pre-approved - show the TUI
          local _ti_approval_result=""
          local _ti_approval_why=""
          if ! approvals:tui-shell "$args_json" _ti_approval_result _ti_approval_why; then
            # Denied
            if [[ -n "$_ti_approval_why" ]]; then
              _TOOL_INVOKE_STDOUT="Command denied by user: $_ti_approval_why"
              _TOOL_INVOKE_STDERR=""
              return 0
            fi
            _TOOL_INVOKE_STDOUT=""
            _TOOL_INVOKE_STDERR="Command not approved by user"
            return 1
          fi
        fi
        ;;
    esac
  fi

  main_path="$(tool:tools-dir)/$name/main"

  tmp:make out_file /tmp/scratch-tool-out.XXXXXX
  tmp:make err_file /tmp/scratch-tool-err.XXXXXX
  tmp:install-traps

  # Run main in a subshell so the exported env vars don't pollute the
  # caller's environment. Tempfiles capture stdout and stderr separately
  # so the exit-code-determines-stream rule (success=stdout, failure=stderr)
  # has clean inputs.
  # SC2030/SC2031: all env modifications are intentionally subshell-local.
  # shellcheck disable=SC2030,SC2031
  (
    export SCRATCH_TOOL_ARGS_JSON="$args_json"
    export SCRATCH_TUI_USE_TTY=1
    export SCRATCH_TOOL_DIR
    SCRATCH_TOOL_DIR="$(tool:tools-dir)/$name"
    export SCRATCH_HOME
    SCRATCH_HOME="$(cd "$_TOOL_SCRIPTDIR/.." && pwd -P)"

    # Populate project env vars only when project:detect succeeds. Tools
    # can then use [[ -n ${SCRATCH_PROJECT:-} ]] to test for "in a project".
    #
    # Fast path: if the caller already exported SCRATCH_PROJECT and
    # SCRATCH_PROJECT_ROOT (scratch-dispatch does this at startup), trust
    # them and skip the detect. Avoids three git subprocess calls and a
    # jq pass on the project settings per tool invocation.
    #
    # We use plain assignment (not `local`) here because we're in a subshell
    # ( ... ), and subshell-scoped vars are discarded when the subshell
    # exits regardless of declaration. Avoiding `local` also dodges a
    # set -u edge case where `local foo` inside a subshell can trigger
    # an "unbound variable" error before the nameref-based assignment runs.
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

    "$main_path"
  ) > "$out_file" 2> "$err_file"
  rc=$?

  _TOOL_INVOKE_STDOUT="$(cat "$out_file")"
  _TOOL_INVOKE_STDERR="$(cat "$err_file")"
  rm -f "$out_file" "$err_file"

  return "$rc"
}

export -f tool:invoke

#-------------------------------------------------------------------------------
# tool:invoke-parallel CALLS_JSON
#
# Execute multiple tool calls in parallel and assemble the results.
#
# CALLS_JSON is a JSON array of {id, name, args} objects, matching the
# OpenAI tool_calls response shape (with .args being the already-parsed
# argument object, not the JSON string the API uses).
#
# Forks one background job per call. Each job writes its captured stdout,
# stderr, and exit code to numbered temp files. The parent waits for all
# jobs to finish, then assembles a JSON array of results in *input order*
# (not wait order):
#
#   [{"tool_call_id": "...", "content": "...", "ok": true|false}, ...]
#
# Where:
#   ok=true  -> content is the tool's stdout
#   ok=false -> content is the tool's stderr (or a synthesized error if
#               stderr was empty)
#
# Empty CALLS_JSON returns "[]".
#
# Failures are encoded as ok:false; the function does NOT die on individual
# failures, so a single broken tool doesn't kill the whole batch.
#
# CRITICAL: tmp:make is called in the PARENT shell. Children inherit the
# already-allocated paths via the bg job environment. tmp:make uses an
# in-memory registry that lives in the parent process; calling it from a
# subshell would lose the registration and the cleanup would skip the file.
#-------------------------------------------------------------------------------
tool:invoke-parallel() {
  local calls_json="$1"
  local count
  local i
  local id
  local rc
  local content
  local ok
  local results='[]'

  # Empty input -> empty result, fast path
  count="$(jq 'length' <<< "$calls_json")"
  if ((count == 0)); then
    printf '%s\n' "$results"
    return 0
  fi

  # Allocate the work directory in the PARENT shell so tmp:track's registry
  # records it. tmp:make is for files; for a directory we use mktemp -d
  # directly and manually tmp:track.
  local workdir
  workdir="$(mktemp -d -t scratch-tool-parallel.XXXXXX)"
  tmp:track "$workdir"
  tmp:install-traps

  # Pre-decode call data into parallel arrays so the worker can index
  # into them with no per-fork jq cost. Subshells inherit parent
  # variables at fork time, so the arrays are visible to every worker.
  local -a TOOL_PAR_IDS=()
  local -a TOOL_PAR_NAMES=()
  local -a TOOL_PAR_ARGS=()
  for ((i = 0; i < count; i++)); do
    TOOL_PAR_IDS+=("$(jq -r ".[$i].id" <<< "$calls_json")")
    TOOL_PAR_NAMES+=("$(jq -r ".[$i].name" <<< "$calls_json")")
    TOOL_PAR_ARGS+=("$(jq -c ".[$i].args" <<< "$calls_json")")
    # Stash the id in the workdir up front so the result-assembly loop
    # below does not depend on the worker having run successfully.
    printf '%s' "${TOOL_PAR_IDS[i]}" > "${workdir}/${i}.id"
  done

  TOOL_PAR_WORKDIR="$workdir"
  export TOOL_PAR_IDS TOOL_PAR_NAMES TOOL_PAR_ARGS TOOL_PAR_WORKDIR

  # Worker function. Each invocation gets a single index, looks up its
  # call data from the parallel arrays, runs the tool, and writes
  # stdout/stderr/status to per-index files in the workdir.
  #
  # set +e because tool:invoke is allowed to return non-zero - we
  # capture the rc into the .status file rather than propagating it as
  # a subshell failure (which would tear down the worker pool).
  # shellcheck disable=SC2329 # invoked indirectly by workers:run-parallel
  _tool_invoke_parallel_worker() {
    local i="$1"
    set +e
    tool:invoke "${TOOL_PAR_NAMES[i]}" "${TOOL_PAR_ARGS[i]}" 2> /dev/null
    local worker_rc=$?
    printf '%s' "$worker_rc" > "${TOOL_PAR_WORKDIR}/${i}.status"
    printf '%s' "$_TOOL_INVOKE_STDOUT" > "${TOOL_PAR_WORKDIR}/${i}.out"
    printf '%s' "$_TOOL_INVOKE_STDERR" > "${TOOL_PAR_WORKDIR}/${i}.err"
  }
  export -f _tool_invoke_parallel_worker

  local max_jobs="${SCRATCH_TOOL_PARALLEL_JOBS:-$(workers:cpu-count)}"
  workers:run-parallel "$max_jobs" "$count" _tool_invoke_parallel_worker

  # Reassemble results in input order
  for ((i = 0; i < count; i++)); do
    id="$(cat "${workdir}/${i}.id")"
    rc="$(cat "${workdir}/${i}.status")"

    if [[ "$rc" == "0" ]]; then
      content="$(cat "${workdir}/${i}.out")"
      ok=true
    else
      content="$(cat "${workdir}/${i}.err")"
      ok=false
      # Fallback for silent failures: tool exited non-zero but wrote
      # nothing to stderr. Synthesize a usable error message so the LLM
      # always gets actionable content.
      if [[ -z "$content" ]]; then
        content="ERROR: tool '${TOOL_PAR_NAMES[i]}' exited with status $rc"
      fi
    fi

    results="$(jq -c \
      --arg id "$id" \
      --arg c "$content" \
      --argjson ok "$ok" \
      '. + [{tool_call_id: $id, content: $c, ok: $ok}]' <<< "$results")"
  done

  printf '%s\n' "$results"
}

export -f tool:invoke-parallel

#===============================================================================
# Toolboxes
#
# A toolbox is a named bundle of tool names with its own is-available gate.
# Lets agents reference logical bundles ("read-only filesystem", "editing")
# instead of enumerating tool names, and lets the policy gate live with the
# bundle rather than at every call site.
#
#   toolboxes/<name>/
#     tools.json     {"description": "...", "tools": ["tool_a", "tool_b"]}
#     is-available   bash; runtime gate
#
# Most toolboxes are pure policy (gated on TTY, edit mode, project context,
# etc.) and have no binary deps of their own. The has-commands declarations
# in is-available are optional - same relaxed contract as tools and agents.
#
# Composition with the existing primitives:
#
#   tool:specs-json $(tool:box read-only | jq -r '.tools[]')
#
# tool:box returns the full tools.json content on success, or the same shape
# with an empty tools array on failure (with a once-per-process warn). The
# empty fallback lets callers always do `... | jq -r '.tools[]'` without
# branching on the error case.
#===============================================================================

#-------------------------------------------------------------------------------
# tool:boxes-dir
#
# Print the absolute path to the toolboxes directory. Honors
# SCRATCH_TOOLBOXES_DIR for tests; defaults to <repo>/toolboxes.
#-------------------------------------------------------------------------------
tool:boxes-dir() {
  if [[ -n "${SCRATCH_TOOLBOXES_DIR:-}" ]]; then
    printf '%s\n' "$SCRATCH_TOOLBOXES_DIR"
  else
    printf '%s\n' "$(cd "$_TOOL_SCRIPTDIR/../toolboxes" 2> /dev/null && pwd -P || echo "$_TOOL_SCRIPTDIR/../toolboxes")"
  fi
}

export -f tool:boxes-dir

#-------------------------------------------------------------------------------
# tool:box-list
#
# Print the names of all toolboxes (sorted, one per line). A toolbox is a
# directory under tool:boxes-dir that contains at least a tools.json file.
# Directories missing tools.json are silently skipped.
#-------------------------------------------------------------------------------
tool:box-list() {
  local boxes_dir
  local d
  local name

  boxes_dir="$(tool:boxes-dir)"
  [[ -d "$boxes_dir" ]] || return 0

  for d in "$boxes_dir"/*/; do
    [[ -d "$d" ]] || continue
    [[ -f "${d}tools.json" ]] || continue
    name="$(basename "$d")"
    printf '%s\n' "$name"
  done | sort
}

export -f tool:box-list

#-------------------------------------------------------------------------------
# tool:box-exists NAME
#
# Return 0 if toolboxes/NAME/ has both required files (tools.json and
# is-available). Return 1 otherwise. Silent. Does NOT check executable bits.
#-------------------------------------------------------------------------------
tool:box-exists() {
  local name="$1"
  local boxes_dir
  boxes_dir="$(tool:boxes-dir)"

  [[ -f "${boxes_dir}/${name}/tools.json" ]] || return 1
  [[ -f "${boxes_dir}/${name}/is-available" ]] || return 1
  return 0
}

export -f tool:box-exists

#-------------------------------------------------------------------------------
# tool:box-dir NAME
#
# Print the absolute path to toolboxes/NAME/. Dies if the directory does not
# exist or is missing the required files.
#-------------------------------------------------------------------------------
tool:box-dir() {
  local name="$1"
  if ! tool:box-exists "$name"; then
    die "toolbox: not found: $name (expected toolboxes/$name/ with tools.json + is-available)"
    return 1
  fi
  printf '%s\n' "$(tool:boxes-dir)/$name"
}

export -f tool:box-dir

#-------------------------------------------------------------------------------
# tool:box NAME
#
# The headline function. Returns the toolbox's tools.json content on stdout.
#
# On success: the original {"description": "...", "tools": [...]} object as
# read from disk.
#
# On failure (is-available exits non-zero): the same object with `tools`
# replaced by `[]`. The description is preserved so callers can still
# render it. Warns ONCE per process per unavailable toolbox via
# tui:debug + the _TOOLBOX_WARNED associative array.
#
# Dies if:
#   - the toolbox doesn't exist (typo case)
#   - tools.json doesn't parse
#
# Honors SCRATCH_TOOL_SKIP_AVAILABILITY=1 by skipping the gate (returns
# the full tools.json regardless of is-available state). Useful in tests.
#-------------------------------------------------------------------------------
tool:box() {
  local name="$1"
  local boxes_dir
  local content
  local script
  local err_file
  local rc

  if ! tool:box-exists "$name"; then
    die "toolbox: not found: $name"
    return 1
  fi

  boxes_dir="$(tool:boxes-dir)"
  content="$(cat "${boxes_dir}/${name}/tools.json")"

  if ! jq -e . <<< "$content" > /dev/null 2>&1; then
    die "toolbox: $name/tools.json does not parse as JSON"
    return 1
  fi

  if [[ "${SCRATCH_TOOL_SKIP_AVAILABILITY:-}" == "1" ]]; then
    printf '%s\n' "$content"
    return 0
  fi

  # Run the toolbox's is-available gate. Same subshell + env contract as
  # tool:available so a die() inside the script propagates as an exit code
  # rather than aborting the caller. We wrap the subshell in `if` so a
  # non-zero exit does not trip set -e in the calling context (set -e
  # does not fire on conditions inside `if`).
  script="${boxes_dir}/${name}/is-available"
  err_file="$(mktemp -t scratch-toolbox-avail-err.XXXXXX)"

  # SC2030/SC2031: subshell-local export is intentional.
  # shellcheck disable=SC2030,SC2031
  if (
    export SCRATCH_HOME
    SCRATCH_HOME="$(cd "$_TOOL_SCRIPTDIR/.." && pwd -P)"
    "$script"
  ) 2> "$err_file"; then
    rc=0
  else
    rc=$?
  fi
  local err_msg
  err_msg="$(cat "$err_file")"
  rm -f "$err_file"

  if ((rc == 0)); then
    printf '%s\n' "$content"
    return 0
  fi

  # Unavailable. Warn ONCE per process for this toolbox name, then return
  # the empty-tools fallback so callers can keep iterating without
  # branching on the error.
  if [[ -z "${_TOOLBOX_WARNED[$name]:-}" ]]; then
    _TOOLBOX_WARNED[$name]=1
    if type -t tui:debug &> /dev/null; then
      tui:debug "tool:box: toolbox unavailable" name "$name" reason "$err_msg" || true
    fi
  fi

  jq -c --argjson c "$content" '$c + {tools: []}' <<< "$content"
}

export -f tool:box
