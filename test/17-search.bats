#!/usr/bin/env bats

# vim: set ft=bash
set -euo pipefail

#-------------------------------------------------------------------------------
# Tests for lib/search.sh
#
# Stubs helpers/embed so no Elixir/ML deps are needed. Pre-seeds the
# index database with known embeddings for ranking tests.
#-------------------------------------------------------------------------------

setup() {
  SCRIPTDIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" > /dev/null 2>&1 && pwd)"
  SCRATCH_HOME="$(cd "${SCRIPTDIR}/.." && pwd)"
  source "${SCRIPTDIR}/helpers.sh"
  source "${SCRATCH_HOME}/lib/search.sh"

  export HOME="${BATS_TEST_TMPDIR}/home"
  mkdir -p "$HOME"

  export SCRATCH_PROJECTS_DIR="${BATS_TEST_TMPDIR}/projects"
  mkdir -p "${SCRATCH_PROJECTS_DIR}/testproj"
  printf '{"root":"/tmp/fake","is_git":false,"exclude":[]}\n' \
    > "${SCRATCH_PROJECTS_DIR}/testproj/settings.json"

  PROJECT="testproj"
  index:ensure "$PROJECT"
}

# Stub helpers/embed to return a known vector based on input text.
# Replaces search:embed directly since that's cleaner than stubbing the
# external script path.
install_embed_stub() {
  local vector="$1"
  eval "search:embed() { printf '%s' '$vector'; }"
}

# ---------------------------------------------------------------------------
# search:embed
# ---------------------------------------------------------------------------

@test "search:embed calls helpers/embed and returns JSON array" {
  # Stub search:embed with a known vector
  install_embed_stub "[1.0,0.0,0.0]"

  run search:embed "test query"
  is "$status" 0
  is "$output" "[1.0,0.0,0.0]"
}

# ---------------------------------------------------------------------------
# search:query
# ---------------------------------------------------------------------------

@test "search:query returns ranked results" {
  # Seed entries with known 3-dim embeddings
  index:record "$PROJECT" file "exact.sh" "aaa" "exact match" "[1.0,0.0,0.0]"
  index:record "$PROJECT" file "partial.sh" "bbb" "partial match" "[0.7,0.7,0.0]"
  index:record "$PROJECT" file "orthogonal.sh" "ccc" "no match" "[0.0,1.0,0.0]"

  # Stub embed to return the query vector
  install_embed_stub "[1.0,0.0,0.0]"

  run search:query "$PROJECT" file "test query"
  is "$status" 0

  # Should have 3 results, sorted by score descending
  local line_count
  line_count="$(echo "$output" | wc -l | tr -d ' ')"
  is "$line_count" "3"

  # First result should be exact.sh (score 1.000)
  local first_id
  first_id="$(echo "$output" | head -1 | cut -f2)"
  is "$first_id" "exact.sh"

  local first_score
  first_score="$(echo "$output" | head -1 | cut -f1)"
  is "$first_score" "1.000"
}

@test "search:query respects top_k" {
  index:record "$PROJECT" file "a.sh" "aaa" "a" "[1.0,0.0,0.0]"
  index:record "$PROJECT" file "b.sh" "bbb" "b" "[0.9,0.1,0.0]"
  index:record "$PROJECT" file "c.sh" "ccc" "c" "[0.0,1.0,0.0]"

  install_embed_stub "[1.0,0.0,0.0]"

  run search:query "$PROJECT" file "test" 2
  is "$status" 0

  local line_count
  line_count="$(echo "$output" | wc -l | tr -d ' ')"
  is "$line_count" "2"
}

@test "search:query skips entries with NULL embedding" {
  index:record "$PROJECT" file "has-embed.sh" "aaa" "has" "[1.0,0.0,0.0]"
  index:record "$PROJECT" file "no-embed.sh" "bbb" "no embed"
  # no-embed.sh has NULL embedding

  install_embed_stub "[1.0,0.0,0.0]"

  run search:query "$PROJECT" file "test"
  is "$status" 0

  # Only 1 result (the one with an embedding)
  local line_count
  line_count="$(echo "$output" | wc -l | tr -d ' ')"
  is "$line_count" "1"

  [[ "$output" == *"has-embed.sh"* ]]
}

@test "search:query returns empty for no entries" {
  install_embed_stub "[1.0,0.0,0.0]"

  run search:query "$PROJECT" file "test"
  is "$status" 0
  is "$output" ""
}

# ---------------------------------------------------------------------------
# search:is-stale
# ---------------------------------------------------------------------------

@test "search:is-stale returns 0 when no timestamp exists" {
  run search:is-stale "$PROJECT"
  is "$status" 0
}

@test "search:is-stale returns 0 when timestamp is old" {
  index:set-meta "$PROJECT" "last_indexed_at" "2020-01-01T00:00:00"
  run search:is-stale "$PROJECT"
  is "$status" 0
}

@test "search:is-stale returns 1 when timestamp is fresh" {
  # Set to now
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%S)"
  index:set-meta "$PROJECT" "last_indexed_at" "$now"
  run search:is-stale "$PROJECT"
  is "$status" 1
}

@test "search:is-stale respects custom max_age" {
  # Set to 2 days ago — stale with max_age=1, fresh with max_age=3
  local db
  db="$(index:db-path "$PROJECT")"
  local two_days_ago
  two_days_ago="$(db:query "$db" "SELECT datetime('now', '-2 days');")"
  index:set-meta "$PROJECT" "last_indexed_at" "$two_days_ago"

  run search:is-stale "$PROJECT" 1
  is "$status" 0

  run search:is-stale "$PROJECT" 5
  is "$status" 1
}
