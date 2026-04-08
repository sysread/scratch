#!/usr/bin/env bats

# vim: set ft=bash
set -euo pipefail

#-------------------------------------------------------------------------------
# Tests for lib/prompt.sh
#
# Each test sets SCRATCH_PROMPTS_DIR to a fresh fixture root under the test
# tmpdir, populates it with the files the test cares about, and exercises
# prompt:load / prompt:render against that root.
#-------------------------------------------------------------------------------

setup() {
  SCRIPTDIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" > /dev/null 2>&1 && pwd)"
  SCRATCH_HOME="$(cd "${SCRIPTDIR}/.." && pwd)"
  source "${SCRIPTDIR}/helpers.sh"
  source "${SCRATCH_HOME}/lib/prompt.sh"

  export HOME="${BATS_TEST_TMPDIR}/home"
  mkdir -p "$HOME"

  export SCRATCH_PROMPTS_DIR="${BATS_TEST_TMPDIR}/prompts"
  mkdir -p "$SCRATCH_PROMPTS_DIR"
}

# ---------------------------------------------------------------------------
# prompt:dir
# ---------------------------------------------------------------------------

@test "prompt:dir honors SCRATCH_PROMPTS_DIR override" {
  run prompt:dir
  is "$status" 0
  is "$output" "$SCRATCH_PROMPTS_DIR"
}

@test "prompt:dir falls back to data/prompts next to lib when override is unset" {
  unset SCRATCH_PROMPTS_DIR
  run prompt:dir
  is "$status" 0
  [[ "$output" == */data/prompts ]]
}

# ---------------------------------------------------------------------------
# prompt:load
# ---------------------------------------------------------------------------

@test "prompt:load returns the contents of a top-level prompt file" {
  printf 'hello prompt\n' > "${SCRATCH_PROMPTS_DIR}/greeting.md"
  run prompt:load greeting
  is "$status" 0
  is "$output" "hello prompt"
}

@test "prompt:load resolves nested names like accumulator/system" {
  mkdir -p "${SCRATCH_PROMPTS_DIR}/accumulator"
  printf 'system prompt body\n' > "${SCRATCH_PROMPTS_DIR}/accumulator/system.md"
  run prompt:load accumulator/system
  is "$status" 0
  is "$output" "system prompt body"
}

@test "prompt:load preserves multiple lines and whitespace" {
  printf 'line one\nline two\n\nline four\n' > "${SCRATCH_PROMPTS_DIR}/multi.md"
  run prompt:load multi
  is "$status" 0
  # bats $output strips a trailing newline but preserves internal blanks
  is "$output" "line one
line two

line four"
}

@test "prompt:load dies with the resolved path on a missing file" {
  run prompt:load no-such-prompt
  is "$status" 1
  [[ "$output" == *"no-such-prompt.md"* ]]
  [[ "$output" == *"$SCRATCH_PROMPTS_DIR"* ]]
}

# ---------------------------------------------------------------------------
# prompt:render
# ---------------------------------------------------------------------------

@test "prompt:render substitutes a single {{var}} placeholder" {
  printf 'hello {{name}}\n' > "${SCRATCH_PROMPTS_DIR}/greet.md"
  run prompt:render greet name=world
  is "$status" 0
  is "$output" "hello world"
}

@test "prompt:render substitutes multiple variables in one call" {
  printf '{{greeting}}, {{name}}!\n' > "${SCRATCH_PROMPTS_DIR}/g.md"
  run prompt:render g greeting=hi name=jeff
  is "$status" 0
  is "$output" "hi, jeff!"
}

@test "prompt:render substitutes the same placeholder multiple times" {
  printf '{{x}} and {{x}} again\n' > "${SCRATCH_PROMPTS_DIR}/dup.md"
  run prompt:render dup x=foo
  is "$status" 0
  is "$output" "foo and foo again"
}

@test "prompt:render leaves unsupplied placeholders as-is" {
  printf '{{a}} and {{b}}\n' > "${SCRATCH_PROMPTS_DIR}/p.md"
  run prompt:render p a=alpha
  is "$status" 0
  is "$output" "alpha and {{b}}"
}

@test "prompt:render handles values containing forward slashes" {
  printf 'path is {{p}}\n' > "${SCRATCH_PROMPTS_DIR}/p.md"
  run prompt:render p p=/usr/local/bin
  is "$status" 0
  is "$output" "path is /usr/local/bin"
}

@test "prompt:render handles values containing ampersands" {
  printf 'cmd is {{c}}\n' > "${SCRATCH_PROMPTS_DIR}/c.md"
  run prompt:render c c='foo & bar'
  is "$status" 0
  is "$output" "cmd is foo & bar"
}

@test "prompt:render handles values containing pipe characters" {
  printf 'pipeline is {{p}}\n' > "${SCRATCH_PROMPTS_DIR}/p.md"
  run prompt:render p p='cat foo | grep bar'
  is "$status" 0
  is "$output" "pipeline is cat foo | grep bar"
}

@test "prompt:render handles values containing backslashes" {
  printf 'esc is {{e}}\n' > "${SCRATCH_PROMPTS_DIR}/e.md"
  run prompt:render e e='a\b\c'
  is "$status" 0
  is "$output" 'esc is a\b\c'
}

@test "prompt:render handles values containing literal newlines" {
  # Multi-line values must round-trip cleanly. The accumulator feeds
  # multi-line accumulated_notes back into the next round's system
  # prompt as a {{notes}} substitution; if newline handling broke,
  # every multi-round accumulator run would corrupt its own buffer.
  printf 'before\n{{notes}}\nafter\n' > "${SCRATCH_PROMPTS_DIR}/m.md"
  run prompt:render m notes='line one
line two
line three'
  is "$status" 0
  is "$output" "before
line one
line two
line three
after"
}

@test "prompt:render handles values containing curly braces" {
  printf 'json: {{j}}\n' > "${SCRATCH_PROMPTS_DIR}/j.md"
  run prompt:render j j='{"key": "value"}'
  is "$status" 0
  is "$output" 'json: {"key": "value"}'
}

@test "prompt:render dies on a missing prompt file" {
  run prompt:render nope key=val
  is "$status" 1
  [[ "$output" == *"nope.md"* ]]
}
