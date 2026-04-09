#!/usr/bin/env bats

# vim: set ft=bash
set -euo pipefail

#-------------------------------------------------------------------------------
# Tests for lib/db.sh
#
# Each test gets a fresh SQLite database under BATS_TEST_TMPDIR so there
# is no cross-test contamination.
#-------------------------------------------------------------------------------

setup() {
  SCRIPTDIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" > /dev/null 2>&1 && pwd)"
  SCRATCH_HOME="$(cd "${SCRIPTDIR}/.." && pwd)"
  source "${SCRIPTDIR}/helpers.sh"
  source "${SCRATCH_HOME}/lib/db.sh"

  export HOME="${BATS_TEST_TMPDIR}/home"
  mkdir -p "$HOME"

  TEST_DB="${BATS_TEST_TMPDIR}/test.db"
}

# ---------------------------------------------------------------------------
# db:quote
# ---------------------------------------------------------------------------

@test "db:quote wraps value in single quotes" {
  run db:quote "hello"
  is "$status" 0
  is "$output" "'hello'"
}

@test "db:quote doubles embedded single quotes" {
  run db:quote "it's a test"
  is "$status" 0
  is "$output" "'it''s a test'"
}

@test "db:quote handles empty string" {
  run db:quote ""
  is "$status" 0
  is "$output" "''"
}

@test "db:quote preserves newlines" {
  run db:quote "line one
line two"
  is "$status" 0
  is "$output" "'line one
line two'"
}

# ---------------------------------------------------------------------------
# db:exec
# ---------------------------------------------------------------------------

@test "db:exec creates a table" {
  db:exec "$TEST_DB" "CREATE TABLE t(a TEXT);"
  # Verify the table exists by inserting a row
  db:exec "$TEST_DB" "INSERT INTO t VALUES('hello');"
}

@test "db:exec dies on bad SQL" {
  run db:exec "$TEST_DB" "NOT VALID SQL;"
  is "$status" 1
  [[ "$output" == *"db:exec:"* ]]
}

@test "db:exec handles multiple statements" {
  db:exec "$TEST_DB" "
    CREATE TABLE t(a TEXT, b TEXT);
    INSERT INTO t VALUES('x', 'y');
    INSERT INTO t VALUES('m', 'n');
  "
  run db:query "$TEST_DB" "SELECT count(*) FROM t;"
  is "$output" "2"
}

# ---------------------------------------------------------------------------
# db:query
# ---------------------------------------------------------------------------

@test "db:query returns tab-delimited rows" {
  db:exec "$TEST_DB" "
    CREATE TABLE t(a TEXT, b TEXT);
    INSERT INTO t VALUES('hello', 'world');
  "
  run db:query "$TEST_DB" "SELECT a, b FROM t;"
  is "$status" 0
  is "$output" "hello	world"
}

@test "db:query returns multiple rows" {
  db:exec "$TEST_DB" "
    CREATE TABLE t(n INTEGER);
    INSERT INTO t VALUES(1);
    INSERT INTO t VALUES(2);
    INSERT INTO t VALUES(3);
  "
  run db:query "$TEST_DB" "SELECT n FROM t ORDER BY n;"
  is "$status" 0
  is "$output" "1
2
3"
}

@test "db:query returns empty output for no rows" {
  db:exec "$TEST_DB" "CREATE TABLE t(a TEXT);"
  run db:query "$TEST_DB" "SELECT * FROM t;"
  is "$status" 0
  is "$output" ""
}

@test "db:query dies on bad SQL" {
  run db:query "$TEST_DB" "SELECT * FROM nonexistent;"
  is "$status" 1
  [[ "$output" == *"db:query:"* ]]
}

# ---------------------------------------------------------------------------
# db:query-json
# ---------------------------------------------------------------------------

@test "db:query-json returns JSON array of objects" {
  db:exec "$TEST_DB" "
    CREATE TABLE t(name TEXT, age INTEGER);
    INSERT INTO t VALUES('alice', 30);
    INSERT INTO t VALUES('bob', 25);
  "
  run db:query-json "$TEST_DB" "SELECT name, age FROM t ORDER BY name;"
  is "$status" 0
  # Validate it's valid JSON with expected structure
  local count
  count="$(echo "$output" | jq 'length')"
  is "$count" "2"
  local first_name
  first_name="$(echo "$output" | jq -r '.[0].name')"
  is "$first_name" "alice"
}

@test "db:query-json returns [] for empty result set" {
  db:exec "$TEST_DB" "CREATE TABLE t(a TEXT);"
  run db:query-json "$TEST_DB" "SELECT * FROM t;"
  is "$status" 0
  is "$output" "[]"
}

@test "db:query-json dies on bad SQL" {
  run db:query-json "$TEST_DB" "SELECT * FROM nonexistent;"
  is "$status" 1
  [[ "$output" == *"db:query-json:"* ]]
}

# ---------------------------------------------------------------------------
# db:exists
# ---------------------------------------------------------------------------

@test "db:exists returns 0 when rows exist" {
  db:exec "$TEST_DB" "
    CREATE TABLE t(a TEXT);
    INSERT INTO t VALUES('x');
  "
  run db:exists "$TEST_DB" "SELECT 1 FROM t;"
  is "$status" 0
}

@test "db:exists returns 1 when no rows" {
  db:exec "$TEST_DB" "CREATE TABLE t(a TEXT);"
  run db:exists "$TEST_DB" "SELECT 1 FROM t;"
  is "$status" 1
}

@test "db:exists dies on bad SQL" {
  run db:exists "$TEST_DB" "SELECT 1 FROM nonexistent;"
  is "$status" 1
  [[ "$output" == *"db:exists:"* ]]
}

# ---------------------------------------------------------------------------
# db:init
# ---------------------------------------------------------------------------

@test "db:init creates database file and parent directory" {
  local nested="${BATS_TEST_TMPDIR}/a/b/c/test.db"
  db:init "$nested"
  [[ -f "$nested" ]]
}

@test "db:init sets WAL journal mode" {
  db:init "$TEST_DB"
  run db:query "$TEST_DB" "PRAGMA journal_mode;"
  is "$output" "wal"
}

@test "db:init enables foreign keys" {
  db:init "$TEST_DB"
  run db:query "$TEST_DB" "PRAGMA foreign_keys;"
  is "$output" "1"
}

@test "db:init is idempotent" {
  db:init "$TEST_DB"
  db:init "$TEST_DB"
  run db:query "$TEST_DB" "PRAGMA journal_mode;"
  is "$output" "wal"
}

# ---------------------------------------------------------------------------
# db:migrate
# ---------------------------------------------------------------------------

@test "db:migrate applies migrations in filename order" {
  local mdir="${BATS_TEST_TMPDIR}/migrations"
  mkdir -p "$mdir"

  printf 'CREATE TABLE alpha(id INTEGER PRIMARY KEY);\n' > "$mdir/001-alpha.sql"
  printf 'CREATE TABLE beta(id INTEGER PRIMARY KEY);\n' > "$mdir/002-beta.sql"

  db:init "$TEST_DB"
  db:migrate "$TEST_DB" "$mdir"

  # Both tables should exist (check sqlite_master, not row content)
  run db:exists "$TEST_DB" "SELECT 1 FROM sqlite_master WHERE type='table' AND name='alpha';"
  is "$status" 0
  run db:exists "$TEST_DB" "SELECT 1 FROM sqlite_master WHERE type='table' AND name='beta';"
  is "$status" 0

  # Both migrations should be recorded
  run db:query "$TEST_DB" "SELECT name FROM migrations ORDER BY name;"
  is "$output" "001-alpha.sql
002-beta.sql"
}

@test "db:migrate skips already-applied migrations" {
  local mdir="${BATS_TEST_TMPDIR}/migrations"
  mkdir -p "$mdir"

  printf 'CREATE TABLE alpha(id INTEGER PRIMARY KEY);\n' > "$mdir/001-alpha.sql"

  db:init "$TEST_DB"
  db:migrate "$TEST_DB" "$mdir"

  # Add a second migration and re-run
  printf 'CREATE TABLE beta(id INTEGER PRIMARY KEY);\n' > "$mdir/002-beta.sql"
  db:migrate "$TEST_DB" "$mdir"

  # Only two migrations recorded, alpha not applied twice
  run db:query "$TEST_DB" "SELECT count(*) FROM migrations;"
  is "$output" "2"
}

@test "db:migrate is idempotent" {
  local mdir="${BATS_TEST_TMPDIR}/migrations"
  mkdir -p "$mdir"

  printf 'CREATE TABLE alpha(id INTEGER PRIMARY KEY);\n' > "$mdir/001-alpha.sql"

  db:init "$TEST_DB"
  db:migrate "$TEST_DB" "$mdir"
  db:migrate "$TEST_DB" "$mdir"

  run db:query "$TEST_DB" "SELECT count(*) FROM migrations;"
  is "$output" "1"
}

@test "db:migrate dies on missing migrations directory" {
  db:init "$TEST_DB"
  run db:migrate "$TEST_DB" "${BATS_TEST_TMPDIR}/no-such-dir"
  is "$status" 1
  [[ "$output" == *"migrations directory not found"* ]]
}

@test "db:migrate dies on bad SQL in a migration" {
  local mdir="${BATS_TEST_TMPDIR}/migrations"
  mkdir -p "$mdir"

  printf 'THIS IS NOT SQL;\n' > "$mdir/001-bad.sql"

  db:init "$TEST_DB"
  run db:migrate "$TEST_DB" "$mdir"
  is "$status" 1

  # Failed migration should NOT be recorded
  run db:query "$TEST_DB" "SELECT count(*) FROM migrations;"
  is "$output" "0"
}

@test "db:migrate handles empty migrations directory" {
  local mdir="${BATS_TEST_TMPDIR}/migrations"
  mkdir -p "$mdir"

  db:init "$TEST_DB"
  run db:migrate "$TEST_DB" "$mdir"
  is "$status" 0
}

# ---------------------------------------------------------------------------
# db:quote round-trip through db:exec
# ---------------------------------------------------------------------------

@test "db:quote safely inserts values with special characters" {
  db:exec "$TEST_DB" "CREATE TABLE t(val TEXT);"

  local tricky="it's a \"test\" with
newlines & pipes | and backslashes \\"
  local q_val
  q_val="$(db:quote "$tricky")"
  db:exec "$TEST_DB" "INSERT INTO t VALUES($q_val);"

  run db:query "$TEST_DB" "SELECT val FROM t;"
  is "$status" 0
  is "$output" "$tricky"
}

# ---------------------------------------------------------------------------
# Integration: db:init + db:migrate with the real index migration
# ---------------------------------------------------------------------------

@test "initial index migration creates entries and metadata tables" {
  db:init "$TEST_DB"
  db:migrate "$TEST_DB" "${SCRATCH_HOME}/data/migrations/index"

  # entries table exists
  run db:exists "$TEST_DB" "SELECT 1 FROM sqlite_master WHERE type='table' AND name='entries';"
  is "$status" 0

  # metadata table exists
  run db:exists "$TEST_DB" "SELECT 1 FROM sqlite_master WHERE type='table' AND name='metadata';"
  is "$status" 0

  # unique constraint on (type, identifier) works
  db:exec "$TEST_DB" "INSERT INTO entries (type, identifier, content_sha, summary) VALUES ('file', 'a.txt', 'abc', 'summary');"
  run db:exec "$TEST_DB" "INSERT INTO entries (type, identifier, content_sha, summary) VALUES ('file', 'a.txt', 'def', 'other');"
  is "$status" 1
}
