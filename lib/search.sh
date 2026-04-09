#!/usr/bin/env bash

#-------------------------------------------------------------------------------
# Search primitives
#
# Provides embedding generation, cosine similarity ranking, and index
# staleness checking. The heavy lifting happens in helpers/embed (Elixir)
# for embedding and libexec/cosine-rank.awk for similarity computation.
# This library orchestrates the pipeline: query → embed → rank → results.
#-------------------------------------------------------------------------------

[[ "${_INCLUDED_SEARCH:-}" == "1" ]] && return 0
_INCLUDED_SEARCH=1

_SEARCH_SCRIPTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source-path=SCRIPTDIR/lib
# shellcheck disable=SC1091
{
  source "$_SEARCH_SCRIPTDIR/base.sh"
  source "$_SEARCH_SCRIPTDIR/db.sh"
  source "$_SEARCH_SCRIPTDIR/index.sh"
}

_SEARCH_COSINE_RANK="$_SEARCH_SCRIPTDIR/../libexec/cosine-rank.awk"

#-------------------------------------------------------------------------------
# search:embed TEXT
#
# Generate an embedding vector for TEXT via helpers/embed. Returns the
# JSON array on stdout (384 floats). Dies if helpers/embed fails.
#-------------------------------------------------------------------------------
search:embed() {
  local text="$1"

  local embed_helper="$_SEARCH_SCRIPTDIR/../helpers/embed"

  local output
  if ! output="$(printf '%s' "$text" | "$embed_helper" - 2> /dev/null)"; then
    die "search:embed: helpers/embed failed"
    return 1
  fi

  printf '%s' "$output"
}

export -f search:embed

#-------------------------------------------------------------------------------
# search:query PROJECT_NAME TYPE QUERY [TOP_K]
#
# Embed the query, load all entries of the given type from the index,
# compute cosine similarity via cosine-rank.awk, and print the top K
# results as tab-delimited lines: score<tab>identifier.
#
# Default TOP_K: 10.
#-------------------------------------------------------------------------------
search:query() {
  local project="$1"
  local type="$2"
  local query="$3"
  local top_k="${4:-10}"

  local db
  db="$(index:db-path "$project")"

  # Embed the query
  local query_embedding
  if ! query_embedding="$(search:embed "$query")"; then
    return 1
  fi

  local q_type
  q_type="$(db:quote "$type")"

  # Dump entries and pipe through cosine-rank.awk. The first line is the
  # query embedding, followed by tab-delimited identifier + embedding rows.
  {
    printf '%s\n' "$query_embedding"
    db:query "$db" "SELECT identifier, embedding FROM entries WHERE type = $q_type AND embedding IS NOT NULL;"
  } | awk -v top_k="$top_k" -f "$_SEARCH_COSINE_RANK"
}

export -f search:query

#-------------------------------------------------------------------------------
# search:is-stale PROJECT_NAME [MAX_AGE_DAYS]
#
# Returns 0 if the index is stale (last_indexed_at is older than
# MAX_AGE_DAYS or missing). Returns 1 if fresh. Default threshold: 3 days.
#-------------------------------------------------------------------------------
search:is-stale() {
  local project="$1"
  local max_age="${2:-3}"

  local last_indexed
  if ! last_indexed="$(index:get-meta "$project" "last_indexed_at")"; then
    # No timestamp recorded — stale by definition
    return 0
  fi

  local db
  db="$(index:db-path "$project")"

  # Use SQLite's date arithmetic to compare timestamps
  local age_check
  age_check="$(db:query "$db" "
    SELECT CASE
      WHEN datetime('$last_indexed') < datetime('now', '-$max_age days')
      THEN 'stale'
      ELSE 'fresh'
    END;
  ")"

  [[ "$age_check" == "stale" ]]
}

export -f search:is-stale
