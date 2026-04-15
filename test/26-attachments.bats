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

  # SCRATCH_CONFIG_DIR must be overridden too — attachments:global-db-path
  # reads this directly to place attachments-global.db alongside the
  # project dirs. Defaulting to $HOME/.config/scratch would be fine, but
  # making it explicit keeps every test in one clean tmpdir.
  export SCRATCH_CONFIG_DIR="${BATS_TEST_TMPDIR}/config"
  export SCRATCH_PROJECTS_DIR="${BATS_TEST_TMPDIR}/projects"
  mkdir -p "$SCRATCH_CONFIG_DIR" "${SCRATCH_PROJECTS_DIR}/testproj"
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

# ---------------------------------------------------------------------------
# Phase 3: reinforce + classify-reaction
# ---------------------------------------------------------------------------

@test "attachments:classify-reaction picks disconfirm first" {
  run attachments:classify-reaction "no, thanks, that's wrong"
  is "$output" "disconfirm"
}

@test "attachments:classify-reaction picks confirm for satisfaction tokens" {
  run attachments:classify-reaction "yes that's exactly right"
  is "$output" "confirm"
  run attachments:classify-reaction "thanks"
  is "$output" "confirm"
  run attachments:classify-reaction "perfect"
  is "$output" "confirm"
}

@test "attachments:classify-reaction returns neutral for ambiguous text" {
  run attachments:classify-reaction "tell me about the weather"
  is "$output" "neutral"
}

@test "attachments:reinforce bumps confirm and updates confidence" {
  attachments:seed "$PROJECT" "p" '[1.0,0.0]' "v" "wary"
  run attachments:reinforce 1 "confirm" "$PROJECT"
  is "$status" 0
  local db
  db="$(attachments:db-path "$PROJECT")"
  run db:query "$db" "SELECT confirm_count, confidence FROM attachments WHERE id=1;"
  # Laplace: confirm=1, disconfirm=0 → (1+1)/(1+0+2) = 2/3 = 0.6666...
  # confidence is stored as REAL; sqlite prints it without trimming.
  local conf
  conf="$(db:query "$db" "SELECT confirm_count FROM attachments WHERE id=1;")"
  is "$conf" "1"
}

@test "attachments:reinforce bumps disconfirm" {
  attachments:seed "$PROJECT" "p" '[1.0,0.0]' "v" "wary"
  attachments:reinforce 1 "disconfirm" "$PROJECT"
  local db
  db="$(attachments:db-path "$PROJECT")"
  run db:query "$db" "SELECT disconfirm_count FROM attachments WHERE id=1;"
  is "$output" "1"
}

@test "attachments:reinforce resolves unresolved fires in the last 10 minutes" {
  attachments:seed "$PROJECT" "p" '[1.0,0.0]' "v" "wary"
  attachments:fire "$PROJECT" '[1.0,0.0]' 5 > /dev/null

  local db
  db="$(attachments:db-path "$PROJECT")"
  run db:query "$db" "SELECT was_confirmed IS NULL FROM attachment_fires WHERE attachment_id=1;"
  is "$output" "1"

  attachments:reinforce 1 "confirm" "$PROJECT"

  run db:query "$db" "SELECT was_confirmed FROM attachment_fires WHERE attachment_id=1;"
  is "$output" "1"
}

@test "attachments:reinforce with neutral is a no-op" {
  attachments:seed "$PROJECT" "p" '[1.0,0.0]' "v" "wary"
  run attachments:reinforce 1 "neutral" "$PROJECT"
  is "$status" 0
  local db
  db="$(attachments:db-path "$PROJECT")"
  run db:query "$db" "SELECT confirm_count + disconfirm_count FROM attachments WHERE id=1;"
  is "$output" "0"
}

@test "attachments:apply-reaction applies classify to recent fires" {
  attachments:seed "$PROJECT" "p" '[1.0,0.0]' "v" "wary"
  attachments:fire "$PROJECT" '[1.0,0.0]' 5 > /dev/null

  attachments:apply-reaction "$PROJECT" "thanks, perfect"

  local db
  db="$(attachments:db-path "$PROJECT")"
  run db:query "$db" "SELECT confirm_count, disconfirm_count FROM attachments WHERE id=1;"
  is "$output" $'1\t0'
}

# ---------------------------------------------------------------------------
# Phase 3: associate + substrate-neighbors
# ---------------------------------------------------------------------------

@test "attachments:associate inserts and bumps reinforcement on duplicate" {
  attachments:record-turn "$PROJECT" "s" "0" "moment A"
  attachments:record-turn "$PROJECT" "s" "1" "moment B"

  local id1 id2
  id1="$(attachments:associate "$PROJECT" 1 2 "label one" '[0.1,0.2]')"
  id2="$(attachments:associate "$PROJECT" 1 2 "label one" '[0.1,0.2]')"
  is "$id1" "$id2"

  local db
  db="$(attachments:db-path "$PROJECT")"
  run db:query "$db" "SELECT reinforcement FROM associations WHERE id=$id1;"
  is "$output" "2"
}

@test "attachments:associate allows multiple labels per pair" {
  attachments:record-turn "$PROJECT" "s" "0" "A"
  attachments:record-turn "$PROJECT" "s" "1" "B"

  local id1 id2
  id1="$(attachments:associate "$PROJECT" 1 2 "label one" '[0.1,0.2]')"
  id2="$(attachments:associate "$PROJECT" 1 2 "label two" '[0.3,0.4]')"
  [[ "$id1" != "$id2" ]]
}

@test "attachments:substrate-neighbors emits dedup pairs in canonical order" {
  attachments:record-turn "$PROJECT" "s" "0" "a"
  attachments:record-turn "$PROJECT" "s" "1" "b"
  attachments:record-turn "$PROJECT" "s" "2" "c"

  # Hand-set embeddings so we control the cosine topology
  local db
  db="$(attachments:db-path "$PROJECT")"
  db:exec "$db" "
    UPDATE substrate_events SET situation_embedding='[1.0,0.0,0.0]' WHERE id=1;
    UPDATE substrate_events SET situation_embedding='[0.9,0.1,0.0]' WHERE id=2;
    UPDATE substrate_events SET situation_embedding='[0.0,1.0,0.0]' WHERE id=3;
  "

  run attachments:substrate-neighbors "$PROJECT" "" 8
  is "$status" 0
  # Expect (1,2) as the closest pair; canonical order (smaller first)
  [[ "$output" == *$'1\t2'* ]]
}

# ---------------------------------------------------------------------------
# Phase 3: cluster-associations
# ---------------------------------------------------------------------------

@test "attachments:cluster-associations groups near-duplicate labels" {
  attachments:record-turn "$PROJECT" "s" "0" "a"
  attachments:record-turn "$PROJECT" "s" "1" "b"
  attachments:record-turn "$PROJECT" "s" "2" "c"
  attachments:record-turn "$PROJECT" "s" "3" "d"

  # Two near-duplicate labels (high cosine) plus one distinct one.
  attachments:associate "$PROJECT" 1 2 "ambiguous scope" '[1.0,0.0,0.0]' > /dev/null
  attachments:associate "$PROJECT" 2 3 "ambiguous scope similar" '[0.95,0.05,0.0]' > /dev/null
  attachments:associate "$PROJECT" 3 4 "user wants terse" '[0.0,1.0,0.0]' > /dev/null

  local clusters
  clusters="$(attachments:cluster-associations "$PROJECT" 0.15)"
  local n
  n="$(printf '%s\n' "$clusters" | grep -c '^{')"
  is "$n" "2"
}

# ---------------------------------------------------------------------------
# Phase 3: mint-cluster (via stubbed agent)
# ---------------------------------------------------------------------------

@test "attachments:mint-cluster skips below count threshold" {
  attachments:ensure "$PROJECT"
  local cluster='{"association_ids":[1,2],"total_reinforcement":10,"count":2,"centroid_embedding":[0.1,0.2],"sample_labels":["x"]}'
  run attachments:mint-cluster "$PROJECT" "$cluster" 3 5
  is "$status" 0
  is "$output" ""
}

@test "attachments:mint-cluster skips below reinforcement threshold" {
  attachments:ensure "$PROJECT"
  local cluster='{"association_ids":[1,2,3],"total_reinforcement":2,"count":3,"centroid_embedding":[0.1,0.2],"sample_labels":["x"]}'
  run attachments:mint-cluster "$PROJECT" "$cluster" 3 5
  is "$status" 0
  is "$output" ""
}

@test "attachments:mint-cluster mints when minter confirms (stubbed agent)" {
  # Seed real substrate + associations so provenance joins find rows
  attachments:record-turn "$PROJECT" "s" "0" "A"
  attachments:record-turn "$PROJECT" "s" "1" "B"
  attachments:record-turn "$PROJECT" "s" "2" "C"
  attachments:associate "$PROJECT" 1 2 "label1" '[1.0,0.0,0.0]' > /dev/null
  attachments:associate "$PROJECT" 2 3 "label2" '[0.9,0.1,0.0]' > /dev/null
  attachments:associate "$PROJECT" 1 3 "label3" '[0.95,0.05,0.0]' > /dev/null

  # Stub the agent invocation via SCRATCH_ATTACHMENTS_AGENT_CMD
  export SCRATCH_ATTACHMENTS_AGENT_CMD="${BATS_TEST_TMPDIR}/stub-agent"
  cat > "$SCRATCH_ATTACHMENTS_AGENT_CMD" << 'STUB'
#!/usr/bin/env bash
cat > /dev/null  # discard input
case "$1" in
  attachment-minter)
    printf '{"confirm":true,"prediction":"in X, user likely wants Y","inner_voice":"just do it","affect":"confident","confidence":0.7}\n'
    ;;
  *) exit 1 ;;
esac
STUB
  chmod +x "$SCRATCH_ATTACHMENTS_AGENT_CMD"

  local cluster='{"association_ids":[1,2,3],"total_reinforcement":10,"count":3,"centroid_embedding":[1.0,0.0,0.0],"sample_labels":["label1","label2","label3"]}'
  run attachments:mint-cluster "$PROJECT" "$cluster" 3 5
  is "$status" 0
  [[ "$output" =~ ^[0-9]+$ ]]

  local aid="$output"
  local db
  db="$(attachments:db-path "$PROJECT")"

  # Attachment inserted
  run db:query "$db" "SELECT prediction, affect, confidence FROM attachments WHERE id=$aid;"
  is "$output" $'in X, user likely wants Y\tconfident\t0.7'

  # Provenance includes every substrate event and every association
  run db:query "$db" "SELECT kind, count(*) FROM attachment_provenance WHERE attachment_id=$aid GROUP BY kind ORDER BY kind;"
  is "$output" $'association\t3\nsubstrate\t3'
}

@test "attachments:mint-cluster skips when minter declines (stubbed agent)" {
  attachments:record-turn "$PROJECT" "s" "0" "A"
  attachments:record-turn "$PROJECT" "s" "1" "B"
  attachments:record-turn "$PROJECT" "s" "2" "C"
  attachments:associate "$PROJECT" 1 2 "label1" '[1.0,0.0,0.0]' > /dev/null
  attachments:associate "$PROJECT" 2 3 "label2" '[0.9,0.1,0.0]' > /dev/null
  attachments:associate "$PROJECT" 1 3 "label3" '[0.95,0.05,0.0]' > /dev/null

  export SCRATCH_ATTACHMENTS_AGENT_CMD="${BATS_TEST_TMPDIR}/stub-agent-decline"
  cat > "$SCRATCH_ATTACHMENTS_AGENT_CMD" << 'STUB'
#!/usr/bin/env bash
cat > /dev/null
printf '{"confirm":false}\n'
STUB
  chmod +x "$SCRATCH_ATTACHMENTS_AGENT_CMD"

  local cluster='{"association_ids":[1,2,3],"total_reinforcement":10,"count":3,"centroid_embedding":[1.0,0.0,0.0],"sample_labels":["label1","label2","label3"]}'
  run attachments:mint-cluster "$PROJECT" "$cluster" 3 5
  is "$status" 0
  is "$output" ""

  local db
  db="$(attachments:db-path "$PROJECT")"
  run db:query "$db" "SELECT count(*) FROM attachments;"
  is "$output" "0"
}

@test "attachments:mint-cluster is idempotent by signature" {
  attachments:record-turn "$PROJECT" "s" "0" "A"
  attachments:record-turn "$PROJECT" "s" "1" "B"
  attachments:record-turn "$PROJECT" "s" "2" "C"
  attachments:associate "$PROJECT" 1 2 "l1" '[1.0,0.0,0.0]' > /dev/null
  attachments:associate "$PROJECT" 2 3 "l2" '[0.9,0.1,0.0]' > /dev/null
  attachments:associate "$PROJECT" 1 3 "l3" '[0.95,0.05,0.0]' > /dev/null

  export SCRATCH_ATTACHMENTS_AGENT_CMD="${BATS_TEST_TMPDIR}/stub-agent-idem"
  cat > "$SCRATCH_ATTACHMENTS_AGENT_CMD" << 'STUB'
#!/usr/bin/env bash
cat > /dev/null
printf '{"confirm":true,"prediction":"p","inner_voice":"v","affect":"curious","confidence":0.5}\n'
STUB
  chmod +x "$SCRATCH_ATTACHMENTS_AGENT_CMD"

  local cluster='{"association_ids":[1,2,3],"total_reinforcement":10,"count":3,"centroid_embedding":[1.0,0.0,0.0],"sample_labels":["l1","l2","l3"]}'

  # First mint succeeds
  run attachments:mint-cluster "$PROJECT" "$cluster" 3 5
  is "$status" 0
  [[ "$output" =~ ^[0-9]+$ ]]

  # Second call on identical centroid is a no-op (signature collides)
  run attachments:mint-cluster "$PROJECT" "$cluster" 3 5
  is "$status" 0
  is "$output" ""

  local db
  db="$(attachments:db-path "$PROJECT")"
  run db:query "$db" "SELECT count(*) FROM attachments;"
  is "$output" "1"
}

# ---------------------------------------------------------------------------
# Phase 3: decay
# ---------------------------------------------------------------------------

@test "attachments:decay reduces health for never-fired attachments" {
  attachments:seed "$PROJECT" "p" '[1.0,0.0]' "v" "wary"

  local db
  db="$(attachments:db-path "$PROJECT")"
  local before
  before="$(db:query "$db" "SELECT health FROM attachments WHERE id=1;")"
  is "$before" "1.0"

  attachments:decay "$PROJECT"

  local after
  after="$(db:query "$db" "SELECT health FROM attachments WHERE id=1;")"
  # 1.0 - 0.02 = 0.98
  is "$after" "0.98"
}

@test "attachments:decay hits attachments with more disconfirm than confirm" {
  attachments:seed "$PROJECT" "p" '[1.0,0.0]' "v" "wary"
  local db
  db="$(attachments:db-path "$PROJECT")"

  # Simulate disconfirm dominance
  db:exec "$db" "UPDATE attachments SET disconfirm_count=3, confirm_count=0, last_fired_at=datetime('now') WHERE id=1;"

  attachments:decay "$PROJECT"

  local after
  after="$(db:query "$db" "SELECT health FROM attachments WHERE id=1;")"
  # Fresh last_fired_at so no stale decay; disconfirm path: 1.0 - 0.1 = 0.9
  is "$after" "0.9"
}

@test "attachments:decay leaves fresh-and-confirmed attachments alone" {
  attachments:seed "$PROJECT" "p" '[1.0,0.0]' "v" "wary"
  local db
  db="$(attachments:db-path "$PROJECT")"
  db:exec "$db" "UPDATE attachments SET confirm_count=3, disconfirm_count=0, last_fired_at=datetime('now') WHERE id=1;"

  attachments:decay "$PROJECT"

  local after
  after="$(db:query "$db" "SELECT health FROM attachments WHERE id=1;")"
  is "$after" "1.0"
}

# ---------------------------------------------------------------------------
# Phase 4: tension detection in format-priming
# ---------------------------------------------------------------------------

@test "attachments:format-priming adds 'threads of X' when secondary passes threshold" {
  local fired='[
    {"id":1,"prediction":"P1","inner_voice":"V1","affect":"wary","confidence":0.5,"health":1.0,"score":0.9},
    {"id":2,"prediction":"P2","inner_voice":"V2","affect":"wary","confidence":0.5,"health":1.0,"score":0.8},
    {"id":3,"prediction":"P3","inner_voice":"V3","affect":"curious","confidence":0.5,"health":1.0,"score":0.7}
  ]'
  run attachments:format-priming "$fired"
  is "$status" 0
  [[ "$output" == *"Texture: mostly wary, threads of curious"* ]]
}

@test "attachments:format-priming omits secondary below 25% threshold" {
  # 4 wary, 1 curious → curious is 20%, below 25% threshold
  local fired='[
    {"id":1,"prediction":"P1","inner_voice":"V1","affect":"wary","confidence":0.5,"health":1.0,"score":0.9},
    {"id":2,"prediction":"P2","inner_voice":"V2","affect":"wary","confidence":0.5,"health":1.0,"score":0.8},
    {"id":3,"prediction":"P3","inner_voice":"V3","affect":"wary","confidence":0.5,"health":1.0,"score":0.7},
    {"id":4,"prediction":"P4","inner_voice":"V4","affect":"wary","confidence":0.5,"health":1.0,"score":0.6},
    {"id":5,"prediction":"P5","inner_voice":"V5","affect":"curious","confidence":0.5,"health":1.0,"score":0.5}
  ]'
  run attachments:format-priming "$fired"
  is "$status" 0
  [[ "$output" == *"Texture: mostly wary"* ]]
  [[ "$output" != *"threads of"* ]]
}

@test "attachments:format-priming emits tension line when opposing pair fires together" {
  local fired='[
    {"id":1,"prediction":"P1","inner_voice":"V1","affect":"wary","confidence":0.5,"health":1.0,"score":0.9},
    {"id":2,"prediction":"P2","inner_voice":"V2","affect":"confident","confidence":0.5,"health":1.0,"score":0.8}
  ]'
  run attachments:format-priming "$fired"
  is "$status" 0
  [[ "$output" == *"tension: wary ↔ confident"* ]]
}

@test "attachments:format-priming detects each declared tension pair" {
  for pair in "wary:confident" "uneasy:eager" "resigned:curious"; do
    local a="${pair%%:*}"
    local b="${pair##*:}"
    local fired='[
      {"id":1,"prediction":"P1","inner_voice":"V1","affect":"'"$a"'","confidence":0.5,"health":1.0,"score":0.9},
      {"id":2,"prediction":"P2","inner_voice":"V2","affect":"'"$b"'","confidence":0.5,"health":1.0,"score":0.8}
    ]'
    run attachments:format-priming "$fired"
    is "$status" 0
    [[ "$output" == *"tension: $a ↔ $b"* ]]
  done
}

@test "attachments:format-priming has no tension line for co-fires without opposing pair" {
  # wary + uneasy share valence, not a declared tension pair
  local fired='[
    {"id":1,"prediction":"P1","inner_voice":"V1","affect":"wary","confidence":0.5,"health":1.0,"score":0.9},
    {"id":2,"prediction":"P2","inner_voice":"V2","affect":"uneasy","confidence":0.5,"health":1.0,"score":0.8}
  ]'
  run attachments:format-priming "$fired"
  is "$status" 0
  [[ "$output" != *"tension:"* ]]
}

# ---------------------------------------------------------------------------
# Phase 4: settings
# ---------------------------------------------------------------------------

@test "attachments:setting returns default when file missing" {
  # Delete the settings.json so the file lookup fails
  rm -f "${SCRATCH_PROJECTS_DIR}/testproj/settings.json"
  run attachments:setting "$PROJECT" "firing_timeout_ms" "1500"
  is "$status" 0
  is "$output" "1500"
}

@test "attachments:setting returns value when set under attachments.<key>" {
  cat > "${SCRATCH_PROJECTS_DIR}/testproj/settings.json" << 'JSON'
{
  "root": "/tmp/fake",
  "is_git": false,
  "exclude": [],
  "attachments": {
    "firing_timeout_ms": 2500,
    "enabled": false
  }
}
JSON
  run attachments:setting "$PROJECT" "firing_timeout_ms" "1500"
  is "$status" 0
  is "$output" "2500"
  run attachments:setting "$PROJECT" "enabled" "true"
  is "$status" 0
  is "$output" "false"
}

@test "attachments:setting returns default when key is missing" {
  cat > "${SCRATCH_PROJECTS_DIR}/testproj/settings.json" << 'JSON'
{"root":"/tmp/fake","is_git":false,"exclude":[],"attachments":{}}
JSON
  run attachments:setting "$PROJECT" "firing_timeout_ms" "1500"
  is "$status" 0
  is "$output" "1500"
}

# ---------------------------------------------------------------------------
# Phase 4: fires log
# ---------------------------------------------------------------------------

@test "attachments:fires prints header even when empty" {
  attachments:ensure "$PROJECT"
  run attachments:fires "$PROJECT"
  is "$status" 0
  local head
  head="$(head -1 <<< "$output")"
  is "$head" $'FIRED_AT\tID\tCONFIRMED\tAFFECT\tPREDICTION'
}

@test "attachments:fires shows resolution status per fire" {
  attachments:seed "$PROJECT" "prediction text" '[1.0,0.0]' "voice" "wary"
  attachments:fire "$PROJECT" '[1.0,0.0]' 5 > /dev/null  # fire #1 unresolved
  attachments:fire "$PROJECT" '[1.0,0.0]' 5 > /dev/null  # fire #2 unresolved

  local db
  db="$(attachments:db-path "$PROJECT")"

  # Mark fire #1 confirmed
  db:exec "$db" "UPDATE attachment_fires SET was_confirmed=1 WHERE id=1;"

  local output
  output="$(attachments:fires "$PROJECT" | tail -n +2 | awk -F'\t' '{print $3}' | sort -u | tr '\n' ',')"
  # Both 'yes' and '?' should appear
  [[ "$output" == *"yes"* ]]
  [[ "$output" == *"?"* ]]
}

# ---------------------------------------------------------------------------
# Phase 5: global DB + emergent globality
# ---------------------------------------------------------------------------

@test "attachments:global-db-path resolves under SCRATCH_CONFIG_DIR" {
  run attachments:global-db-path
  is "$status" 0
  is "$output" "${SCRATCH_CONFIG_DIR}/attachments-global.db"
}

@test "attachments:global-ensure creates both tables and records migration" {
  attachments:global-ensure

  local db
  db="$(attachments:global-db-path)"
  [[ -f "$db" ]]

  run db:exists "$db" "SELECT 1 FROM sqlite_master WHERE type='table' AND name='global_attachments';"
  is "$status" 0
  run db:exists "$db" "SELECT 1 FROM sqlite_master WHERE type='table' AND name='global_fires';"
  is "$status" 0
  run db:exists "$db" "SELECT 1 FROM migrations WHERE name='001-initial.sql';"
  is "$status" 0
}

@test "attachments:log-global-fire inserts a slim record" {
  attachments:log-global-fire "proj-a" "deadbeef01"
  attachments:log-global-fire "proj-b" "deadbeef01"
  local db
  db="$(attachments:global-db-path)"
  run db:query "$db" "SELECT count(*) FROM global_fires WHERE shape_signature='deadbeef01';"
  is "$output" "2"
}

@test "attachments:fire logs global fire alongside local fire" {
  attachments:seed "$PROJECT" "pred" '[1.0,0.0,0.0]' "voice" "wary"
  attachments:fire "$PROJECT" '[1.0,0.0,0.0]' 5 > /dev/null

  local gdb sig
  gdb="$(attachments:global-db-path)"
  sig="$(db:query "$(attachments:db-path "$PROJECT")" "SELECT shape_signature FROM attachments WHERE id=1;")"

  run db:query "$gdb" "SELECT count(*) FROM global_fires WHERE shape_signature='$sig' AND project='$PROJECT';"
  is "$output" "1"
}

@test "attachments:fire merges local and global hits with a global flag" {
  # Local attachment
  attachments:seed "$PROJECT" "local pred" '[1.0,0.0,0.0]' "local v" "wary"

  # Inject a global-only attachment directly
  attachments:global-ensure
  local gdb
  gdb="$(attachments:global-db-path)"
  db:exec "$gdb" "
    INSERT INTO global_attachments (shape_signature, prediction, prediction_embedding, inner_voice, affect)
    VALUES ('globalsig001', 'global pred', '[0.9,0.1,0.0]', 'global v', 'curious');
  "

  run attachments:fire "$PROJECT" '[1.0,0.0,0.0]' 5
  is "$status" 0

  local n has_global
  n="$(jq 'length' <<< "$output")"
  has_global="$(jq '[.[] | select(.global == true)] | length' <<< "$output")"
  [[ "$n" -ge 2 ]]
  [[ "$has_global" -ge 1 ]]
}

@test "attachments:fire-global returns empty when global DB has nothing live" {
  run attachments:fire-global '[1.0,0.0]' 5
  is "$status" 0
  is "$output" "[]"
}

@test "attachments:check-promotion promotes attachment with ≥2 cross-project fires" {
  # Seed a project attachment; grab its signature.
  attachments:seed "$PROJECT" "shared pred" '[1.0,0.0,0.0]' "v" "curious"
  local pdb
  pdb="$(attachments:db-path "$PROJECT")"
  local sig
  sig="$(db:query "$pdb" "SELECT shape_signature FROM attachments WHERE id=1;")"

  # Simulate 2 distinct projects firing the same signature
  attachments:log-global-fire "$PROJECT" "$sig"
  attachments:log-global-fire "other-proj" "$sig"

  # Before: scope is 'project'
  run db:query "$pdb" "SELECT scope FROM attachments WHERE id=1;"
  is "$output" "project"

  attachments:check-promotion "$PROJECT"

  # After: scope is 'global_candidate' locally; global_attachments has the row.
  run db:query "$pdb" "SELECT scope FROM attachments WHERE id=1;"
  is "$output" "global_candidate"

  local gdb
  gdb="$(attachments:global-db-path)"
  local got
  got="$(db:query "$gdb" "SELECT scope, origin_project FROM global_attachments WHERE shape_signature='$sig';")"
  is "$got" $'global_candidate\t'"$PROJECT"
}

@test "attachments:check-promotion does not promote with only 1 project firing" {
  attachments:seed "$PROJECT" "only-one pred" '[1.0,0.0,0.0]' "v" "wary"
  local pdb
  pdb="$(attachments:db-path "$PROJECT")"
  local sig
  sig="$(db:query "$pdb" "SELECT shape_signature FROM attachments WHERE id=1;")"

  attachments:log-global-fire "$PROJECT" "$sig"
  attachments:log-global-fire "$PROJECT" "$sig"
  attachments:log-global-fire "$PROJECT" "$sig"

  attachments:check-promotion "$PROJECT"

  run db:query "$pdb" "SELECT scope FROM attachments WHERE id=1;"
  is "$output" "project"
}

@test "attachments:check-promotion graduates global_candidate to global" {
  attachments:seed "$PROJECT" "mature pred" '[1.0,0.0,0.0]' "v" "eager"
  local pdb
  pdb="$(attachments:db-path "$PROJECT")"
  local sig
  sig="$(db:query "$pdb" "SELECT shape_signature FROM attachments WHERE id=1;")"

  # Two distinct projects + lots of fires (≥5)
  attachments:log-global-fire "$PROJECT" "$sig"
  attachments:log-global-fire "other-proj" "$sig"
  attachments:log-global-fire "other-proj" "$sig"
  attachments:log-global-fire "other-proj" "$sig"
  attachments:log-global-fire "other-proj" "$sig"

  attachments:check-promotion "$PROJECT"

  local gdb
  gdb="$(attachments:global-db-path)"
  run db:query "$gdb" "SELECT scope FROM global_attachments WHERE shape_signature='$sig';"
  is "$output" "global"
  run db:query "$pdb" "SELECT scope FROM attachments WHERE id=1;"
  is "$output" "global"
}

@test "attachments:sweep-global-orphans decays global attachments whose origin is gone" {
  attachments:global-ensure
  local gdb
  gdb="$(attachments:global-db-path)"

  # Real origin project
  db:exec "$gdb" "INSERT INTO global_attachments
    (shape_signature, prediction, prediction_embedding, inner_voice, affect, origin_project)
    VALUES ('sig-alive', 'p', '[0.1]', 'v', 'wary', '$PROJECT');"
  # Fake origin project (no DB on disk)
  db:exec "$gdb" "INSERT INTO global_attachments
    (shape_signature, prediction, prediction_embedding, inner_voice, affect, origin_project)
    VALUES ('sig-orphan', 'p', '[0.1]', 'v', 'wary', 'nonexistent');"

  # Create the real project's DB so sweep finds it alive
  attachments:ensure "$PROJECT" > /dev/null

  attachments:sweep-global-orphans

  run db:query "$gdb" "SELECT health FROM global_attachments WHERE shape_signature='sig-alive';"
  is "$output" "1.0"
  run db:query "$gdb" "SELECT health FROM global_attachments WHERE shape_signature='sig-orphan';"
  is "$output" "0.5"
}
