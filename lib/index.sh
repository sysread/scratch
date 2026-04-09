#!/usr/bin/env bash

#-------------------------------------------------------------------------------
# Index management
#
# CRUD operations on the per-project index database. Each project gets its
# own SQLite database at ~/.config/scratch/projects/<name>/index.db, managed
# by lib/db.sh with forward-only migrations from data/migrations/index/.
#
# The `entries` table uses a (type, identifier) composite key to support
# multiple index types (file, commit, conversation, etc.) in one table.
# For file indexing, `type` is "file" and `identifier` is the relative
# path from the project root.
#
# Change detection uses content_sha (SHA-256 of raw file contents).
# File status (current/stale/orphaned/missing) is computed at query time
# by comparing the stored SHA against the live file — never stored.
#-------------------------------------------------------------------------------

[[ "${_INCLUDED_INDEX:-}" == "1" ]] && return 0
_INCLUDED_INDEX=1

_INDEX_SCRIPTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source-path=SCRIPTDIR/lib
# shellcheck disable=SC1091
{
  source "$_INDEX_SCRIPTDIR/base.sh"
  source "$_INDEX_SCRIPTDIR/db.sh"
  source "$_INDEX_SCRIPTDIR/project.sh"
}

_INDEX_MIGRATIONS_DIR="$_INDEX_SCRIPTDIR/../data/migrations/index"

#-------------------------------------------------------------------------------
# index:db-path PROJECT_NAME
#
# Print the absolute path to a project's index database file.
#-------------------------------------------------------------------------------
index:db-path() {
  local name="$1"
  printf '%s/index.db' "$(project:config-dir "$name")"
}

export -f index:db-path

#-------------------------------------------------------------------------------
# index:ensure PROJECT_NAME
#
# Ensure the project's index database exists and has the latest schema.
# Creates the database and applies migrations if needed. Idempotent.
#-------------------------------------------------------------------------------
index:ensure() {
  local name="$1"

  local db
  db="$(index:db-path "$name")"

  db:init "$db"
  db:migrate "$db" "$_INDEX_MIGRATIONS_DIR"
}

export -f index:ensure

#-------------------------------------------------------------------------------
# index:record PROJECT_NAME TYPE IDENTIFIER CONTENT_SHA SUMMARY [EMBEDDING_JSON]
#
# Upsert an index entry. If (type, identifier) already exists, update the
# sha, summary, embedding, and updated_at. Otherwise insert a new row.
# EMBEDDING_JSON is optional — pass "" or omit to leave embedding NULL
# (used by the summarize phase before the embed phase fills it in).
#-------------------------------------------------------------------------------
index:record() {
  local name="$1"
  local type="$2"
  local identifier="$3"
  local content_sha="$4"
  local summary="$5"
  local embedding="${6:-}"

  local db
  db="$(index:db-path "$name")"

  local q_type q_id q_sha q_summary q_embedding
  q_type="$(db:quote "$type")"
  q_id="$(db:quote "$identifier")"
  q_sha="$(db:quote "$content_sha")"
  q_summary="$(db:quote "$summary")"

  if [[ -n "$embedding" ]]; then
    q_embedding="$(db:quote "$embedding")"
  else
    q_embedding="NULL"
  fi

  db:exec "$db" "
    INSERT INTO entries (type, identifier, content_sha, summary, embedding)
    VALUES ($q_type, $q_id, $q_sha, $q_summary, $q_embedding)
    ON CONFLICT(type, identifier) DO UPDATE SET
      content_sha = excluded.content_sha,
      summary = excluded.summary,
      embedding = excluded.embedding,
      updated_at = datetime('now');
  "
}

export -f index:record

#-------------------------------------------------------------------------------
# index:lookup PROJECT_NAME TYPE IDENTIFIER
#
# Print the entry as a JSON object, or return 1 if not found.
#-------------------------------------------------------------------------------
index:lookup() {
  local name="$1"
  local type="$2"
  local identifier="$3"

  local db
  db="$(index:db-path "$name")"

  local q_type q_id
  q_type="$(db:quote "$type")"
  q_id="$(db:quote "$identifier")"

  local result
  result="$(db:query-json "$db" "
    SELECT id, type, identifier, content_sha, summary, embedding, created_at, updated_at
    FROM entries
    WHERE type = $q_type AND identifier = $q_id;
  ")"

  # query-json returns "[]" for no results
  if [[ "$result" == "[]" ]]; then
    return 1
  fi

  # Unwrap the single-element array to a plain object
  printf '%s' "$result" | jq -c '.[0]'
}

export -f index:lookup

#-------------------------------------------------------------------------------
# index:remove PROJECT_NAME TYPE IDENTIFIER
#
# Delete an entry. Returns 0 even if the entry didn't exist.
#-------------------------------------------------------------------------------
index:remove() {
  local name="$1"
  local type="$2"
  local identifier="$3"

  local db
  db="$(index:db-path "$name")"

  local q_type q_id
  q_type="$(db:quote "$type")"
  q_id="$(db:quote "$identifier")"

  db:exec "$db" "DELETE FROM entries WHERE type = $q_type AND identifier = $q_id;"
}

export -f index:remove

#-------------------------------------------------------------------------------
# index:remove-type PROJECT_NAME TYPE
#
# Delete all entries of a given type.
#-------------------------------------------------------------------------------
index:remove-type() {
  local name="$1"
  local type="$2"

  local db
  db="$(index:db-path "$name")"

  local q_type
  q_type="$(db:quote "$type")"

  db:exec "$db" "DELETE FROM entries WHERE type = $q_type;"
}

export -f index:remove-type

#-------------------------------------------------------------------------------
# index:list PROJECT_NAME TYPE
#
# Print all (identifier, content_sha) pairs for a type. Tab-delimited,
# one per line. Used by the index command to diff against the filesystem.
#-------------------------------------------------------------------------------
index:list() {
  local name="$1"
  local type="$2"

  local db
  db="$(index:db-path "$name")"

  local q_type
  q_type="$(db:quote "$type")"

  db:query "$db" "SELECT identifier, content_sha FROM entries WHERE type = $q_type ORDER BY identifier;"
}

export -f index:list

#-------------------------------------------------------------------------------
# index:set-meta PROJECT_NAME KEY VALUE
#
# Upsert a metadata key-value pair.
#-------------------------------------------------------------------------------
index:set-meta() {
  local name="$1"
  local key="$2"
  local value="$3"

  local db
  db="$(index:db-path "$name")"

  local q_key q_val
  q_key="$(db:quote "$key")"
  q_val="$(db:quote "$value")"

  db:exec "$db" "
    INSERT INTO metadata (key, value) VALUES ($q_key, $q_val)
    ON CONFLICT(key) DO UPDATE SET value = excluded.value;
  "
}

export -f index:set-meta

#-------------------------------------------------------------------------------
# index:get-meta PROJECT_NAME KEY
#
# Print a metadata value, or return 1 if the key doesn't exist.
#-------------------------------------------------------------------------------
index:get-meta() {
  local name="$1"
  local key="$2"

  local db
  db="$(index:db-path "$name")"

  local q_key
  q_key="$(db:quote "$key")"

  local result
  result="$(db:query "$db" "SELECT value FROM metadata WHERE key = $q_key;")"

  if [[ -z "$result" ]]; then
    return 1
  fi

  printf '%s' "$result"
}

export -f index:get-meta
