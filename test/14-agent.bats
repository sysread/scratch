#!/usr/bin/env bats

# vim: set ft=bash
# shellcheck disable=SC2016
set -euo pipefail

#-------------------------------------------------------------------------------
# Tests for lib/agent.sh
#
# Agents are discovered via SCRATCH_AGENTS_DIR (which lib/agent.sh honors when
# set, defaulting to <repo>/agents otherwise). Each test points it at a fresh
# subdir under BATS_TEST_TMPDIR and seeds it with fake agents via the
# make_fake_agent helper.
#
# Agents that need real LLM connectivity are tested via the integration suite.
# The fake agents here echo their env vars or exit with a canned status,
# exercising the lib's discovery, gating, and fork-with-env logic.
#-------------------------------------------------------------------------------

setup() {
  SCRIPTDIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" > /dev/null 2>&1 && pwd)"
  SCRATCH_HOME="$(cd "${SCRIPTDIR}/.." && pwd)"
  source "${SCRIPTDIR}/helpers.sh"
  source "${SCRATCH_HOME}/lib/agent.sh"

  # Per-test HOME so anything resolving under $HOME/.config/scratch/...
  # is fresh for every test.
  export HOME="${BATS_TEST_TMPDIR}/home"
  mkdir -p "$HOME"

  # Per-test agents directory. lib/agent.sh's agent:agents-dir honors this.
  export SCRATCH_AGENTS_DIR="${BATS_TEST_TMPDIR}/agents"
  mkdir -p "$SCRATCH_AGENTS_DIR"
}

#-------------------------------------------------------------------------------
# Helpers
#-------------------------------------------------------------------------------

# make_fake_agent NAME [RUN_BODY] [AVAIL_EXIT_CODE] [DESCRIPTION]
#
# Creates a complete fake agent under $SCRATCH_AGENTS_DIR/NAME with all three
# required files. RUN_BODY is the body of run (after the bash shebang);
# defaults to "cat" so the agent echoes its stdin. AVAIL_EXIT_CODE is the
# exit code is-available returns; defaults to 0.
make_fake_agent() {
  local name="$1"
  local run_body="${2:-cat}"
  local avail_exit="${3:-0}"
  local desc="${4:-fake test agent}"
  local dir="${SCRATCH_AGENTS_DIR}/${name}"

  mkdir -p "$dir"

  jq -n \
    --arg n "$name" \
    --arg d "$desc" \
    '{name: $n, description: $d}' \
    > "${dir}/spec.json"

  printf '#!/usr/bin/env bash\nset -euo pipefail\n%s\n' "$run_body" > "${dir}/run"
  chmod +x "${dir}/run"

  printf '#!/usr/bin/env bash\nexit %s\n' "$avail_exit" > "${dir}/is-available"
  chmod +x "${dir}/is-available"

  return 0
}

# ---------------------------------------------------------------------------
# agent:agents-dir
# ---------------------------------------------------------------------------

@test "agent:agents-dir honors SCRATCH_AGENTS_DIR override" {
  run agent:agents-dir
  is "$status" 0
  is "$output" "$SCRATCH_AGENTS_DIR"
}

@test "agent:agents-dir falls back to <repo>/agents when override is unset" {
  unset SCRATCH_AGENTS_DIR
  run agent:agents-dir
  is "$status" 0
  [[ "$output" == */agents ]]
}

# ---------------------------------------------------------------------------
# agent:list
# ---------------------------------------------------------------------------

@test "agent:list returns empty when agents dir is empty" {
  run agent:list
  is "$status" 0
  is "$output" ""
}

@test "agent:list returns one agent when one is defined" {
  make_fake_agent solo
  run agent:list
  is "$output" "solo"
}

@test "agent:list returns multiple agents sorted" {
  make_fake_agent zebra
  make_fake_agent alpha
  make_fake_agent mike
  run agent:list
  is "$output" "alpha
mike
zebra"
}

@test "agent:list skips dirs without spec.json" {
  make_fake_agent good
  mkdir -p "${SCRATCH_AGENTS_DIR}/incomplete"
  printf '#!/usr/bin/env bash\ncat\n' > "${SCRATCH_AGENTS_DIR}/incomplete/run"
  chmod +x "${SCRATCH_AGENTS_DIR}/incomplete/run"

  run agent:list
  is "$output" "good"
}

# ---------------------------------------------------------------------------
# agent:exists
# ---------------------------------------------------------------------------

@test "agent:exists returns 0 for a complete agent" {
  make_fake_agent complete
  run agent:exists complete
  is "$status" 0
}

@test "agent:exists returns 1 for an unknown agent" {
  run agent:exists nonexistent
  is "$status" 1
}

@test "agent:exists returns 1 for a dir missing run" {
  local dir="${SCRATCH_AGENTS_DIR}/nourun"
  mkdir -p "$dir"
  printf '{}' > "${dir}/spec.json"
  printf '#!/usr/bin/env bash\nexit 0\n' > "${dir}/is-available"
  chmod +x "${dir}/is-available"

  run agent:exists nourun
  is "$status" 1
}

@test "agent:exists returns 1 for a dir missing is-available" {
  local dir="${SCRATCH_AGENTS_DIR}/noavail"
  mkdir -p "$dir"
  printf '{}' > "${dir}/spec.json"
  printf '#!/usr/bin/env bash\ncat\n' > "${dir}/run"
  chmod +x "${dir}/run"

  run agent:exists noavail
  is "$status" 1
}

# ---------------------------------------------------------------------------
# agent:dir
# ---------------------------------------------------------------------------

@test "agent:dir prints absolute path for a known agent" {
  make_fake_agent here
  run agent:dir here
  is "$status" 0
  is "$output" "${SCRATCH_AGENTS_DIR}/here"
}

@test "agent:dir dies for an unknown agent" {
  run agent:dir ghost
  is "$status" 1
  [[ "$output" == *"not found"* ]]
}

# ---------------------------------------------------------------------------
# agent:spec
# ---------------------------------------------------------------------------

@test "agent:spec prints the raw spec.json" {
  make_fake_agent specced "cat" 0 "a useful agent"
  run agent:spec specced
  is "$status" 0
  run jq -r '.description' <<< "$output"
  is "$output" "a useful agent"
}

@test "agent:spec dies for an unknown agent" {
  run agent:spec ghost
  is "$status" 1
}

# ---------------------------------------------------------------------------
# agent:available
# ---------------------------------------------------------------------------

@test "agent:available returns 0 when is-available exits 0" {
  make_fake_agent ready "cat" 0
  run agent:available ready
  is "$status" 0
}

@test "agent:available returns the script's exit code on failure" {
  make_fake_agent broken "cat" 7
  run agent:available broken
  is "$status" 7
}

@test "agent:available captures stderr from is-available into _AGENT_AVAILABILITY_ERR" {
  local dir="${SCRATCH_AGENTS_DIR}/loud"
  mkdir -p "$dir"
  printf '{}' > "${dir}/spec.json"
  printf '#!/usr/bin/env bash\ncat\n' > "${dir}/run"
  chmod +x "${dir}/run"
  printf '#!/usr/bin/env bash\necho "missing precondition foo" >&2\nexit 1\n' > "${dir}/is-available"
  chmod +x "${dir}/is-available"

  agent:available loud || true
  [[ "$_AGENT_AVAILABILITY_ERR" == *"missing precondition foo"* ]]
}

@test "agent:available honors SCRATCH_AGENT_SKIP_AVAILABILITY=1" {
  make_fake_agent broken "cat" 1
  export SCRATCH_AGENT_SKIP_AVAILABILITY=1
  run agent:available broken
  is "$status" 0
}

# ---------------------------------------------------------------------------
# agent:run - basic invocation
# ---------------------------------------------------------------------------

@test "agent:run pipes stdin through to the run script" {
  make_fake_agent echobot "cat"
  # Order matters: source first, then pipe to agent:run. Piping to source
  # would consume stdin before agent:run could see it.
  run bash -c "source '${SCRATCH_HOME}/lib/agent.sh'; echo 'hello world' | agent:run echobot"
  is "$status" 0
  is "$output" "hello world"
}

@test "agent:run propagates the run script's stdout" {
  make_fake_agent printer "echo from-the-agent"
  run agent:run printer < /dev/null
  is "$status" 0
  is "$output" "from-the-agent"
}

@test "agent:run propagates the run script's exit code" {
  make_fake_agent failing "exit 42"
  run agent:run failing < /dev/null
  is "$status" 42
}

@test "agent:run sets SCRATCH_AGENT_DIR in the env" {
  make_fake_agent introspect 'echo "$SCRATCH_AGENT_DIR"'
  run agent:run introspect < /dev/null
  is "$status" 0
  is "$output" "${SCRATCH_AGENTS_DIR}/introspect"
}

@test "agent:run sets SCRATCH_HOME in the env" {
  make_fake_agent introspect 'echo "$SCRATCH_HOME"'
  run agent:run introspect < /dev/null
  is "$status" 0
  [[ "$output" == */dev/scratch || "$output" == "$SCRATCH_HOME" ]]
}

# ---------------------------------------------------------------------------
# agent:run - availability gate
# ---------------------------------------------------------------------------

@test "agent:run dies for an unknown agent" {
  run agent:run ghost < /dev/null
  is "$status" 1
  [[ "$output" == *"not found"* ]]
}

@test "agent:run refuses to invoke an unavailable agent" {
  local dir="${SCRATCH_AGENTS_DIR}/gated"
  mkdir -p "$dir"
  printf '{}' > "${dir}/spec.json"
  printf '#!/usr/bin/env bash\necho "should not run"\n' > "${dir}/run"
  chmod +x "${dir}/run"
  printf '#!/usr/bin/env bash\necho "edit mode required" >&2\nexit 1\n' > "${dir}/is-available"
  chmod +x "${dir}/is-available"

  run agent:run gated < /dev/null
  is "$status" 1
  [[ "$output" == *"not available"* ]]
  [[ "$output" == *"edit mode required"* ]]
  # The run script must NOT have executed
  [[ "$output" != *"should not run"* ]]
}

# ---------------------------------------------------------------------------
# agent:run - recursion guard
# ---------------------------------------------------------------------------

@test "agent:run sets SCRATCH_AGENT_DEPTH=1 on a top-level call" {
  make_fake_agent depth 'echo "$SCRATCH_AGENT_DEPTH"'
  unset SCRATCH_AGENT_DEPTH
  run agent:run depth < /dev/null
  is "$status" 0
  is "$output" "1"
}

@test "agent:run increments SCRATCH_AGENT_DEPTH on a nested call" {
  make_fake_agent depth 'echo "$SCRATCH_AGENT_DEPTH"'
  export SCRATCH_AGENT_DEPTH=3
  run agent:run depth < /dev/null
  is "$status" 0
  is "$output" "4"
}

@test "agent:run dies when SCRATCH_AGENT_DEPTH would exceed SCRATCH_AGENT_MAX_DEPTH" {
  make_fake_agent depth 'echo should-not-run'
  export SCRATCH_AGENT_DEPTH=8
  export SCRATCH_AGENT_MAX_DEPTH=8
  run agent:run depth < /dev/null
  is "$status" 1
  [[ "$output" == *"recursion limit"* ]]
  [[ "$output" != *"should-not-run"* ]]
}

@test "agent:run honors a custom SCRATCH_AGENT_MAX_DEPTH" {
  make_fake_agent depth 'echo "$SCRATCH_AGENT_DEPTH"'
  export SCRATCH_AGENT_DEPTH=2
  export SCRATCH_AGENT_MAX_DEPTH=3
  run agent:run depth < /dev/null
  is "$status" 0
  is "$output" "3"
}

# ===========================================================================
# agent:simple-completion - common-case helper tests
#
# Each test stubs chat:completion / chat:complete-with-tools and the model
# profile lookups directly in the test process. bats `run` inherits the
# stubs through the function exports without re-sourcing lib/agent.sh
# (which would overwrite them). The integration test in
# test/integration/02-agent.bats covers the real-API path.
# ===========================================================================

setup_simple_completion_stubs() {
  export SCRATCH_PROMPTS_DIR="${BATS_TEST_TMPDIR}/prompts"
  mkdir -p "$SCRATCH_PROMPTS_DIR"

  CHAT_CALLS_LOG="${BATS_TEST_TMPDIR}/chat-calls.log"
  : > "$CHAT_CALLS_LOG"
  export CHAT_CALLS_LOG

  model:profile:model() {
    printf '%s' "fake-model-id"
  }
  export -f model:profile:model

  model:profile:extras() {
    printf '%s' '{"temperature":0.5}'
  }
  export -f model:profile:extras

  chat:completion() {
    {
      printf 'model=%s\n' "$1"
      printf 'messages=%s\n' "$2"
      printf 'extras=%s\n' "${3:-}"
    } >> "$CHAT_CALLS_LOG"

    local user_msg
    user_msg="$(jq -r '.[1].content' <<< "$2")"
    jq -c -n --arg c "$user_msg" '{choices:[{message:{content:$c}}]}'
  }
  export -f chat:completion

  chat:complete-with-tools() {
    {
      printf 'tools-call: model=%s\n' "$1"
      printf 'messages=%s\n' "$2"
      printf 'tools=%s\n' "$3"
      printf 'extras=%s\n' "${4:-}"
    } >> "$CHAT_CALLS_LOG"

    local user_msg
    user_msg="$(jq -r '.[1].content' <<< "$2")"
    jq -c -n --arg c "$user_msg" '{choices:[{message:{content:$c}}]}'
  }
  export -f chat:complete-with-tools
}

@test "agent:simple-completion: no-tools path passes stdin as the user message" {
  setup_simple_completion_stubs
  printf 'system prompt body\n' > "${SCRATCH_PROMPTS_DIR}/test.md"
  printf 'hello stdin' > "${BATS_TEST_TMPDIR}/in"

  run agent:simple-completion balanced test < "${BATS_TEST_TMPDIR}/in"
  is "$status" 0
  is "$output" "hello stdin"
}

@test "agent:simple-completion: loads the system prompt via prompt:load" {
  setup_simple_completion_stubs
  printf 'MARKER_SYSTEM_PROMPT\n' > "${SCRATCH_PROMPTS_DIR}/marked.md"

  run agent:simple-completion balanced marked < /dev/null
  is "$status" 0
  grep -q 'MARKER_SYSTEM_PROMPT' "$CHAT_CALLS_LOG"
}

@test "agent:simple-completion: passes profile model + extras to chat:completion" {
  setup_simple_completion_stubs
  printf 'sys\n' > "${SCRATCH_PROMPTS_DIR}/p.md"

  run agent:simple-completion balanced p < /dev/null
  is "$status" 0
  grep -q 'model=fake-model-id' "$CHAT_CALLS_LOG"
  grep -q '"temperature":0.5' "$CHAT_CALLS_LOG"
}

@test "agent:simple-completion: caller extras override profile extras" {
  setup_simple_completion_stubs
  printf 'sys\n' > "${SCRATCH_PROMPTS_DIR}/p.md"

  run agent:simple-completion balanced p '' '{"temperature":0.99}' < /dev/null
  is "$status" 0
  grep -q '"temperature":0.99' "$CHAT_CALLS_LOG"
}

@test "agent:simple-completion: routes through chat:complete-with-tools when tools are non-empty" {
  setup_simple_completion_stubs
  printf 'sys\n' > "${SCRATCH_PROMPTS_DIR}/p.md"

  run agent:simple-completion balanced p '["notify"]' < /dev/null
  is "$status" 0
  grep -q 'tools-call' "$CHAT_CALLS_LOG"
  grep -q '"notify"' "$CHAT_CALLS_LOG"
}

@test "agent:simple-completion: empty tools array routes through chat:completion (no tools)" {
  setup_simple_completion_stubs
  printf 'sys\n' > "${SCRATCH_PROMPTS_DIR}/p.md"

  run agent:simple-completion balanced p '[]' < /dev/null
  is "$status" 0
  run ! grep -q 'tools-call' "$CHAT_CALLS_LOG"
}

@test "agent:simple-completion: dies when prompt is missing" {
  setup_simple_completion_stubs

  run agent:simple-completion balanced no-such-prompt < /dev/null
  is "$status" 1
  [[ "$output" == *"no-such-prompt.md"* ]]
}
