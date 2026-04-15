#!/usr/bin/env bats

# vim: set ft=bash
set -euo pipefail

#-------------------------------------------------------------------------------
# Tests for lib/attachments.sh (Phase 1 — substrate-recording primitives)
#
# Attachments share the project index.db, so these tests piggyback on the
# same test-harness pattern as 16-index.bats. Each test gets a fresh
# project config and DB under BATS_TEST_TMPDIR.
#-------------------------------------------------------------------------------

setup() {
  SCRIPTDIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" > /dev/null 2>&1 && pwd)"
  SCRATCH_HOME="$(cd "${SCRIPTDIR}/.." && pwd)"
  source "${SCRIPTDIR}/helpers.sh"
  source "${SCRATCH_HOME}/lib/attachments.sh"

  export HOME="${BATS_TEST_TMPDIR}/home"
  mkdir -p "$HOME"

  export SCRATCH_PROJECTS_DIR="${BATS_TEST_TMPDIR}/projects"
  mkdir -p "${SCRATCH_PROJECTS_DIR}/testproj"
  printf '{"root":"/tmp/fake","is_git":false,"exclude":[]}\n' \
    > "${SCRATCH_PROJECTS_DIR}/testproj/settings.json"

  PROJECT="testproj"
}

# ---------------------------------------------------------------------------
# attachments:db-path / attachments:ensure
# ---------------------------------------------------------------------------

@test "attachments:db-path is the same as index:db-path" {
  run attachments:db-path "$PROJECT"
  is "$status" 0
  is "$output" "${SCRATCH_PROJECTS_DIR}/testproj/index.db"
}

@test "attachments:ensure creates all expected tables" {
  attachments:ensure "$PROJECT"

  local db
  db="$(attachments:db-path "$PROJECT")"
  [[ -f "$db" ]]

  # All five attachments-model tables exist after the 002 migration
  local t
  for t in substrate_events associations attachments attachment_provenance attachment_fires; do
    run db:exists "$db" "SELECT 1 FROM sqlite_master WHERE type='table' AND name='${t}';"
    is "$status" 0
  done

  # The 002 migration is recorded
  run db:exists "$db" "SELECT 1 FROM migrations WHERE name='002-attachments.sql';"
  is "$status" 0
}

@test "attachments:ensure is idempotent" {
  attachments:ensure "$PROJECT"
  attachments:ensure "$PROJECT"

  local db
  db="$(attachments:db-path "$PROJECT")"
  run db:query "$db" "SELECT count(*) FROM migrations WHERE name='002-attachments.sql';"
  is "$output" "1"
}

# ---------------------------------------------------------------------------
# attachments:record-turn
# ---------------------------------------------------------------------------

@test "attachments:record-turn inserts a substrate row and prints its id" {
  run attachments:record-turn "$PROJECT" "abc123" "0" "user said hi; assistant said hi back"
  is "$status" 0
  # The id of the just-inserted row
  is "$output" "1"

  local db
  db="$(attachments:db-path "$PROJECT")"

  run db:query "$db" "SELECT kind, project, conversation_slug, round_index, situation FROM substrate_events WHERE id=1;"
  is "$output" $'turn\ttestproj\tabc123\t0\tuser said hi; assistant said hi back'
}

@test "attachments:record-turn stores NULL for empty round / outcome / affect" {
  attachments:record-turn "$PROJECT" "abc123" "" "situation text"

  local db
  db="$(attachments:db-path "$PROJECT")"

  # round_index, outcome, affect all NULL; situation_embedding also NULL
  run db:query "$db" "SELECT round_index IS NULL, outcome IS NULL, affect IS NULL, situation_embedding IS NULL FROM substrate_events WHERE id=1;"
  is "$output" $'1\t1\t1\t1'
}

@test "attachments:record-turn accepts optional outcome and affect" {
  attachments:record-turn "$PROJECT" "abc123" "3" "situation" "user said thanks" "curious"

  local db
  db="$(attachments:db-path "$PROJECT")"

  run db:query "$db" "SELECT round_index, outcome, affect FROM substrate_events WHERE id=1;"
  is "$output" $'3\tuser said thanks\tcurious'
}

@test "attachments:record-turn quotes situation text with embedded single quotes" {
  attachments:record-turn "$PROJECT" "abc123" "0" "it's a situation with 'quotes' inside"

  local db
  db="$(attachments:db-path "$PROJECT")"

  run db:query "$db" "SELECT situation FROM substrate_events WHERE id=1;"
  is "$output" "it's a situation with 'quotes' inside"
}

@test "attachments:record-turn treats non-integer round as NULL" {
  # Garbage round index should not corrupt the insert
  attachments:record-turn "$PROJECT" "abc123" "not-a-number" "situation"

  local db
  db="$(attachments:db-path "$PROJECT")"

  run db:query "$db" "SELECT round_index IS NULL FROM substrate_events WHERE id=1;"
  is "$output" "1"
}

@test "multiple record-turn calls accumulate rows in order" {
  attachments:record-turn "$PROJECT" "slug1" "0" "first"
  attachments:record-turn "$PROJECT" "slug1" "1" "second"
  attachments:record-turn "$PROJECT" "slug2" "0" "third"

  local db
  db="$(attachments:db-path "$PROJECT")"

  run db:query "$db" "SELECT count(*) FROM substrate_events;"
  is "$output" "3"

  run db:query "$db" "SELECT situation FROM substrate_events ORDER BY id;"
  is "$output" $'first\nsecond\nthird'
}

# ---------------------------------------------------------------------------
# Substrate survives entries deletion — a core design guarantee
# ---------------------------------------------------------------------------

@test "substrate rows survive a full wipe of entries" {
  attachments:ensure "$PROJECT"

  local db
  db="$(attachments:db-path "$PROJECT")"

  # Seed substrate
  attachments:record-turn "$PROJECT" "abc123" "0" "a recorded moment"
  attachments:record-turn "$PROJECT" "abc123" "1" "another moment"

  # Seed an entry (simulating a user-visible indexed item)
  db:exec "$db" "INSERT INTO entries (type, identifier, content_sha, summary)
                 VALUES ('file', 'src/foo.txt', 'abc', 'a file');"

  # Nuke all entries — this is what a user-driven deletion looks like
  db:exec "$db" "DELETE FROM entries;"

  # Substrate must be untouched
  run db:query "$db" "SELECT count(*) FROM substrate_events;"
  is "$output" "2"
}

# ---------------------------------------------------------------------------
# attachments:decay — Phase 1 stub
# ---------------------------------------------------------------------------

@test "attachments:decay is a no-op in Phase 1" {
  attachments:ensure "$PROJECT"
  run attachments:decay "$PROJECT"
  is "$status" 0
  is "$output" ""
}
