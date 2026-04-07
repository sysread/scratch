#!/usr/bin/env bats

# vim: set ft=bash
# shellcheck disable=SC2016
set -euo pipefail

#-------------------------------------------------------------------------------
# Tests for lib/venice.sh
#
# venice:api-key resolution tests are pure (no curl involved).
# venice:curl tests install a curl stub that writes a pre-canned body to the
# file specified via -o and prints a pre-canned status code to stdout. The
# stub reads those from files under $BATS_TEST_TMPDIR so the test body can
# configure them per case.
#-------------------------------------------------------------------------------

setup() {
  SCRIPTDIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" > /dev/null 2>&1 && pwd)"
  SCRATCH_HOME="$(cd "${SCRIPTDIR}/.." && pwd)"
  source "${SCRIPTDIR}/helpers.sh"
  source "${SCRATCH_HOME}/lib/venice.sh"

  # Defaults used by venice:curl tests
  export SCRATCH_VENICE_API_KEY="test-key"
}

# Install a curl stub that replays canned body + status for venice:curl tests.
# Writes:
#   BATS_TEST_TMPDIR/curl-response.body    (body content)
#   BATS_TEST_TMPDIR/curl-response.status  (status code)
install_curl_stub() {
  local body="$1"
  local status="$2"

  printf '%s' "$body" > "${BATS_TEST_TMPDIR}/curl-response.body"
  printf '%s' "$status" > "${BATS_TEST_TMPDIR}/curl-response.status"

  make_stub curl "$(
    cat << STUB
#!/usr/bin/env bash
# Find -o FILE in args and write the canned body there
body_file=""
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    -o) body_file="\$2"; shift 2 ;;
    *) shift ;;
  esac
done
if [[ -n "\$body_file" ]]; then
  cat '${BATS_TEST_TMPDIR}/curl-response.body' > "\$body_file"
fi
cat '${BATS_TEST_TMPDIR}/curl-response.status'
STUB
  )" > /dev/null

  prepend_stub_path
}

# ---------------------------------------------------------------------------
# venice:api-key
# ---------------------------------------------------------------------------

@test "venice:api-key prefers SCRATCH_VENICE_API_KEY when both are set" {
  export SCRATCH_VENICE_API_KEY="from-scratch"
  export VENICE_API_KEY="from-venice"
  run venice:api-key
  is "$status" 0
  is "$output" "from-scratch"
}

@test "venice:api-key falls back to VENICE_API_KEY" {
  unset SCRATCH_VENICE_API_KEY
  export VENICE_API_KEY="from-venice"
  run venice:api-key
  is "$status" 0
  is "$output" "from-venice"
}

@test "venice:api-key dies when neither is set" {
  unset SCRATCH_VENICE_API_KEY
  unset VENICE_API_KEY
  run bash -c 'set -e; source '"${SCRATCH_HOME}"'/lib/venice.sh; venice:api-key 2>&1'
  is "$status" 1
  [[ "$output" == *"no API key found"* ]]
  [[ "$output" == *"SCRATCH_VENICE_API_KEY"* ]]
  [[ "$output" == *"VENICE_API_KEY"* ]]
}

@test "venice:api-key dies when both are empty strings" {
  export SCRATCH_VENICE_API_KEY=""
  export VENICE_API_KEY=""
  run bash -c 'set -e; export SCRATCH_VENICE_API_KEY=""; export VENICE_API_KEY=""; source '"${SCRATCH_HOME}"'/lib/venice.sh; venice:api-key 2>&1'
  is "$status" 1
  [[ "$output" == *"no API key found"* ]]
}

# ---------------------------------------------------------------------------
# venice:base-url
# ---------------------------------------------------------------------------

@test "venice:base-url returns the hard-coded API root" {
  run venice:base-url
  is "$status" 0
  is "$output" "https://api.venice.ai/api/v1"
}

# ---------------------------------------------------------------------------
# venice:config-dir
# ---------------------------------------------------------------------------

@test "venice:config-dir returns and creates the config dir under HOME" {
  run venice:config-dir
  is "$status" 0
  is "$output" "${HOME}/.config/scratch/venice"
  [[ -d "$output" ]]
}

# ---------------------------------------------------------------------------
# venice:curl - success paths
# ---------------------------------------------------------------------------

@test "venice:curl returns body on 200" {
  install_curl_stub '{"ok":true}' "200"
  run venice:curl GET /models
  is "$status" 0
  is "$output" '{"ok":true}'
}

@test "venice:curl handles 201 success" {
  install_curl_stub '{"created":true}' "201"
  run venice:curl POST /foo '{"x":1}'
  is "$status" 0
  is "$output" '{"created":true}'
}

@test "venice:curl sends the body when provided" {
  # We can't directly verify stdin bytes without a more elaborate stub,
  # but we can verify the call succeeds end-to-end with a body argument.
  install_curl_stub '{"echoed":"ok"}' "200"
  run venice:curl POST /chat/completions '{"model":"x","messages":[]}'
  is "$status" 0
  is "$output" '{"echoed":"ok"}'
}

# ---------------------------------------------------------------------------
# venice:curl - documented error codes get friendly messages
# ---------------------------------------------------------------------------

@test "venice:curl dies with credit message on 402" {
  install_curl_stub '{"error":"payment required"}' "402"
  run bash -c 'set -e; export SCRATCH_VENICE_API_KEY=test-key; export PATH="'"${BATS_TEST_TMPDIR}"'/stubbin:$PATH"; source '"${SCRATCH_HOME}"'/lib/venice.sh; venice:curl GET /models 2>&1'
  is "$status" 1
  [[ "$output" == *"insufficient credits"* ]]
  [[ "$output" == *"402"* ]]
}

@test "venice:curl dies with auth message on 401" {
  install_curl_stub '{"error":"unauthorized"}' "401"
  run bash -c 'set -e; export SCRATCH_VENICE_API_KEY=test-key; export PATH="'"${BATS_TEST_TMPDIR}"'/stubbin:$PATH"; source '"${SCRATCH_HOME}"'/lib/venice.sh; venice:curl GET /models 2>&1'
  is "$status" 1
  [[ "$output" == *"authentication failed"* ]]
  [[ "$output" == *"401"* ]]
}

@test "venice:curl dies with rate-limit message on 429" {
  install_curl_stub '{"error":"rate limited"}' "429"
  run bash -c 'set -e; export SCRATCH_VENICE_API_KEY=test-key; export PATH="'"${BATS_TEST_TMPDIR}"'/stubbin:$PATH"; source '"${SCRATCH_HOME}"'/lib/venice.sh; venice:curl GET /models 2>&1'
  is "$status" 1
  [[ "$output" == *"rate limited"* ]]
  [[ "$output" == *"429"* ]]
}

@test "venice:curl dies with capacity message on 503" {
  install_curl_stub '{"error":"busy"}' "503"
  run bash -c 'set -e; export SCRATCH_VENICE_API_KEY=test-key; export PATH="'"${BATS_TEST_TMPDIR}"'/stubbin:$PATH"; source '"${SCRATCH_HOME}"'/lib/venice.sh; venice:curl GET /models 2>&1'
  is "$status" 1
  [[ "$output" == *"at capacity"* ]]
  [[ "$output" == *"503"* ]]
}

@test "venice:curl dies with unknown-status message on 418" {
  install_curl_stub '{"error":"teapot"}' "418"
  run bash -c 'set -e; export SCRATCH_VENICE_API_KEY=test-key; export PATH="'"${BATS_TEST_TMPDIR}"'/stubbin:$PATH"; source '"${SCRATCH_HOME}"'/lib/venice.sh; venice:curl GET /models 2>&1'
  is "$status" 1
  [[ "$output" == *"418"* ]]
  [[ "$output" == *"teapot"* ]]
}
