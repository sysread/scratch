#!/usr/bin/env bats

# vim: set ft=bash
set -euo pipefail

#-------------------------------------------------------------------------------
# Tests for lib/index.sh
#
# Each test gets a fresh project config and database under BATS_TEST_TMPDIR.
# SCRATCH_PROJECTS_DIR is overridden so project:config-dir resolves to the
# test tmpdir, giving each test an isolated index database.
#-------------------------------------------------------------------------------

setup() {
  SCRIPTDIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" > /dev/null 2>&1 && pwd)"
  SCRATCH_HOME="$(cd "${SCRIPTDIR}/.." && pwd)"
  source "${SCRIPTDIR}/helpers.sh"
  source "${SCRATCH_HOME}/lib/index.sh"

  export HOME="${BATS_TEST_TMPDIR}/home"
  mkdir -p "$HOME"

  # Override project config dir so index:db-path resolves under tmpdir
  export SCRATCH_PROJECTS_DIR="${BATS_TEST_TMPDIR}/projects"
  mkdir -p "${SCRATCH_PROJECTS_DIR}/testproj"

  # Create a minimal project config so project:config-dir works
  printf '{"root":"/tmp/fake","is_git":false,"exclude":[]}\n' \
    > "${SCRATCH_PROJECTS_DIR}/testproj/settings.json"

  PROJECT="testproj"
}

# ---------------------------------------------------------------------------
# index:db-path
# ---------------------------------------------------------------------------

@test "index:db-path returns expected path" {
  run index:db-path "$PROJECT"
  is "$status" 0
  is "$output" "${SCRATCH_PROJECTS_DIR}/testproj/index.db"
}

# ---------------------------------------------------------------------------
# index:ensure
# ---------------------------------------------------------------------------

@test "index:ensure creates database with schema" {
  index:ensure "$PROJECT"

  local db
  db="$(index:db-path "$PROJECT")"
  [[ -f "$db" ]]

  # entries table exists
  run db:exists "$db" "SELECT 1 FROM sqlite_master WHERE type='table' AND name='entries';"
  is "$status" 0

  # metadata table exists
  run db:exists "$db" "SELECT 1 FROM sqlite_master WHERE type='table' AND name='metadata';"
  is "$status" 0

  # migrations recorded
  run db:exists "$db" "SELECT 1 FROM migrations WHERE name='001-initial-schema.sql';"
  is "$status" 0
}

@test "index:ensure is idempotent" {
  index:ensure "$PROJECT"
  index:ensure "$PROJECT"

  local db
  db="$(index:db-path "$PROJECT")"
  # Idempotency: each migration is recorded exactly once, no duplicates.
  run db:query "$db" "SELECT name, count(*) FROM migrations GROUP BY name HAVING count(*) > 1;"
  is "$output" ""
}

# ---------------------------------------------------------------------------
# index:record
# ---------------------------------------------------------------------------

@test "index:record inserts a new entry" {
  index:ensure "$PROJECT"
  index:record "$PROJECT" file "lib/foo.sh" "abc123" "A foo library"

  local db
  db="$(index:db-path "$PROJECT")"
  run db:query "$db" "SELECT type, identifier, content_sha, summary FROM entries;"
  is "$status" 0
  is "$output" "file	lib/foo.sh	abc123	A foo library"
}

@test "index:record with embedding stores it" {
  index:ensure "$PROJECT"
  index:record "$PROJECT" file "lib/foo.sh" "abc123" "A foo library" "[1.0,2.0,3.0]"

  local db
  db="$(index:db-path "$PROJECT")"
  run db:query "$db" "SELECT embedding FROM entries;"
  is "$output" "[1.0,2.0,3.0]"
}

@test "index:record without embedding stores NULL" {
  index:ensure "$PROJECT"
  index:record "$PROJECT" file "lib/foo.sh" "abc123" "A foo library"

  local db
  db="$(index:db-path "$PROJECT")"
  run db:query "$db" "SELECT embedding FROM entries;"
  # NULL renders as empty string in sqlite3 default output
  is "$output" ""
}

@test "index:record upserts on duplicate (type, identifier)" {
  index:ensure "$PROJECT"
  index:record "$PROJECT" file "lib/foo.sh" "abc123" "version one"
  index:record "$PROJECT" file "lib/foo.sh" "def456" "version two" "[1.0]"

  local db
  db="$(index:db-path "$PROJECT")"

  # Only one row
  run db:query "$db" "SELECT count(*) FROM entries;"
  is "$output" "1"

  # Updated values
  run db:query "$db" "SELECT content_sha, summary, embedding FROM entries;"
  is "$output" "def456	version two	[1.0]"
}

@test "index:record handles special characters in summary" {
  index:ensure "$PROJECT"
  local tricky="it's got \"quotes\" and
newlines & pipes | too"
  index:record "$PROJECT" file "lib/foo.sh" "abc" "$tricky"

  local result
  result="$(index:lookup "$PROJECT" file "lib/foo.sh")"
  local summary
  summary="$(printf '%s' "$result" | jq -r '.summary')"
  is "$summary" "$tricky"
}

# ---------------------------------------------------------------------------
# index:lookup
# ---------------------------------------------------------------------------

@test "index:lookup returns JSON for existing entry" {
  index:ensure "$PROJECT"
  index:record "$PROJECT" file "lib/foo.sh" "abc123" "A foo library" "[1.0]"

  run index:lookup "$PROJECT" file "lib/foo.sh"
  is "$status" 0

  # Validate JSON structure
  local id type identifier
  id="$(printf '%s' "$output" | jq '.id')"
  type="$(printf '%s' "$output" | jq -r '.type')"
  identifier="$(printf '%s' "$output" | jq -r '.identifier')"
  [[ "$id" =~ ^[0-9]+$ ]]
  is "$type" "file"
  is "$identifier" "lib/foo.sh"
}

@test "index:lookup returns 1 for missing entry" {
  index:ensure "$PROJECT"
  run index:lookup "$PROJECT" file "no/such/file.sh"
  is "$status" 1
}

# ---------------------------------------------------------------------------
# index:remove
# ---------------------------------------------------------------------------

@test "index:remove deletes an entry" {
  index:ensure "$PROJECT"
  index:record "$PROJECT" file "lib/foo.sh" "abc" "summary"

  index:remove "$PROJECT" file "lib/foo.sh"

  run index:lookup "$PROJECT" file "lib/foo.sh"
  is "$status" 1
}

@test "index:remove returns 0 for nonexistent entry" {
  index:ensure "$PROJECT"
  run index:remove "$PROJECT" file "no/such/file.sh"
  is "$status" 0
}

# ---------------------------------------------------------------------------
# index:remove-type
# ---------------------------------------------------------------------------

@test "index:remove-type deletes all entries of a type" {
  index:ensure "$PROJECT"
  index:record "$PROJECT" file "a.sh" "aaa" "file a"
  index:record "$PROJECT" file "b.sh" "bbb" "file b"
  index:record "$PROJECT" commit "abc123" "ccc" "commit summary"

  index:remove-type "$PROJECT" file

  # Files gone
  run index:lookup "$PROJECT" file "a.sh"
  is "$status" 1

  # Commit still there
  run index:lookup "$PROJECT" commit "abc123"
  is "$status" 0
}

# ---------------------------------------------------------------------------
# index:list
# ---------------------------------------------------------------------------

@test "index:list returns tab-delimited identifier and sha" {
  index:ensure "$PROJECT"
  index:record "$PROJECT" file "a.sh" "aaa" "file a"
  index:record "$PROJECT" file "b.sh" "bbb" "file b"

  run index:list "$PROJECT" file
  is "$status" 0
  is "$output" "a.sh	aaa
b.sh	bbb"
}

@test "index:list returns empty for no entries" {
  index:ensure "$PROJECT"
  run index:list "$PROJECT" file
  is "$status" 0
  is "$output" ""
}

@test "index:list filters by type" {
  index:ensure "$PROJECT"
  index:record "$PROJECT" file "a.sh" "aaa" "file"
  index:record "$PROJECT" commit "abc" "ccc" "commit"

  run index:list "$PROJECT" file
  is "$output" "a.sh	aaa"

  run index:list "$PROJECT" commit
  is "$output" "abc	ccc"
}

# ---------------------------------------------------------------------------
# index:set-meta / index:get-meta
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# index:update-summary / index:finalize
# ---------------------------------------------------------------------------

@test "index:update-summary upserts summary without changing SHA or embedding" {
  index:ensure "$PROJECT"
  index:record "$PROJECT" file "a.sh" "original_sha" "old summary" "[1.0]"

  index:update-summary "$PROJECT" file "a.sh" "new summary"

  local db
  db="$(index:db-path "$PROJECT")"

  # Summary updated
  run db:query "$db" "SELECT summary FROM entries WHERE identifier = 'a.sh';"
  is "$output" "new summary"

  # SHA preserved
  run db:query "$db" "SELECT content_sha FROM entries WHERE identifier = 'a.sh';"
  is "$output" "original_sha"

  # Embedding preserved
  run db:query "$db" "SELECT embedding FROM entries WHERE identifier = 'a.sh';"
  is "$output" "[1.0]"
}

@test "index:update-summary creates entry with placeholder SHA if new" {
  index:ensure "$PROJECT"
  index:update-summary "$PROJECT" file "new.sh" "a summary"

  local db
  db="$(index:db-path "$PROJECT")"

  run db:query "$db" "SELECT content_sha FROM entries WHERE identifier = 'new.sh';"
  is "$output" "_pending_"
}

@test "index:finalize writes SHA and embedding together" {
  index:ensure "$PROJECT"
  index:update-summary "$PROJECT" file "a.sh" "summary text"

  index:finalize "$PROJECT" file "a.sh" "real_sha_256" "[1.0,2.0,3.0]"

  local db
  db="$(index:db-path "$PROJECT")"

  run db:query "$db" "SELECT content_sha FROM entries WHERE identifier = 'a.sh';"
  is "$output" "real_sha_256"

  run db:query "$db" "SELECT embedding FROM entries WHERE identifier = 'a.sh';"
  is "$output" "[1.0,2.0,3.0]"
}

# ---------------------------------------------------------------------------
# index:set-meta / index:get-meta
# ---------------------------------------------------------------------------

@test "index:set-meta and index:get-meta round-trip" {
  index:ensure "$PROJECT"
  index:set-meta "$PROJECT" "last_indexed_at" "2026-04-09T12:00:00"

  run index:get-meta "$PROJECT" "last_indexed_at"
  is "$status" 0
  is "$output" "2026-04-09T12:00:00"
}

@test "index:set-meta upserts on duplicate key" {
  index:ensure "$PROJECT"
  index:set-meta "$PROJECT" "key" "value1"
  index:set-meta "$PROJECT" "key" "value2"

  run index:get-meta "$PROJECT" "key"
  is "$output" "value2"
}

@test "index:get-meta returns 1 for missing key" {
  index:ensure "$PROJECT"
  run index:get-meta "$PROJECT" "nonexistent"
  is "$status" 1
}
