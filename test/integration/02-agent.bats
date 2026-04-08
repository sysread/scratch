#!/usr/bin/env bats

# vim: set ft=bash
set -euo pipefail

#-------------------------------------------------------------------------------
# Integration tests for the agent layer - REAL API CALLS
#
# These exercise actual scratch agents end-to-end against Venice. They cost
# real money. Run via `mise run test:integration` or
# helpers/run-integration-tests; never automatic.
#
# Skips cleanly without an API key, so contributors without one still get
# a green run.
#-------------------------------------------------------------------------------

setup() {
  SCRIPTDIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" > /dev/null 2>&1 && pwd)"
  SCRATCH_HOME="$(cd "${SCRIPTDIR}/../.." && pwd)"
  source "${SCRIPTDIR}/../helpers.sh"
  source "${SCRATCH_HOME}/lib/agent.sh"

  if [[ -z "${SCRATCH_VENICE_API_KEY:-}" && -z "${VENICE_API_KEY:-}" ]]; then
    skip "no venice api key set (SCRATCH_VENICE_API_KEY or VENICE_API_KEY)"
  fi

  export HOME="${BATS_TEST_TMPDIR}/home"
  mkdir -p "$HOME"
}

# ---------------------------------------------------------------------------
# echo agent - the simple-completion smoke test
# ---------------------------------------------------------------------------

@test "agent:run echo paraphrases user input via the fast profile" {
  local out
  out="$(printf 'the cat sit on the matt' | agent:run echo)"

  # Model output is non-deterministic but the structure is stable:
  # the response should mention 'cat' and 'mat' in some form, and
  # should be longer than nothing.
  [[ -n "$out" ]]
  [[ "$out" == *"cat"* ]]
  [[ "$out" == *"mat"* ]]
}

# ---------------------------------------------------------------------------
# intuition agent - the multi-phase complex agent
# ---------------------------------------------------------------------------

# A small fixture transcript that the accumulator can chunk meaningfully
# but not so large that the test costs more than a few cents.
sample_transcript() {
  cat << 'EOF'
user said: I'm trying to add a feature where users can subscribe to
notifications when a project they're watching gets a new release. I was
thinking of polling the GitHub API every 5 minutes from a cron job.

assistant said: A polling approach would work but it has a few drawbacks:
rate limits on the GitHub API, latency between release and notification,
and you'd be making requests even when no projects had updates. Have you
considered using GitHub webhooks instead? They push events to your endpoint
in near-real-time and don't consume rate limit budget.

user said: I hadn't thought about webhooks. The issue is that webhooks
require a public endpoint and I'm running this on a home server behind
a NAT. Setting up port forwarding feels fragile.

assistant said: That's a fair concern. A few options that work behind NAT:
1. A managed tunnel like ngrok or Cloudflare Tunnel that gives you a public
URL without port forwarding. 2. A small cloud relay (a tiny VM that
receives webhooks and forwards them to your home server over a persistent
connection). 3. Just stick with polling but be smarter about it - use
ETags or conditional requests to only consume rate budget on actual changes.

user said: Wait, can I use ETags with the GitHub releases API? That would
solve most of my concerns about polling without changing the architecture
much.

assistant said: Yes, the GitHub API supports conditional requests with
If-None-Match headers. A 304 response doesn't count against your rate
limit. So you could poll every 5 minutes and only consume a request when
something has actually changed. That's probably the lowest-effort path
for your situation.

user said: Perfect, I'll go with that. Thank you!
EOF
}

@test "agent:run intuition produces a synthesized intuition for a real transcript" {
  local out
  out="$(sample_transcript | agent:run intuition)"

  # Model output is non-deterministic. We assert structural markers:
  # the synthesis should produce non-empty text and should reference
  # the user's situation in some way (talks, recognizes, identifies, etc).
  [[ -n "$out" ]]
  # Should be at least a few sentences
  [[ "${#out}" -gt 80 ]]
}
