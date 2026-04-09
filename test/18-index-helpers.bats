#!/usr/bin/env bats

# vim: set ft=bash
set -euo pipefail

#-------------------------------------------------------------------------------
# Tests for helpers/index/{produce,consume}
#
# Uses a fake project fixture (test/fixtures/fake-project/) copied into
# BATS_TEST_TMPDIR with a registered project config. Each test gets an
# isolated project, database, and file tree.
#
# The summarize stage is not tested here (it needs the Venice API).
# See test/integration/04-index.bats for end-to-end pipeline tests.
#-------------------------------------------------------------------------------

setup() {
  SCRIPTDIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" > /dev/null 2>&1 && pwd)"
  SCRATCH_HOME="$(cd "${SCRIPTDIR}/.." && pwd)"
  source "${SCRIPTDIR}/helpers.sh"
  source "${SCRATCH_HOME}/lib/index.sh"
  source "${SCRATCH_HOME}/lib/db.sh"

  export HOME="${BATS_TEST_TMPDIR}/home"
  mkdir -p "$HOME"

  export SCRATCH_HOME
  # Both the test body AND the helper scripts need this override.
  # The helpers source lib/project.sh which reads SCRATCH_PROJECTS_DIR.
  export SCRATCH_PROJECTS_DIR="${BATS_TEST_TMPDIR}/projects"

  # Copy fixture into a temp project directory
  PROJECT_ROOT="${BATS_TEST_TMPDIR}/myproject"
  cp -R "${SCRIPTDIR}/fixtures/fake-project" "$PROJECT_ROOT"

  # Register the project
  mkdir -p "${SCRATCH_PROJECTS_DIR}/myproject"
  printf '{"root":"%s","is_git":false,"exclude":[]}\n' "$PROJECT_ROOT" \
    > "${SCRATCH_PROJECTS_DIR}/myproject/settings.json"

  index:ensure myproject

  PRODUCE="${SCRATCH_HOME}/helpers/index/produce"
  CONSUME="${SCRATCH_HOME}/helpers/index/consume"
}

# ---------------------------------------------------------------------------
# helpers/index/produce
# ---------------------------------------------------------------------------

@test "produce emits JSONL for all files in a non-git project" {
  local out
  out="$("$PRODUCE" myproject "$PROJECT_ROOT" false "" 2> /dev/null)"

  # Should have 3 files (greet.pl, stats.awk, lib/utils.sh)
  local count
  count="$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
  is "$count" "3"

  # Each line is valid JSON with required fields
  local line
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    printf '%s' "$line" | jq -e '.id and .sha and .file' > /dev/null
  done <<< "$out"
}

@test "produce JSONL id field is a relative path" {
  local out
  out="$("$PRODUCE" myproject "$PROJECT_ROOT" false "" 2> /dev/null)"

  local ids
  ids="$(printf '%s\n' "$out" | jq -r '.id')"
  while IFS= read -r id; do
    [[ "$id" != /* ]] || {
      echo "expected relative path, got: $id"
      return 1
    }
  done <<< "$ids"
}

@test "produce JSONL file field is an absolute path" {
  local out
  out="$("$PRODUCE" myproject "$PROJECT_ROOT" false "" 2> /dev/null)"

  local files
  files="$(printf '%s\n' "$out" | jq -r '.file')"
  while IFS= read -r f; do
    [[ "$f" == /* ]] || {
      echo "expected absolute path, got: $f"
      return 1
    }
  done <<< "$files"
}

@test "produce skips files already indexed with matching SHA" {
  local sha
  sha="$(shasum -a 256 "${PROJECT_ROOT}/greet.pl" | cut -d' ' -f1)"
  index:record myproject file "greet.pl" "$sha" "a perl greeter"

  local out
  out="$("$PRODUCE" myproject "$PROJECT_ROOT" false "" 2> /dev/null)"

  # greet.pl should NOT appear (already indexed, SHA matches)
  local count
  count="$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
  is "$count" "2"

  [[ "$out" != *"greet.pl"* ]]
}

@test "produce emits changed files (SHA mismatch)" {
  index:record myproject file "greet.pl" "stale_sha" "old summary"

  local out
  out="$("$PRODUCE" myproject "$PROJECT_ROOT" false "" 2> /dev/null)"

  [[ "$out" == *"greet.pl"* ]]
}

@test "produce removes orphaned entries" {
  index:record myproject file "deleted.rb" "deadbeef" "gone"

  "$PRODUCE" myproject "$PROJECT_ROOT" false "" > /dev/null 2>&1

  run index:lookup myproject file "deleted.rb"
  is "$status" 1
}

@test "produce respects exclude patterns for non-git projects" {
  local out
  out="$("$PRODUCE" myproject "$PROJECT_ROOT" false "lib/**" 2> /dev/null)"

  [[ "$out" != *"lib/utils.sh"* ]]
  [[ "$out" == *"greet.pl"* ]]
  [[ "$out" == *"stats.awk"* ]]
}

@test "produce SHA is deterministic" {
  local out1 out2
  out1="$("$PRODUCE" myproject "$PROJECT_ROOT" false "" 2> /dev/null)"
  out2="$("$PRODUCE" myproject "$PROJECT_ROOT" false "" 2> /dev/null)"

  # Same files, same content → same SHAs
  local shas1 shas2
  shas1="$(echo "$out1" | jq -r '.sha' | sort)"
  shas2="$(echo "$out2" | jq -r '.sha' | sort)"
  is "$shas1" "$shas2"
}

# ---------------------------------------------------------------------------
# helpers/index/consume
# ---------------------------------------------------------------------------

@test "consume finalizes entries with SHA and embedding" {
  # Pre-seed an entry with a pending SHA
  index:update-summary myproject file "greet.pl" "a perl greeter"

  # Feed it an embedding result with SHA
  printf '{"id":"greet.pl","sha":"abc123","embedding":[1.0,2.0,3.0]}\n' \
    | "$CONSUME" myproject

  local db
  db="$(index:db-path myproject)"

  # Embedding stored
  run db:query "$db" "SELECT embedding FROM entries WHERE identifier = 'greet.pl';"
  is "$output" "[1.0,2.0,3.0]"

  # SHA updated from _pending_ to real value
  run db:query "$db" "SELECT content_sha FROM entries WHERE identifier = 'greet.pl';"
  is "$output" "abc123"
}

@test "consume handles multiple entries" {
  index:update-summary myproject file "a.pl" "file a"
  index:update-summary myproject file "b.awk" "file b"

  printf '{"id":"a.pl","sha":"aaa","embedding":[1.0]}\n{"id":"b.awk","sha":"bbb","embedding":[2.0]}\n' \
    | "$CONSUME" myproject

  local db
  db="$(index:db-path myproject)"

  run db:query "$db" "SELECT embedding FROM entries WHERE identifier = 'a.pl';"
  is "$output" "[1.0]"

  run db:query "$db" "SELECT embedding FROM entries WHERE identifier = 'b.awk';"
  is "$output" "[2.0]"
}

@test "consume skips entries with null embedding" {
  index:record myproject file "greet.pl" "abc" "summary"

  printf '{"id":"greet.pl","sha":"abc","embedding":null}\n' \
    | "$CONSUME" myproject

  local db
  db="$(index:db-path myproject)"
  run db:query "$db" "SELECT embedding FROM entries WHERE identifier = 'greet.pl';"
  # Should still be empty (NULL)
  is "$output" ""
}

@test "consume skips entries with missing embedding field" {
  index:record myproject file "greet.pl" "abc" "summary"

  printf '{"id":"greet.pl","error":"something went wrong"}\n' \
    | "$CONSUME" myproject

  local db
  db="$(index:db-path myproject)"
  run db:query "$db" "SELECT embedding FROM entries WHERE identifier = 'greet.pl';"
  is "$output" ""
}

@test "consume handles empty input" {
  run "$CONSUME" myproject < /dev/null
  is "$status" 0
}
