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

# ---------------------------------------------------------------------------
# Phase 2: affect vocabulary + shape signature
# ---------------------------------------------------------------------------

@test "attachments:affect-valid accepts the controlled vocab" {
  for a in wary curious confident uneasy resigned eager uncertain surprised; do
    run attachments:affect-valid "$a"
    is "$status" 0
  done
}

@test "attachments:affect-valid rejects anything outside the vocab" {
  run attachments:affect-valid "angry"
  is "$status" 1
  run attachments:affect-valid ""
  is "$status" 1
  run attachments:affect-valid "Wary"  # case-sensitive
  is "$status" 1
}

@test "attachments:shape-signature is deterministic for the same embedding" {
  local emb='[0.1,-0.2,0.3,-0.4,0.5]'
  local sig1 sig2
  sig1="$(attachments:shape-signature "$emb")"
  sig2="$(attachments:shape-signature "$emb")"
  is "$sig1" "$sig2"
  # Non-empty, 12 hex chars
  [[ "$sig1" =~ ^[0-9a-f]{12}$ ]]
}

@test "attachments:shape-signature differs for sign-flipped embedding" {
  local sig1 sig2
  sig1="$(attachments:shape-signature '[0.1,-0.2,0.3]')"
  sig2="$(attachments:shape-signature '[-0.1,0.2,-0.3]')"
  [[ "$sig1" != "$sig2" ]]
}

@test "attachments:shape-signature is insensitive to magnitude along the same direction" {
  # Sign-quantization ignores magnitude; only orientation matters.
  local sig1 sig2
  sig1="$(attachments:shape-signature '[0.1,-0.2,0.3]')"
  sig2="$(attachments:shape-signature '[5.0,-9.0,2.5]')"
  is "$sig1" "$sig2"
}

# ---------------------------------------------------------------------------
# Phase 2: seed
# ---------------------------------------------------------------------------

@test "attachments:seed inserts an attachment and prints its id" {
  local emb='[0.1,-0.2,0.3,-0.4]'
  run attachments:seed "$PROJECT" "user wants terse" "$emb" "don't pad" "wary"
  is "$status" 0
  is "$output" "1"

  local db
  db="$(attachments:db-path "$PROJECT")"
  run db:query "$db" "SELECT prediction, inner_voice, affect, confidence, health FROM attachments WHERE id=1;"
  is "$output" $'user wants terse\tdon\'t pad\twary\t0.5\t1.0'
}

@test "attachments:seed rejects invalid affect" {
  local emb='[0.1,0.2]'
  run attachments:seed "$PROJECT" "pred" "$emb" "voice" "angry"
  is "$status" 1
}

@test "attachments:seed respects explicit confidence" {
  attachments:seed "$PROJECT" "pred" '[0.1,0.2]' "voice" "curious" "0.75"
  local db
  db="$(attachments:db-path "$PROJECT")"
  run db:query "$db" "SELECT confidence FROM attachments WHERE id=1;"
  is "$output" "0.75"
}

@test "attachments:seed sets scope=project and health=1.0 by default" {
  attachments:seed "$PROJECT" "pred" '[0.1,0.2]' "voice" "eager"
  local db
  db="$(attachments:db-path "$PROJECT")"
  run db:query "$db" "SELECT scope, health FROM attachments WHERE id=1;"
  is "$output" $'project\t1.0'
}

# ---------------------------------------------------------------------------
# Phase 2: fire
# ---------------------------------------------------------------------------

@test "attachments:fire returns [] when no attachments exist" {
  run attachments:fire "$PROJECT" '[0.1,0.2,0.3]' 5
  is "$status" 0
  is "$output" "[]"
}

@test "attachments:fire returns top-k matches with score, logs fire, increments fire_count" {
  # Two attachments with different embeddings
  attachments:seed "$PROJECT" "pred alpha" '[1.0,0.0,0.0]' "voice alpha" "wary"
  attachments:seed "$PROJECT" "pred beta"  '[0.0,1.0,0.0]' "voice beta"  "curious"

  # Situation close to alpha (cosine ~1.0) and orthogonal to beta
  run attachments:fire "$PROJECT" '[0.9,0.1,0.0]' 5
  is "$status" 0

  # Result is a JSON array of at least one object; top match should be alpha
  local top_id top_pred top_affect top_score
  top_id="$(jq '.[0].id' <<< "$output")"
  top_pred="$(jq -r '.[0].prediction' <<< "$output")"
  top_affect="$(jq -r '.[0].affect' <<< "$output")"
  top_score="$(jq '.[0].score' <<< "$output")"

  is "$top_id" "1"
  is "$top_pred" "pred alpha"
  is "$top_affect" "wary"
  # Score should be > 0.95 for nearly-collinear vectors
  [[ "$(awk -v s="$top_score" 'BEGIN { print (s > 0.95) }')" == "1" ]]

  # Fire was logged and counters updated
  local db
  db="$(attachments:db-path "$PROJECT")"
  run db:query "$db" "SELECT count(*) FROM attachment_fires WHERE attachment_id=1;"
  is "$output" "1"
  run db:query "$db" "SELECT fire_count FROM attachments WHERE id=1;"
  is "$output" "1"
}

@test "attachments:fire respects top_k" {
  attachments:seed "$PROJECT" "a" '[1.0,0.0,0.0]' "va" "wary"
  attachments:seed "$PROJECT" "b" '[0.9,0.1,0.0]' "vb" "curious"
  attachments:seed "$PROJECT" "c" '[0.8,0.2,0.0]' "vc" "confident"

  run attachments:fire "$PROJECT" '[1.0,0.0,0.0]' 2
  is "$status" 0
  local count
  count="$(jq 'length' <<< "$output")"
  is "$count" "2"
}

@test "attachments:fire skips attachments with health <= 0.3" {
  attachments:seed "$PROJECT" "pred" '[1.0,0.0,0.0]' "voice" "wary"
  local db
  db="$(attachments:db-path "$PROJECT")"
  db:exec "$db" "UPDATE attachments SET health=0.2 WHERE id=1;"

  run attachments:fire "$PROJECT" '[1.0,0.0,0.0]' 5
  is "$status" 0
  is "$output" "[]"
}

# ---------------------------------------------------------------------------
# Phase 2: list + show
# ---------------------------------------------------------------------------

@test "attachments:list returns header-only when empty" {
  attachments:ensure "$PROJECT"
  run attachments:list "$PROJECT"
  is "$status" 0
  local head
  head="$(head -1 <<< "$output")"
  is "$head" $'ID\tSCORE\tAFFECT\tSCOPE\tFIRES\tPREDICTION'
  local body
  body="$(tail -n +2 <<< "$output" | grep -c '.' || true)"
  is "$body" "0"
}

@test "attachments:list orders by confidence*health descending" {
  attachments:seed "$PROJECT" "third"  '[1.0,0.0]' "v" "wary"     "0.3"
  attachments:seed "$PROJECT" "first"  '[1.0,0.0]' "v" "curious"  "0.9"
  attachments:seed "$PROJECT" "second" '[1.0,0.0]' "v" "confident" "0.6"

  local out
  out="$(attachments:list "$PROJECT" | tail -n +2 | awk -F'\t' '{print $6}')"
  # Note: our seeded predictions are "first" "second" "third" but inserted out of order;
  # list should produce them by score desc: first (0.9*1.0=0.9), second (0.6), third (0.3)
  is "$out" $'first\nsecond\nthird'
}

@test "attachments:show returns JSON with provenance for existing id" {
  attachments:seed "$PROJECT" "pred" '[1.0,0.0]' "voice" "wary"
  local db
  db="$(attachments:db-path "$PROJECT")"
  db:exec "$db" "INSERT INTO attachment_provenance (attachment_id, kind, ref_id, weight)
                 VALUES (1, 'substrate', 7, 0.5),
                        (1, 'association', 13, 1.0);"

  run attachments:show "$PROJECT" 1
  is "$status" 0
  local pred affect prov_len
  pred="$(jq -r '.prediction' <<< "$output")"
  affect="$(jq -r '.affect' <<< "$output")"
  prov_len="$(jq '.provenance | length' <<< "$output")"
  is "$pred" "pred"
  is "$affect" "wary"
  is "$prov_len" "2"
}

@test "attachments:show returns 1 for missing id" {
  attachments:ensure "$PROJECT"
  run attachments:show "$PROJECT" 999
  is "$status" 1
}

@test "attachments:show rejects non-integer id" {
  attachments:ensure "$PROJECT"
  run attachments:show "$PROJECT" "abc"
  is "$status" 1
}

# ---------------------------------------------------------------------------
# Phase 2: format-priming
# ---------------------------------------------------------------------------

@test "attachments:format-priming returns empty for empty input" {
  run attachments:format-priming "[]"
  is "$status" 0
  is "$output" ""
}

@test "attachments:format-priming emits a priming block for non-empty input" {
  local fired='[{"id":1,"prediction":"P1","inner_voice":"V1","affect":"wary","confidence":0.5,"health":1.0,"score":0.62}]'
  run attachments:format-priming "$fired"
  is "$status" 0
  [[ "$output" == *"## Priming"* ]]
  [[ "$output" == *"Texture: mostly wary"* ]]
  [[ "$output" == *"[wary, 0.62]"* ]]
  [[ "$output" == *"P1 → V1"* ]]
}

@test "attachments:format-priming picks the most common affect as dominant texture" {
  local fired='[
    {"id":1,"prediction":"P1","inner_voice":"V1","affect":"curious","confidence":0.5,"health":1.0,"score":0.9},
    {"id":2,"prediction":"P2","inner_voice":"V2","affect":"curious","confidence":0.5,"health":1.0,"score":0.8},
    {"id":3,"prediction":"P3","inner_voice":"V3","affect":"wary","confidence":0.5,"health":1.0,"score":0.7}
  ]'
  run attachments:format-priming "$fired"
  is "$status" 0
  [[ "$output" == *"Texture: mostly curious"* ]]
}
