#!/usr/bin/env bats

# vim: set ft=bash
set -euo pipefail

#-------------------------------------------------------------------------------
# Tests for tools/read-file
#
# The read-file tool reads project files with line-numbered, hash-annotated
# output. Each line hash incorporates the whole-file SHA-256 (guardian hash),
# line number, and line content, so all hashes self-invalidate when the file
# changes anywhere.
#
# Tests invoke the tool's main script directly with the required env vars,
# same as tool:invoke would set them. Conversation metadata tracking is
# tested via the conversation library's metadata functions.
#-------------------------------------------------------------------------------

setup() {
  SCRIPTDIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" > /dev/null 2>&1 && pwd)"
  SCRATCH_HOME="$(cd "${SCRIPTDIR}/.." && pwd)"
  source "${SCRIPTDIR}/helpers.sh"
  source "${SCRATCH_HOME}/lib/conversations.sh"
  source "${SCRATCH_HOME}/lib/project.sh"

  export SCRATCH_HOME

  # Isolated config
  export SCRATCH_CONFIG_DIR="${BATS_TEST_TMPDIR}/config"
  export SCRATCH_PROJECTS_DIR="${SCRATCH_CONFIG_DIR}/projects"
  mkdir -p "$SCRATCH_PROJECTS_DIR"

  # Test project with a real directory. Canonicalize the path so tests
  # match the output (macOS resolves /tmp -> /private/tmp).
  TEST_PROJECT_ROOT="${BATS_TEST_TMPDIR}/project"
  mkdir -p "$TEST_PROJECT_ROOT/lib"
  TEST_PROJECT_ROOT="$(perl -MCwd -e 'print Cwd::realpath($ARGV[0])' "$TEST_PROJECT_ROOT")"
  export SCRATCH_PROJECT="testproj"
  export SCRATCH_PROJECT_ROOT="$TEST_PROJECT_ROOT"
  project:save "testproj" "$TEST_PROJECT_ROOT" "false"

  # Create a conversation for metadata tracking
  TEST_SLUG="$(conversation:create "testproj")"
  export SCRATCH_CONVERSATION_SLUG="$TEST_SLUG"

  # Tool env contract
  export SCRATCH_TOOL_DIR="${SCRATCH_HOME}/tools/read-file"
  export SCRATCH_TOOL_ARGS_JSON='{}'

  # Create a fixture file
  cat > "${TEST_PROJECT_ROOT}/fixture.sh" << 'FIXTURE'
#!/usr/bin/env bash
set -euo pipefail

greet() {
  local name="$1"
  echo "hello, ${name}"
}

greet "world"
FIXTURE
}

# Invoke the read-file tool with the given args JSON.
# Merges stderr into stdout so error messages are in $output.
_run_read_file() {
  local args_json="$1"
  SCRATCH_TOOL_ARGS_JSON="$args_json" \
    run bash -c '"$SCRATCH_TOOL_DIR/main" 2>&1'
}

# ---------------------------------------------------------------------------
# Basic reads
# ---------------------------------------------------------------------------

@test "full file read: header, line numbers, hashes, content" {
  _run_read_file '{"path": "'"${TEST_PROJECT_ROOT}/fixture.sh"'"}'

  is "$status" 0
  [[ "$output" == *"[file: ${TEST_PROJECT_ROOT}/fixture.sh"* ]]
  [[ "$output" == *"lines: 1-9 of 9"* ]]
  [[ "$output" == *"hash: "* ]]
  # Line 1 should have the shebang
  [[ "$output" == *"1  "* ]]
  [[ "$output" == *"#!/usr/bin/env bash"* ]]
  # Line 10 should have the last line
  [[ "$output" == *"greet \"world\""* ]]
}

@test "chunk read: offset and limit" {
  _run_read_file '{"path": "'"${TEST_PROJECT_ROOT}/fixture.sh"'", "offset": 4, "limit": 3}'

  is "$status" 0
  [[ "$output" == *"lines: 4-6 of 9"* ]]
  [[ "$output" == *"greet()"* ]]
  # Should not contain lines outside the range
  [[ "$output" != *"#!/usr/bin/env bash"* ]]
  [[ "$output" != *"greet \"world\""* ]]
}

@test "offset past end of file" {
  _run_read_file '{"path": "'"${TEST_PROJECT_ROOT}/fixture.sh"'", "offset": 100}'

  is "$status" 0
  [[ "$output" == *"offset 100 is past end of file (9 lines)"* ]]
}

@test "limit exceeding remaining lines reads to end" {
  _run_read_file '{"path": "'"${TEST_PROJECT_ROOT}/fixture.sh"'", "offset": 8, "limit": 100}'

  is "$status" 0
  [[ "$output" == *"lines: 8-9 of 9"* ]]
}

# ---------------------------------------------------------------------------
# Line hash properties
# ---------------------------------------------------------------------------

@test "line hash stability: same file produces identical hashes" {
  _run_read_file '{"path": "'"${TEST_PROJECT_ROOT}/fixture.sh"'"}'
  local first_output="$output"

  _run_read_file '{"path": "'"${TEST_PROJECT_ROOT}/fixture.sh"'"}'

  is "$output" "$first_output"
}

@test "line hashes change on file mutation" {
  _run_read_file '{"path": "'"${TEST_PROJECT_ROOT}/fixture.sh"'"}'
  local first_output="$output"

  # Mutate the file (append a line)
  echo "# added" >> "${TEST_PROJECT_ROOT}/fixture.sh"

  _run_read_file '{"path": "'"${TEST_PROJECT_ROOT}/fixture.sh"'"}'

  # The header hash should differ
  local first_hash second_hash
  first_hash="$(grep '^\[file:' <<< "$first_output" | grep -o 'hash: [a-f0-9]*' | cut -d' ' -f2)"
  second_hash="$(grep '^\[file:' <<< "$output" | grep -o 'hash: [a-f0-9]*' | cut -d' ' -f2)"

  [[ "$first_hash" != "$second_hash" ]]

  # Line 1 hash should also differ (guardian hash is baked in)
  local first_line1 second_line1
  first_line1="$(grep '#!/usr/bin/env bash' <<< "$first_output" | awk '{print $2}')"
  second_line1="$(grep '#!/usr/bin/env bash' <<< "$output" | awk '{print $2}')"

  [[ "$first_line1" != "$second_line1" ]]
}

@test "blank lines at different positions have different hashes" {
  # Create a file with blank lines at positions 2 and 4
  printf 'a\n\nb\n\nc\n' > "${TEST_PROJECT_ROOT}/blanks.txt"

  _run_read_file '{"path": "'"${TEST_PROJECT_ROOT}/blanks.txt"'"}'
  is "$status" 0

  # Extract hashes for lines 2 and 4 (the blank lines)
  local hash_line2 hash_line4
  hash_line2="$(grep -E '^\s+2\s+' <<< "$output" | awk '{print $2}')"
  hash_line4="$(grep -E '^\s+4\s+' <<< "$output" | awk '{print $2}')"

  [[ -n "$hash_line2" ]]
  [[ -n "$hash_line4" ]]
  [[ "$hash_line2" != "$hash_line4" ]]
}

# ---------------------------------------------------------------------------
# Guardian hash in conversation metadata
# ---------------------------------------------------------------------------

@test "guardian hash stored in conversation metadata" {
  _run_read_file '{"path": "'"${TEST_PROJECT_ROOT}/fixture.sh"'"}'
  is "$status" 0

  local meta
  meta="$(conversation:load-metadata "testproj" "$TEST_SLUG")"

  local stored_hash
  stored_hash="$(jq -r ".file_reads[\"${TEST_PROJECT_ROOT}/fixture.sh\"].hash" <<< "$meta")"

  [[ -n "$stored_hash" ]]
  [[ "$stored_hash" != "null" ]]

  # Should match the hash in the output header
  local output_hash
  output_hash="$(grep '^\[file:' <<< "$output" | grep -o 'hash: [a-f0-9]*' | cut -d' ' -f2)"
  is "$stored_hash" "$output_hash"
}

@test "file changed note on re-read after mutation" {
  _run_read_file '{"path": "'"${TEST_PROJECT_ROOT}/fixture.sh"'"}'
  is "$status" 0
  # No change note on first read
  [[ "$output" != *"file changed since previous read"* ]]

  # Mutate
  echo "# changed" >> "${TEST_PROJECT_ROOT}/fixture.sh"

  _run_read_file '{"path": "'"${TEST_PROJECT_ROOT}/fixture.sh"'"}'
  is "$status" 0
  [[ "$output" == *"file changed since previous read"* ]]
}

@test "no changed note on first read" {
  _run_read_file '{"path": "'"${TEST_PROJECT_ROOT}/fixture.sh"'"}'
  is "$status" 0
  [[ "$output" != *"file changed since previous read"* ]]
}

# ---------------------------------------------------------------------------
# Path resolution and security
# ---------------------------------------------------------------------------

@test "project file allowed" {
  _run_read_file '{"path": "'"${TEST_PROJECT_ROOT}/fixture.sh"'"}'
  is "$status" 0
}

@test "file outside project denied" {
  local outside="${BATS_TEST_TMPDIR}/outside.txt"
  echo "secret" > "$outside"

  _run_read_file '{"path": "'"$outside"'"}'
  is "$status" 1
  [[ "$output" == *"access denied"* ]]
}

@test "symlink escape denied" {
  local outside="${BATS_TEST_TMPDIR}/outside_secret.txt"
  echo "secret" > "$outside"
  ln -s "$outside" "${TEST_PROJECT_ROOT}/sneaky_link"

  _run_read_file '{"path": "'"${TEST_PROJECT_ROOT}/sneaky_link"'"}'
  is "$status" 1
  [[ "$output" == *"access denied"* ]]
}

@test "relative path resolves against project root" {
  _run_read_file '{"path": "fixture.sh"}'
  is "$status" 0
  [[ "$output" == *"[file: ${TEST_PROJECT_ROOT}/fixture.sh"* ]]
}

# ---------------------------------------------------------------------------
# Error handling
# ---------------------------------------------------------------------------

@test "binary file rejected" {
  printf '\x00\x01\x02binary\x00' > "${TEST_PROJECT_ROOT}/data.bin"

  _run_read_file '{"path": "'"${TEST_PROJECT_ROOT}/data.bin"'"}'
  is "$status" 1
  [[ "$output" == *"binary file detected"* ]]
}

@test "large file rejected" {
  # Use a small cap for testing
  export SCRATCH_READ_FILE_MAX_SIZE=100
  # Create a file larger than 100 bytes
  printf '%0200d\n' 0 > "${TEST_PROJECT_ROOT}/big.txt"

  _run_read_file '{"path": "'"${TEST_PROJECT_ROOT}/big.txt"'"}'
  is "$status" 1
  [[ "$output" == *"file too large"* ]]
}

@test "missing file produces clear error" {
  _run_read_file '{"path": "'"${TEST_PROJECT_ROOT}/nonexistent.sh"'"}'
  is "$status" 1
  [[ "$output" == *"not found"* ]]
}

@test "missing path argument fails" {
  _run_read_file '{}'
  is "$status" 1
  [[ "$output" == *"path is required"* ]]
}

# ---------------------------------------------------------------------------
# Graceful degradation
# ---------------------------------------------------------------------------

@test "works without conversation slug (no metadata update)" {
  unset SCRATCH_CONVERSATION_SLUG

  _run_read_file '{"path": "'"${TEST_PROJECT_ROOT}/fixture.sh"'"}'
  is "$status" 0
  [[ "$output" == *"fixture.sh"* ]]
}
