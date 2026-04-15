#!/usr/bin/env bash

#-------------------------------------------------------------------------------
# SQLite database primitives
#
# Low-level wrapper around the sqlite3 CLI. All database access in scratch
# goes through this library so callers never construct raw sqlite3 commands.
#
# Key conventions:
#   - Every function takes DB_PATH as its first argument (no global state).
#   - db:init sets WAL journal mode (persistent) and creates the file.
#   - foreign_keys is a per-connection pragma — _db:_sql prepends it to
#     every SQL execution automatically.
#   - db:migrate applies forward-only .sql migrations from a directory,
#     tracking applied migrations in a `migrations` table.
#   - db:quote escapes a value for safe embedding in SQL (doubles single
#     quotes, wraps in single quotes). Use this for dynamic values in
#     SQL strings — sqlite3 CLI has no real parameterized query support.
#   - SQL is always piped via stdin to sqlite3 to avoid issues with SQL
#     comments (--) being parsed as CLI flags.
#
# Tests override nothing — all state is in the DB file, which lives under
# BATS_TEST_TMPDIR in tests.
#-------------------------------------------------------------------------------

[[ "${_INCLUDED_DB:-}" == "1" ]] && return 0
_INCLUDED_DB=1

_DB_SCRIPTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source-path=SCRIPTDIR/lib
# shellcheck disable=SC1091
source "$_DB_SCRIPTDIR/base.sh"

has-commands sqlite3

#-------------------------------------------------------------------------------
# _db:_sql SQL
#
# Prepend the foreign_keys pragma to SQL. Every sqlite3 invocation is a
# new connection, and foreign_keys is per-connection, so this ensures FK
# enforcement everywhere without callers having to remember.
#-------------------------------------------------------------------------------
_db:_sql() {
  # foreign_keys is per-connection and must be set on every sqlite3 call.
  printf 'PRAGMA foreign_keys = ON;\n%s' "$1"
}

export -f '_db:_sql'

#-------------------------------------------------------------------------------
# _db:_sqlite3 [SQLITE_ARGS...]
#
# Invoke the sqlite3 CLI with a connection-level busy timeout preconfigured
# via the `.timeout MS` dot-command. All extra args pass through verbatim
# (e.g. `-separator`, `-json`, the db path).
#
# Why dot-command and not SQL PRAGMA: `PRAGMA busy_timeout = 10000;` echoes
# the new value to stdout, which would pollute db:query / db:query-json
# output with a spurious "10000" line. The `.timeout` dot-command sets the
# same knob silently.
#
# The busy timeout (10s) makes concurrent writers wait for the write lock
# to clear instead of failing immediately with "database is locked" — a
# problem the indexer hit when the summarize stage's 8 parallel workers
# raced through index:update-summary and dropped most writes wholesale
# (especially on the commit passthrough path with no LLM pacing).
#-------------------------------------------------------------------------------
_db:_sqlite3() {
  sqlite3 -cmd '.timeout 10000' "$@"
}

export -f '_db:_sqlite3'

#-------------------------------------------------------------------------------
# db:quote VALUE
#
# Escape a value for safe embedding in a SQL string literal. Doubles any
# single quotes and wraps the result in single quotes. Handles multiline
# values, embedded quotes, and all other special characters safely.
#
# Usage in SQL construction:
#   local q_name; q_name="$(db:quote "$name")"
#   db:exec "$db" "INSERT INTO t(name) VALUES($q_name);"
#-------------------------------------------------------------------------------
db:quote() {
  local val="$1"
  val="${val//\'/\'\'}"
  printf "'%s'" "$val"
}

export -f db:quote

#-------------------------------------------------------------------------------
# db:exec DB_PATH SQL
#
# Execute one or more SQL statements. No output is produced on success.
# Dies on error with the sqlite3 error message. Use for DDL, INSERT,
# UPDATE, DELETE — anything that doesn't return rows.
#-------------------------------------------------------------------------------
db:exec() {
  local db="$1"
  local sql="$2"

  local err
  if ! err="$(_db:_sql "$sql" | _db:_sqlite3 "$db" 2>&1)"; then
    die "db:exec: $err"
    return 1
  fi
}

export -f db:exec

#-------------------------------------------------------------------------------
# db:query DB_PATH SQL
#
# Execute a SELECT and print results to stdout. One row per line, columns
# separated by tab. Returns 0 even if the result set is empty.
# Dies on error.
#-------------------------------------------------------------------------------
db:query() {
  local db="$1"
  local sql="$2"

  local output
  if ! output="$(_db:_sql "$sql" | _db:_sqlite3 -separator $'\t' "$db" 2>&1)"; then
    die "db:query: $output"
    return 1
  fi

  [[ -n "$output" ]] && printf '%s\n' "$output"
  return 0
}

export -f db:query

#-------------------------------------------------------------------------------
# db:query-json DB_PATH SQL
#
# Execute a SELECT and print results as a JSON array of objects.
# Uses sqlite3's -json output mode. Returns "[]" for empty result sets.
# Dies on error.
#-------------------------------------------------------------------------------
db:query-json() {
  local db="$1"
  local sql="$2"

  local output
  if ! output="$(_db:_sql "$sql" | _db:_sqlite3 -json "$db" 2>&1)"; then
    die "db:query-json: $output"
    return 1
  fi

  # sqlite3 -json prints nothing for empty result sets; normalize to "[]"
  if [[ -z "$output" ]]; then
    printf '[]'
  else
    printf '%s' "$output"
  fi
}

export -f db:query-json

#-------------------------------------------------------------------------------
# db:exists DB_PATH SQL
#
# Returns 0 if the query returns at least one row, 1 otherwise. The query
# should be a SELECT. No output is produced.
#-------------------------------------------------------------------------------
db:exists() {
  local db="$1"
  local sql="$2"

  local output
  if ! output="$(_db:_sql "$sql" | _db:_sqlite3 "$db" 2>&1)"; then
    die "db:exists: $output"
    return 1
  fi

  [[ -n "$output" ]]
}

export -f db:exists

#-------------------------------------------------------------------------------
# db:init DB_PATH
#
# Ensure the database file exists and set WAL journal mode. Creates the
# file and parent directory if missing. WAL mode is persistent across
# connections. Idempotent.
#-------------------------------------------------------------------------------
db:init() {
  local db="$1"

  local dir
  dir="$(dirname "$db")"
  [[ -d "$dir" ]] || mkdir -p "$dir"

  # WAL is persistent; foreign_keys is per-connection (handled by _db:_sql)
  _db:_sqlite3 "$db" "PRAGMA journal_mode = WAL;" > /dev/null
}

export -f db:init

#-------------------------------------------------------------------------------
# db:migrate DB_PATH MIGRATIONS_DIR
#
# Apply unapplied forward-only migrations from MIGRATIONS_DIR. Each
# migration is a .sql file named with a sortable prefix (e.g.,
# 001-initial-schema.sql). The migrations table is created automatically
# if missing.
#
# Migration names are the filename without the directory prefix. A
# migration is skipped if its name already appears in the migrations
# table. Applied migrations are recorded with a timestamp.
#
# Idempotent — running twice with the same migrations dir is a no-op.
# Dies if any migration fails (the failing migration is NOT recorded).
#-------------------------------------------------------------------------------
db:migrate() {
  local db="$1"
  local migrations_dir="$2"

  if [[ ! -d "$migrations_dir" ]]; then
    die "db:migrate: migrations directory not found: $migrations_dir"
    return 1
  fi

  # Ensure the migrations tracking table exists
  db:exec "$db" "CREATE TABLE IF NOT EXISTS migrations (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL UNIQUE,
    applied_at TEXT NOT NULL DEFAULT (datetime('now'))
  );"

  # Apply each .sql file in sorted order
  local f name sql
  for f in "$migrations_dir"/*.sql; do
    [[ -f "$f" ]] || continue

    name="$(basename "$f")"

    # Skip if already applied
    if db:exists "$db" "SELECT 1 FROM migrations WHERE name = '${name//\'/\'\'}';"; then
      continue
    fi

    sql="$(cat "$f")"
    if ! db:exec "$db" "$sql"; then
      die "db:migrate: failed to apply $name"
      return 1
    fi

    local q_name
    q_name="$(db:quote "$name")"
    db:exec "$db" "INSERT INTO migrations (name) VALUES ($q_name);"
  done
}

export -f db:migrate
