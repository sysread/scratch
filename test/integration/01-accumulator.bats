#!/usr/bin/env bats

# vim: set ft=bash
set -euo pipefail

#-------------------------------------------------------------------------------
# Integration tests for lib/accumulator.sh - REAL API CALLS
#
# These exercise the full chunk + reduce + finalize loop against a real
# Venice model. They cost real money. Run via `mise run test:integration`
# or helpers/run-integration-tests; never automatic.
#
# The first test was the smoke test that caught two bugs in the
# accumulator series:
#   1. prompt:render's old sed implementation died on multi-line values
#      (bash 5.x ${var//pat/repl} also treats & as a backref - the
#      replacement now escapes \\ then & before substituting).
#   2. Confirmed venice-uncensored does support response_format strict
#      mode end-to-end despite the small model size.
#
# Without these tests, both bugs would have shipped because the unit
# tests stub chat:completion and never exercise the actual prompt-
# substitution + structured-output round trip.
#-------------------------------------------------------------------------------

setup() {
  SCRIPTDIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" > /dev/null 2>&1 && pwd)"
  SCRATCH_HOME="$(cd "${SCRIPTDIR}/../.." && pwd)"
  source "${SCRIPTDIR}/../helpers.sh"
  source "${SCRATCH_HOME}/lib/accumulator.sh"

  if [[ -z "${SCRATCH_VENICE_API_KEY:-}" && -z "${VENICE_API_KEY:-}" ]]; then
    skip "no venice api key set (SCRATCH_VENICE_API_KEY or VENICE_API_KEY)"
  fi

  export HOME="${BATS_TEST_TMPDIR}/home"
  mkdir -p "$HOME"
}

# A small input that we KNOW the answer to. Five distinct functions,
# each on its own export -f line, so the model has clear ground truth
# to extract and we can assert specific names appear in the result.
sample_input() {
  cat << 'EOF'
function alpha_one() { echo "alpha one"; }
export -f alpha_one

function beta_two() { echo "beta two"; }
export -f beta_two

function gamma_three() { echo "gamma three"; }
export -f gamma_three

function delta_four() { echo "delta four"; }
export -f delta_four

function epsilon_five() { echo "epsilon five"; }
export -f epsilon_five
EOF
}

# ---------------------------------------------------------------------------
# accumulate:run - end-to-end against a real model with forced chunking
# ---------------------------------------------------------------------------

@test "accumulate:run extracts function names across multiple chunks" {
  # max_context=80 tokens against the ~330-char input gives a chunk
  # budget of 80 * 4 * 0.7 = 224 chars, so the input splits into 3-5
  # chunks. This exercises the multi-round accumulation path, the
  # structured-output schema, and the prompt:render multi-line value
  # path that the original sed implementation broke on.
  local input
  input="$(sample_input)"

  local prompt="List every function in the input. For each, give the function name and a one-line description of what it does."

  local output
  output="$(accumulate:run venice-uncensored "$prompt" "$input" '{"max_context":80}')"

  # All five function names should appear in the final output. The
  # model is allowed to format the list however it wants; we only
  # assert the names are present.
  [[ "$output" == *"alpha_one"* ]]
  [[ "$output" == *"beta_two"* ]]
  [[ "$output" == *"gamma_three"* ]]
  [[ "$output" == *"delta_four"* ]]
  [[ "$output" == *"epsilon_five"* ]]
}

@test "accumulate:run-profile resolves long-context and runs end-to-end" {
  # The long-context profile points at qwen-3-6-plus (1M token context).
  # Run a tiny input through it just to confirm the profile resolution,
  # extras merge, and full pipeline land green against the real API.
  local input="The capital of France is Paris. The capital of Japan is Tokyo. The capital of Brazil is Brasilia."
  local prompt="List every (country, capital) pair from the input."

  local output
  output="$(accumulate:run-profile long-context "$prompt" "$input")"

  [[ "$output" == *"France"* ]]
  [[ "$output" == *"Paris"* ]]
  [[ "$output" == *"Japan"* ]]
  [[ "$output" == *"Tokyo"* ]]
  [[ "$output" == *"Brazil"* ]]
  # "Brasilia" may be rendered with or without the accent; allow both
  [[ "$output" == *"Brasilia"* || "$output" == *"Brasília"* ]]
}
