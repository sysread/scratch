#!/usr/bin/env bash

#-------------------------------------------------------------------------------
# Attachments memory model
#
# "Attachments" are reinforced, affect-weighted tendencies the assistant
# forms from recurring interactions. They are not facts — they are
# pre-verbal shapes of expectation that fire as priming before the
# coordinator responds. They can be wrong, reinforce on confirmation,
# weaken on disconfirmation, and orphan-and-decay when their source
# observations vanish.
#
# This library owns four layers of primitives, all persisted in the
# per-project index.db:
#
#   substrate_events      raw observations (write-once, never user-deleted)
#   associations          pairs of substrate events + an articulated label
#   attachments           tendencies minted from clusters of associations
#   attachment_fires      log of priming events
#
# Phases:
#   1 — substrate recording (record-turn)
#   2 — hand-seeded attachments + firing (seed, fire, list, show)
#   3 — real consolidation (associate, mint) — not in this file
#   4 — tension surfacing + background-firing fallback
#   5 — emergent globality (global DB)
#
# See /root/.claude/plans/piped-prancing-cat.md for the full design.
#-------------------------------------------------------------------------------

[[ "${_INCLUDED_ATTACHMENTS:-}" == "1" ]] && return 0
_INCLUDED_ATTACHMENTS=1

_ATTACHMENTS_SCRIPTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source-path=SCRIPTDIR/lib
# shellcheck disable=SC1091
{
  source "$_ATTACHMENTS_SCRIPTDIR/base.sh"
  source "$_ATTACHMENTS_SCRIPTDIR/db.sh"
  source "$_ATTACHMENTS_SCRIPTDIR/index.sh"
}

_ATTACHMENTS_COSINE_RANK="$_ATTACHMENTS_SCRIPTDIR/../libexec/cosine-rank.awk"

# Controlled-vocabulary affect tags. Attachments outside this set are
# rejected at mint/seed time.
_ATTACHMENTS_AFFECT_VOCAB="wary curious confident uneasy resigned eager uncertain surprised"

#-------------------------------------------------------------------------------
# attachments:affect-vocab
#
# Print the controlled affect vocabulary as space-separated tokens. Used
# by seed validation and by prompt construction (so the agents that mint
# attachments see the same vocab this lib enforces).
#-------------------------------------------------------------------------------
attachments:affect-vocab() {
  printf '%s' "$_ATTACHMENTS_AFFECT_VOCAB"
}

export -f attachments:affect-vocab

#-------------------------------------------------------------------------------
# attachments:affect-valid AFFECT
#
# Returns 0 if AFFECT is in the controlled vocab, 1 otherwise.
#-------------------------------------------------------------------------------
attachments:affect-valid() {
  local a="$1"
  local t
  for t in $_ATTACHMENTS_AFFECT_VOCAB; do
    [[ "$t" == "$a" ]] && return 0
  done
  return 1
}

export -f attachments:affect-valid

#-------------------------------------------------------------------------------
# attachments:db-path PROJECT_NAME
#
# Print the absolute path to the project's attachments DB. Attachments
# share the index.db so migrations and backups stay coherent.
#-------------------------------------------------------------------------------
attachments:db-path() {
  index:db-path "$1"
}

export -f attachments:db-path

#-------------------------------------------------------------------------------
# attachments:ensure PROJECT_NAME
#
# Ensure the DB exists with all schema migrations applied (including
# the attachments migration 002-attachments.sql). Idempotent. Delegates
# to index:ensure.
#-------------------------------------------------------------------------------
attachments:ensure() {
  index:ensure "$1"
}

export -f attachments:ensure

#-------------------------------------------------------------------------------
# attachments:record-turn PROJECT_NAME SLUG ROUND_INDEX SITUATION [OUTCOME] [AFFECT]
#
# Insert a 'turn' row into substrate_events. The substrate is write-once
# and self-contained — SITUATION is the authoritative record of what
# happened. SLUG and ROUND_INDEX are soft pointers only; they may dangle
# if the underlying conversation is edited or deleted, and callers must
# never join substrate against conversations as though the pointers were
# authoritative.
#
# Empty ROUND_INDEX or OUTCOME or AFFECT is stored as NULL.
#
# Prints the id of the inserted substrate row to stdout.
#-------------------------------------------------------------------------------
attachments:record-turn() {
  local project="$1"
  local slug="$2"
  local round="$3"
  local situation="$4"
  local outcome="${5:-}"
  local affect="${6:-}"

  # Ensure the database and schema exist before inserting. Idempotent.
  attachments:ensure "$project"

  local db
  db="$(attachments:db-path "$project")"

  local q_proj q_slug q_round q_sit q_out q_aff
  q_proj="$(db:quote "$project")"
  q_slug="$(db:quote "$slug")"
  if [[ "$round" =~ ^[0-9]+$ ]]; then
    q_round="$round"
  else
    q_round="NULL"
  fi
  q_sit="$(db:quote "$situation")"
  if [[ -n "$outcome" ]]; then
    q_out="$(db:quote "$outcome")"
  else
    q_out="NULL"
  fi
  if [[ -n "$affect" ]]; then
    q_aff="$(db:quote "$affect")"
  else
    q_aff="NULL"
  fi

  # INSERT ... RETURNING atomically inserts and prints the new id in a
  # single sqlite3 invocation. Required because db:exec and db:query each
  # open their own connection, so last_insert_rowid() in a follow-up
  # query would be 0 (new session).
  db:query "$db" "
    INSERT INTO substrate_events (kind, project, conversation_slug, round_index, situation, outcome, affect)
    VALUES ('turn', $q_proj, $q_slug, $q_round, $q_sit, $q_out, $q_aff)
    RETURNING id;
  "
}

export -f attachments:record-turn

#-------------------------------------------------------------------------------
# attachments:decay PROJECT_NAME
#
# Reduce `health` on stale or low-confidence attachments. Phase 1 stub —
# no attachments exist yet to decay. Wired in so scheduled callers can
# invoke this unconditionally from day one.
#-------------------------------------------------------------------------------
attachments:decay() {
  # Phase 1: no-op. Implementation lands with attachment minting in a
  # later phase.
  return 0
}

export -f attachments:decay

#-------------------------------------------------------------------------------
# attachments:shape-signature EMBEDDING_JSON
#
# Produce a stable, embedder-dependent key that approximately identifies
# "the same tendency" across projects. Implementation is sign-quantization
# of the embedding followed by a SHA-256 prefix — cheap, deterministic,
# and sensitive only to the embedding's orientation (not magnitude).
#
# This is a prefilter for cross-project dedup; true identity is confirmed
# by cosine similarity against the prediction_embedding in the global DB.
# Two attachments with the same signature have very similar orientations;
# two with different signatures may still be similar in cosine but are
# likely to be different tendencies.
#
# Invariant: same embedding ⇒ same signature. Embedder swap ⇒ all
# signatures change, which is a deliberate break (documented in the plan).
#-------------------------------------------------------------------------------
attachments:shape-signature() {
  local embedding="$1"

  # Sign-quantize: 1 bit per dim (>=0 → '1', else '0'). Concat into a
  # bit-string, hash, truncate. Done in awk so we don't pay per-float
  # shell overhead on 384 dims.
  local bits
  bits="$(awk -v emb="$embedding" 'BEGIN {
    gsub(/[\[\]]/, "", emb)
    n = split(emb, a, ",")
    s = ""
    for (i = 1; i <= n; i++) {
      s = s ((a[i] + 0 >= 0) ? "1" : "0")
    }
    print s
  }')"

  printf '%s' "$bits" | sha256sum | cut -c1-12
}

export -f attachments:shape-signature

#-------------------------------------------------------------------------------
# attachments:seed PROJECT_NAME PREDICTION EMBEDDING INNER_VOICE AFFECT [CONFIDENCE]
#
# Insert an attachment by fiat — bypassing the normal mint-from-cluster
# path. Intended for test fixtures and Phase 2 dogfooding: seed a handful
# of attachments to verify the firing + priming pipeline end-to-end before
# consolidation lands.
#
# AFFECT must be in the controlled vocab (see attachments:affect-vocab).
# CONFIDENCE defaults to 0.5.
#
# Prints the new attachment id.
#-------------------------------------------------------------------------------
attachments:seed() {
  local project="$1"
  local prediction="$2"
  local embedding="$3"
  local inner_voice="$4"
  local affect="$5"
  local confidence="${6:-0.5}"

  if ! attachments:affect-valid "$affect"; then
    die "attachments:seed: invalid affect '$affect' (must be one of: $_ATTACHMENTS_AFFECT_VOCAB)"
    return 1
  fi

  attachments:ensure "$project"

  local db
  db="$(attachments:db-path "$project")"

  local sig
  sig="$(attachments:shape-signature "$embedding")"

  local q_sig q_pred q_emb q_voice q_affect
  q_sig="$(db:quote "$sig")"
  q_pred="$(db:quote "$prediction")"
  q_emb="$(db:quote "$embedding")"
  q_voice="$(db:quote "$inner_voice")"
  q_affect="$(db:quote "$affect")"

  db:query "$db" "
    INSERT INTO attachments (shape_signature, prediction, prediction_embedding, inner_voice, affect, confidence)
    VALUES ($q_sig, $q_pred, $q_emb, $q_voice, $q_affect, $confidence)
    RETURNING id;
  "
}

export -f attachments:seed

#-------------------------------------------------------------------------------
# attachments:fire PROJECT_NAME SITUATION_EMBEDDING [TOP_K]
#
# Cosine-rank the situation against all live attachments (health > 0.3,
# embedding present), take the top K, log a fire for each, and print the
# matches as a JSON array:
#
#   [{id, prediction, inner_voice, affect, confidence, health, score}, ...]
#
# SITUATION_EMBEDDING is an already-embedded JSON vector; callers that
# start from text should embed via search:embed first. Keeping firing
# embedding-agnostic lets callers choose when to pay the embedding cost
# (and lets tests inject hand-crafted vectors without booting elixir).
#
# Default TOP_K: 5.
#
# If no attachments are live or ranking yields nothing, prints '[]' and
# returns 0 (the empty case is normal, not an error).
#-------------------------------------------------------------------------------
attachments:fire() {
  local project="$1"
  local embedding="$2"
  local top_k="${3:-5}"

  attachments:ensure "$project"

  local db
  db="$(attachments:db-path "$project")"

  # Bail early if there's nothing to cosine against. The query below
  # counts live attachments with embeddings present.
  local count
  count="$(db:query "$db" "
    SELECT count(*)
    FROM attachments
    WHERE health > 0.3 AND prediction_embedding IS NOT NULL;
  ")"
  if [[ -z "$count" || "$count" -eq 0 ]]; then
    printf '[]'
    return 0
  fi

  local ranked
  ranked="$(
    db:query "$db" "
      SELECT id, prediction_embedding
      FROM attachments
      WHERE health > 0.3 AND prediction_embedding IS NOT NULL;
    " \
      | awk -v needle="$embedding" -v top_k="$top_k" -f "$_ATTACHMENTS_COSINE_RANK"
  )"

  if [[ -z "$ranked" ]]; then
    printf '[]'
    return 0
  fi

  # For each (score, id), log a fire and fetch the attachment's
  # user-facing fields. Builds a JSON object per match; jq -s at the end
  # slurps the stream of objects into a single array.
  {
    while IFS=$'\t' read -r score aid; do
      [[ -z "$aid" ]] && continue

      local q_emb
      q_emb="$(db:quote "$embedding")"

      db:exec "$db" "
        INSERT INTO attachment_fires (attachment_id, situation_embedding)
        VALUES ($aid, $q_emb);
        UPDATE attachments
           SET fire_count = fire_count + 1,
               last_fired_at = datetime('now'),
               updated_at = datetime('now')
         WHERE id = $aid;
      "

      local row
      row="$(db:query-json "$db" "
        SELECT id, prediction, inner_voice, affect, confidence, health
        FROM attachments
        WHERE id = $aid;
      ")"

      jq -c --arg score "$score" '.[0] + {score: ($score | tonumber)}' <<< "$row"
    done <<< "$ranked"
  } | jq -sc '.'
}

export -f attachments:fire

#-------------------------------------------------------------------------------
# attachments:list PROJECT_NAME
#
# Print a human-scannable table of attachments ordered by
# (confidence * health) descending. Tab-delimited, one row per line, with
# a header line. Used by `scratch attachments list`.
#-------------------------------------------------------------------------------
attachments:list() {
  local project="$1"

  attachments:ensure "$project"
  local db
  db="$(attachments:db-path "$project")"

  printf 'ID\tSCORE\tAFFECT\tSCOPE\tFIRES\tPREDICTION\n'

  db:query "$db" "
    SELECT id,
           printf('%.2f', confidence * health) AS score,
           affect,
           scope,
           fire_count,
           substr(prediction, 1, 80) AS prediction
    FROM attachments
    ORDER BY confidence * health DESC, id ASC;
  "
}

export -f attachments:list

#-------------------------------------------------------------------------------
# attachments:show PROJECT_NAME ID
#
# Print a single attachment as pretty JSON, including its provenance.
# Returns 1 if the attachment does not exist.
#-------------------------------------------------------------------------------
attachments:show() {
  local project="$1"
  local id="$2"

  attachments:ensure "$project"
  local db
  db="$(attachments:db-path "$project")"

  # sanity: id must be an integer
  if [[ ! "$id" =~ ^[0-9]+$ ]]; then
    die "attachments:show: id must be an integer, got '$id'"
    return 1
  fi

  local row
  row="$(db:query-json "$db" "
    SELECT id, shape_signature, prediction, inner_voice, affect,
           confidence, fire_count, confirm_count, disconfirm_count,
           scope, health, last_fired_at, created_at, updated_at
    FROM attachments
    WHERE id = $id;
  ")"

  if [[ "$row" == "[]" ]]; then
    return 1
  fi

  local provenance
  provenance="$(db:query-json "$db" "
    SELECT kind, ref_id, weight
    FROM attachment_provenance
    WHERE attachment_id = $id
    ORDER BY kind, ref_id;
  ")"

  jq --argjson prov "$provenance" '.[0] + {provenance: $prov}' <<< "$row"
}

export -f attachments:show

#-------------------------------------------------------------------------------
# attachments:format-priming FIRED_JSON
#
# Format a fired-attachments JSON array (as produced by attachments:fire)
# into the structured priming block the coordinator system prompt expects.
# Prints nothing if the array is empty. See
# data/prompts/coordinator/attachments-preamble.md for how the coordinator
# is taught to read it.
#
# Example output:
#
#   ## Priming (from attachments, not facts — tendencies that may be wrong)
#   Texture: mostly wary, threads of curious
#   - [wary, 0.62] in situations like X, user likely wants Y → don't pad
#   - [curious, 0.55] ...
#
# Texture aggregation and tension-pair detection arrive in Phase 4;
# Phase 2 ships a basic "mostly X" texture only.
#-------------------------------------------------------------------------------
attachments:format-priming() {
  local fired="$1"

  local count
  count="$(jq 'length' <<< "$fired")"
  if [[ -z "$count" || "$count" -eq 0 ]]; then
    return 0
  fi

  # Dominant affect: most common affect tag in the fired set
  local dominant
  dominant="$(jq -r '
    group_by(.affect)
    | map({affect: .[0].affect, n: length})
    | sort_by(-.n)
    | .[0].affect
  ' <<< "$fired")"

  printf '## Priming (from attachments, not facts — tendencies that may be wrong)\n'
  printf 'Texture: mostly %s\n' "$dominant"

  jq -r '
    .[]
    | "- [\(.affect), \(.score | tostring | .[0:4])] \(.prediction) → \(.inner_voice)"
  ' <<< "$fired"
}

export -f attachments:format-priming
