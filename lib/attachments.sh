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
  local project="$1"

  attachments:ensure "$project"
  local db
  db="$(attachments:db-path "$project")"

  # Two decay paths, both gentle:
  #
  # 1. Stale-fire decay: attachments that haven't fired recently bleed a
  #    little health. "Recently" is 60 days. The per-pass decrement is
  #    small (0.02) so a tendency that's simply on hiatus doesn't vanish
  #    between consolidations, but one the user has truly moved past
  #    dies out over many passes.
  #
  # 2. Low-reinforcement decay: attachments with more disconfirm than
  #    confirm events take a bigger hit (0.1) each pass. These are
  #    actively being proven wrong.
  #
  # Health is clamped to [0, 1]. Orphan-by-project-deletion is handled
  # separately in Phase 5's global sweep.
  db:exec "$db" "
    UPDATE attachments
       SET health = MAX(0.0, health - 0.02),
           updated_at = datetime('now')
     WHERE last_fired_at IS NULL
        OR last_fired_at < datetime('now', '-60 days');

    UPDATE attachments
       SET health = MAX(0.0, health - 0.1),
           updated_at = datetime('now')
     WHERE disconfirm_count > confirm_count
       AND disconfirm_count + confirm_count >= 3;
  "
}

export -f attachments:decay

#-------------------------------------------------------------------------------
# attachments:reinforce ATTACHMENT_ID OUTCOME
#
# OUTCOME is 'confirm' or 'disconfirm'. Bumps the corresponding counter,
# recomputes confidence via Laplace smoothing
# ((confirm + 1) / (confirm + disconfirm + 2)), resolves any unresolved
# fire rows for this attachment (setting was_confirmed = 0|1), and
# touches updated_at.
#
# Unknown OUTCOME is a no-op; callers that pass 'neutral' get a quiet
# return rather than a crash.
#-------------------------------------------------------------------------------
attachments:reinforce() {
  local aid="$1"
  local outcome="$2"

  if [[ ! "$aid" =~ ^[0-9]+$ ]]; then
    die "attachments:reinforce: id must be an integer, got '$aid'"
    return 1
  fi

  local project
  # Find the project by finding the DB that has this attachment. Callers
  # normally go through a fire-log loop that already knows the project;
  # we keep the signature simple by inferring it from ATTACHMENTS_DB (or
  # falling back — but callers must have called attachments:ensure with
  # the right project, so we just require a third arg.)
  project="${3:-${SCRATCH_PROJECT:-}}"
  if [[ -z "$project" ]]; then
    die "attachments:reinforce: project must be passed or SCRATCH_PROJECT set"
    return 1
  fi

  local db
  db="$(attachments:db-path "$project")"

  local col
  case "$outcome" in
    confirm) col="confirm_count" ;;
    disconfirm) col="disconfirm_count" ;;
    neutral | "") return 0 ;;
    *)
      die "attachments:reinforce: outcome must be confirm|disconfirm|neutral, got '$outcome'"
      return 1
      ;;
  esac

  local flag
  [[ "$outcome" == "confirm" ]] && flag=1 || flag=0

  db:exec "$db" "
    UPDATE attachments
       SET $col = $col + 1,
           confidence = CAST((confirm_count + 1 + CASE WHEN '$outcome' = 'confirm' THEN 1 ELSE 0 END)
                             AS REAL)
                       / (confirm_count + disconfirm_count + 3),
           updated_at = datetime('now')
     WHERE id = $aid;

    UPDATE attachment_fires
       SET was_confirmed = $flag
     WHERE attachment_id = $aid
       AND was_confirmed IS NULL
       AND fired_at > datetime('now', '-10 minutes');
  "
}

export -f attachments:reinforce

#-------------------------------------------------------------------------------
# attachments:classify-reaction TEXT
#
# Cheap heuristic classifier. Returns 'confirm', 'disconfirm', or
# 'neutral' based on the first satisfaction or correction token found in
# the text. Designed to be embarrassingly dumb — future phases can swap
# in a tiny classifier model.
#-------------------------------------------------------------------------------
attachments:classify-reaction() {
  local text="$1"
  local lower
  lower="$(printf '%s' "$text" | tr '[:upper:]' '[:lower:]')"

  # Disconfirmation beats confirmation if both present, because "no, but
  # thanks anyway" is still a disconfirm.
  local disconfirm_pat='\b(no|nope|actually|wait|but|nah|hmm|ugh|incorrect|wrong|that'"'"'s not)\b'
  local confirm_pat='\b(yes|yep|yeah|thanks|thank you|ok|okay|great|perfect|exactly|that'"'"'s it|nice|correct|right|got it|makes sense)\b'

  if [[ "$lower" =~ $disconfirm_pat ]]; then
    printf 'disconfirm'
  elif [[ "$lower" =~ $confirm_pat ]]; then
    printf 'confirm'
  else
    printf 'neutral'
  fi
}

export -f attachments:classify-reaction

#-------------------------------------------------------------------------------
# attachments:apply-reaction PROJECT TEXT
#
# Classify TEXT and apply the reaction to every attachment that fired in
# the last 10 minutes and doesn't yet have a resolution. Called at the
# start of each turn in scratch-chat to close the loop on the previous
# turn's fires. No-op if classification is 'neutral' — uncertain signal
# shouldn't move counters.
#-------------------------------------------------------------------------------
attachments:apply-reaction() {
  local project="$1"
  local text="$2"

  local outcome
  outcome="$(attachments:classify-reaction "$text")"
  [[ "$outcome" == "neutral" ]] && return 0

  attachments:ensure "$project"
  local db
  db="$(attachments:db-path "$project")"

  # Find distinct attachment_ids with unresolved fires in the window
  local ids
  ids="$(db:query "$db" "
    SELECT DISTINCT attachment_id
    FROM attachment_fires
    WHERE was_confirmed IS NULL
      AND fired_at > datetime('now', '-10 minutes');
  ")"

  [[ -z "$ids" ]] && return 0

  local aid
  while IFS= read -r aid; do
    [[ -z "$aid" ]] && continue
    attachments:reinforce "$aid" "$outcome" "$project"
  done <<< "$ids"
}

export -f attachments:apply-reaction

#-------------------------------------------------------------------------------
# attachments:associate PROJECT A_ID B_ID LABEL LABEL_EMBEDDING
#
# Upsert an association. If (a_id, b_id, articulated_relation) already
# exists, bump reinforcement and touch last_reinforced_at; otherwise
# insert. Prints the association id.
#-------------------------------------------------------------------------------
attachments:associate() {
  local project="$1"
  local a_id="$2"
  local b_id="$3"
  local label="$4"
  local embedding="$5"

  attachments:ensure "$project"
  local db
  db="$(attachments:db-path "$project")"

  local q_label q_emb
  q_label="$(db:quote "$label")"
  q_emb="$(db:quote "$embedding")"

  # ON CONFLICT bumps reinforcement. RETURNING id either way.
  db:query "$db" "
    INSERT INTO associations (a_id, b_id, articulated_relation, relation_embedding)
    VALUES ($a_id, $b_id, $q_label, $q_emb)
    ON CONFLICT(a_id, b_id, articulated_relation) DO UPDATE SET
      reinforcement = reinforcement + 1,
      last_reinforced_at = datetime('now')
    RETURNING id;
  "
}

export -f attachments:associate

#-------------------------------------------------------------------------------
# attachments:substrate-neighbors PROJECT [SINCE_TIMESTAMP] [TOP_K]
#
# For each substrate row with a non-null embedding and created_at >=
# SINCE_TIMESTAMP (default: all), find its top-K nearest neighbors (by
# cosine) among ALL embedded substrate rows. Prints tab-delimited pairs
# one per line: a_id<TAB>b_id (a_id < b_id, deduped across directions).
#
# TOP_K defaults to 8 — enough to catch likely structural analogies
# without blowing up pair count on a full-project sweep.
#-------------------------------------------------------------------------------
attachments:substrate-neighbors() {
  local project="$1"
  local since="${2:-}"
  local top_k="${3:-8}"

  attachments:ensure "$project"
  local db
  db="$(attachments:db-path "$project")"

  local where=""
  if [[ -n "$since" ]]; then
    local q_since
    q_since="$(db:quote "$since")"
    where="AND created_at >= $q_since"
  fi

  # Pull all embedded substrate into a line-oriented corpus for cosine.
  local corpus
  corpus="$(db:query "$db" "
    SELECT id, situation_embedding
    FROM substrate_events
    WHERE situation_embedding IS NOT NULL;
  ")"
  [[ -z "$corpus" ]] && return 0

  # For each new-enough row, rank against the whole corpus and emit top
  # neighbors. The self-match is filtered at the end (a_id != b_id).
  local seeds
  seeds="$(db:query "$db" "
    SELECT id, situation_embedding
    FROM substrate_events
    WHERE situation_embedding IS NOT NULL
      $where;
  ")"
  [[ -z "$seeds" ]] && return 0

  local seed_id seed_emb
  while IFS=$'\t' read -r seed_id seed_emb; do
    [[ -z "$seed_id" ]] && continue
    # Use one-shot awk; corpus is small enough and this keeps the
    # implementation simple. Plan documents this as the Phase-6
    # optimization target (sqlite-vec / in-pool LSH).
    printf '%s' "$corpus" \
      | awk -v needle="$seed_emb" -v top_k="$((top_k + 1))" -f "$_ATTACHMENTS_COSINE_RANK" \
      | awk -F'\t' -v self="$seed_id" '$2 != self { print $2 }' \
      | while IFS= read -r neighbor; do
        [[ -z "$neighbor" ]] && continue
        # Emit with smaller id first, larger second, so de-dup later is
        # trivial.
        if ((seed_id < neighbor)); then
          printf '%s\t%s\n' "$seed_id" "$neighbor"
        else
          printf '%s\t%s\n' "$neighbor" "$seed_id"
        fi
      done
  done <<< "$seeds" \
    | sort -u
}

export -f attachments:substrate-neighbors

#-------------------------------------------------------------------------------
# attachments:substrate-get PROJECT ID
#
# Print a substrate row as a JSON object, or return 1 if missing.
#-------------------------------------------------------------------------------
attachments:substrate-get() {
  local project="$1"
  local id="$2"

  attachments:ensure "$project"
  local db
  db="$(attachments:db-path "$project")"

  [[ "$id" =~ ^[0-9]+$ ]] || {
    die "attachments:substrate-get: id must be integer"
    return 1
  }

  local row
  row="$(db:query-json "$db" "
    SELECT id, kind, conversation_slug, round_index, situation, outcome, affect
    FROM substrate_events
    WHERE id = $id;
  ")"

  [[ "$row" == "[]" ]] && return 1
  jq -c '.[0]' <<< "$row"
}

export -f attachments:substrate-get

#-------------------------------------------------------------------------------
# attachments:cluster-associations PROJECT [RADIUS]
#
# Greedy ball clustering over associations.relation_embedding. Each
# association is assigned to the nearest existing cluster seed within
# RADIUS (cosine distance), or becomes a new seed. Iterates by
# descending reinforcement so strong edges anchor clusters first.
#
# RADIUS is cosine-distance = 1 - cosine-similarity. Default 0.15.
#
# Emits one JSON object per cluster (on separate lines):
#   {
#     "association_ids": [...],
#     "total_reinforcement": N,
#     "centroid_embedding": [...],
#     "sample_labels": ["...", "...", "..."]
#   }
#-------------------------------------------------------------------------------
attachments:cluster-associations() {
  local project="$1"
  local radius="${2:-0.15}"

  attachments:ensure "$project"
  local db
  db="$(attachments:db-path "$project")"

  # Pull associations; body is id<TAB>reinforcement<TAB>label<TAB>embedding.
  local rows
  rows="$(db:query "$db" "
    SELECT id, reinforcement, articulated_relation, relation_embedding
    FROM associations
    WHERE relation_embedding IS NOT NULL
    ORDER BY reinforcement DESC, id ASC;
  ")"
  [[ -z "$rows" ]] && return 0

  # Feed to awk for clustering. The algorithm keeps cluster seeds in
  # memory (O(n·k) where k = number of clusters) and is good enough
  # up to ~10k associations.
  local sim_threshold
  sim_threshold="$(awk -v r="$radius" 'BEGIN { printf "%.6f", 1.0 - r }')"
  printf '%s\n' "$rows" | awk -F'\t' -v sim_threshold="$sim_threshold" '
    function parse_vec(s,   arr, clean, tmp, n, i) {
      clean = s
      gsub(/[\[\]\r]/, "", clean)
      n = split(clean, tmp, ",")
      for (i = 1; i <= n; i++) arr[i] = tmp[i] + 0
      return n
    }
    function cos_sim(av, bv, n,   i, dot, na, nb) {
      dot = 0; na = 0; nb = 0
      for (i = 1; i <= n; i++) {
        dot += av[i] * bv[i]
        na += av[i] * av[i]
        nb += bv[i] * bv[i]
      }
      return (na > 0 && nb > 0) ? dot / (sqrt(na) * sqrt(nb)) : 0
    }
    {
      id = $1; reinf = $2 + 0; label = $3; emb = $4
      delete hay
      ndim = parse_vec(emb, hay)

      best = -1; best_sim = -1
      for (c = 1; c <= ncluster; c++) {
        # seed_emb_c[c][i] held in flat array seed_n[c] + seed[c, i]
        if (seed_n[c] != ndim) continue
        delete seedv
        for (i = 1; i <= seed_n[c]; i++) seedv[i] = seed[c, i]
        s = cos_sim(hay, seedv, ndim)
        if (s > best_sim) { best_sim = s; best = c }
      }

      if (best > 0 && best_sim >= sim_threshold) {
        cluster_ids[best] = cluster_ids[best] "," id
        cluster_reinf[best] += reinf
        cluster_count[best] += 1
        if (cluster_samples[best] < 3) {
          cluster_sample_labels[best, cluster_samples[best]] = label
          cluster_samples[best] += 1
        }
      } else {
        ncluster += 1
        seed_n[ncluster] = ndim
        for (i = 1; i <= ndim; i++) seed[ncluster, i] = hay[i]
        cluster_ids[ncluster] = id
        cluster_reinf[ncluster] = reinf
        cluster_count[ncluster] = 1
        cluster_sample_labels[ncluster, 0] = label
        cluster_samples[ncluster] = 1
        # Stash the centroid embedding string for output
        cluster_centroid[ncluster] = emb
      }
    }
    END {
      for (c = 1; c <= ncluster; c++) {
        # Emit a JSON object. Quote-escape the sample labels.
        labels = ""
        for (i = 0; i < cluster_samples[c]; i++) {
          s = cluster_sample_labels[c, i]
          gsub(/\\/, "\\\\", s)
          gsub(/"/, "\\\"", s)
          if (labels != "") labels = labels ","
          labels = labels "\"" s "\""
        }
        printf "{\"association_ids\":[%s],\"total_reinforcement\":%d,\"count\":%d,\"centroid_embedding\":%s,\"sample_labels\":[%s]}\n",
          cluster_ids[c], cluster_reinf[c], cluster_count[c],
          cluster_centroid[c], labels
      }
    }
  '
}

export -f attachments:cluster-associations

#-------------------------------------------------------------------------------
# attachments:mint PROJECT PREDICTION EMBEDDING INNER_VOICE AFFECT CONFIDENCE \
#                  PROVENANCE_JSON
#
# Insert an attachment plus its provenance rows in a single pass. Like
# seed, but called from the consolidation helper after attachment-minter
# confirms a cluster. PROVENANCE_JSON is an array of
# {kind: "substrate"|"association", ref_id: N, weight: F}.
#
# Prints the new attachment id.
#-------------------------------------------------------------------------------
attachments:mint() {
  local project="$1"
  local prediction="$2"
  local embedding="$3"
  local inner_voice="$4"
  local affect="$5"
  local confidence="$6"
  local provenance="$7"

  if ! attachments:affect-valid "$affect"; then
    die "attachments:mint: invalid affect '$affect'"
    return 1
  fi

  local aid
  aid="$(attachments:seed "$project" "$prediction" "$embedding" "$inner_voice" "$affect" "$confidence")"

  local db
  db="$(attachments:db-path "$project")"

  # Insert each provenance row. Driven from jq so we don't have to
  # hand-parse JSON in bash.
  local inserts
  inserts="$(
    jq -r --argjson aid "$aid" '
      .[]
      | "INSERT INTO attachment_provenance (attachment_id, kind, ref_id, weight) VALUES ("
        + ($aid | tostring) + ", '"'"'" + .kind + "'"'"', "
        + (.ref_id | tostring) + ", " + (.weight | tostring) + ");"
    ' <<< "$provenance"
  )"

  if [[ -n "$inserts" ]]; then
    db:exec "$db" "$inserts"
  fi

  printf '%s' "$aid"
}

export -f attachments:mint

#-------------------------------------------------------------------------------
# attachments:signature-exists PROJECT SIGNATURE
#
# Returns 0 if any existing attachment has this shape_signature, 1
# otherwise. Used by the minter to avoid double-minting a cluster whose
# tendency is already captured.
#-------------------------------------------------------------------------------
attachments:signature-exists() {
  local project="$1"
  local sig="$2"

  attachments:ensure "$project"
  local db
  db="$(attachments:db-path "$project")"

  local q_sig
  q_sig="$(db:quote "$sig")"
  db:exists "$db" "SELECT 1 FROM attachments WHERE shape_signature = $q_sig;"
}

export -f attachments:signature-exists

#-------------------------------------------------------------------------------
# _attachments:run-agent AGENT INPUT_JSON
#
# Internal. Invokes an agent by name via bash (`agents/<name>/run`) with
# INPUT_JSON on stdin, returning stdout. Kept as a single helper so tests
# can override one function instead of a scattered set of invocations.
# Tests stub this by redefining agent:run or by setting
# SCRATCH_ATTACHMENTS_AGENT_CMD.
#-------------------------------------------------------------------------------
_attachments:run-agent() {
  local agent="$1"
  local input="$2"

  if [[ -n "${SCRATCH_ATTACHMENTS_AGENT_CMD:-}" ]]; then
    printf '%s' "$input" | "$SCRATCH_ATTACHMENTS_AGENT_CMD" "$agent"
    return
  fi

  # Lazy-source agent.sh so the test harness can override agent:run
  # without pulling the whole agent system into simpler test cases.
  if ! declare -F agent:run > /dev/null 2>&1; then
    # shellcheck source=/dev/null
    source "$_ATTACHMENTS_SCRIPTDIR/agent.sh"
  fi

  # agent:run inherits stdin from its caller, so we pipe the input in.
  printf '%s' "$input" | agent:run "$agent"
}

export -f _attachments:run-agent

#-------------------------------------------------------------------------------
# attachments:label-pair PROJECT A_ID B_ID
#
# Fetch substrate rows A_ID and B_ID, invoke the relator agent to label
# the relation, skip if 'orthogonal', otherwise embed the label and
# upsert the association. Prints the association id on success, or
# nothing (and returns 0) if the pair was filtered out.
#
# Errors invoking the relator or embedding the label are swallowed —
# a single failed pair must not abort the whole consolidation pass.
#-------------------------------------------------------------------------------
attachments:label-pair() {
  local project="$1"
  local a_id="$2"
  local b_id="$3"

  local a_row b_row
  a_row="$(attachments:substrate-get "$project" "$a_id" 2> /dev/null)" || return 0
  b_row="$(attachments:substrate-get "$project" "$b_id" 2> /dev/null)" || return 0

  local input
  input="$(jq -cn \
    --argjson a "$a_row" \
    --argjson b "$b_row" \
    '{a: $a, b: $b}')"

  local out
  if ! out="$(_attachments:run-agent relator "$input" 2> /dev/null)"; then
    return 0
  fi

  local kind label
  kind="$(jq -r '.kind // "orthogonal"' <<< "$out" 2> /dev/null)" || return 0
  label="$(jq -r '.label // empty' <<< "$out" 2> /dev/null)" || return 0

  [[ "$kind" == "orthogonal" || -z "$label" ]] && return 0

  # Embed the label. Lazy-source search.sh to stay consistent with
  # scratch-chat's non-mandatory-elixir posture.
  if ! declare -F search:embed > /dev/null 2>&1; then
    # shellcheck source=/dev/null
    if ! source "$_ATTACHMENTS_SCRIPTDIR/search.sh" 2> /dev/null; then
      return 0
    fi
  fi

  local embedding
  if ! embedding="$(search:embed "$label" 2> /dev/null)"; then
    return 0
  fi

  attachments:associate "$project" "$a_id" "$b_id" "$label" "$embedding"
}

export -f attachments:label-pair

#-------------------------------------------------------------------------------
# attachments:mint-cluster PROJECT CLUSTER_JSON MIN_COUNT MIN_REINFORCEMENT
#
# Given one cluster from attachments:cluster-associations, decide whether
# to mint an attachment. Filters applied before the agent is invoked:
#
#   - count < MIN_COUNT: skip (too small)
#   - total_reinforcement < MIN_REINFORCEMENT: skip (too weak)
#   - shape_signature of centroid already exists: skip (dup)
#
# On pass, enriches the cluster with up to 3 sample situations, calls
# the attachment-minter agent, and (on confirm) mints the attachment
# with provenance references to every substrate and association
# underlying the cluster.
#
# Prints the new attachment id on mint, empty on skip.
#-------------------------------------------------------------------------------
attachments:mint-cluster() {
  local project="$1"
  local cluster="$2"
  local min_count="${3:-3}"
  local min_reinforcement="${4:-5}"

  local count reinf
  count="$(jq -r '.count' <<< "$cluster")"
  reinf="$(jq -r '.total_reinforcement' <<< "$cluster")"
  [[ -z "$count" || "$count" -lt "$min_count" ]] && return 0
  [[ -z "$reinf" || "$reinf" -lt "$min_reinforcement" ]] && return 0

  local centroid
  centroid="$(jq -c '.centroid_embedding' <<< "$cluster")"
  local sig
  sig="$(attachments:shape-signature "$centroid")"

  if attachments:signature-exists "$project" "$sig"; then
    return 0
  fi

  # Gather up to 3 sample situations from the association endpoints for
  # extra context in the minter prompt. We don't need to be exhaustive
  # — the minter just needs enough flavor to judge coherence.
  local assoc_ids
  assoc_ids="$(jq -r '.association_ids | .[]' <<< "$cluster")"

  local db
  db="$(attachments:db-path "$project")"

  local samples
  samples="$(
    {
      local aid
      while IFS= read -r aid; do
        [[ -z "$aid" ]] && continue
        db:query "$db" "
          SELECT se.situation
          FROM associations a
          JOIN substrate_events se ON se.id IN (a.a_id, a.b_id)
          WHERE a.id = $aid
          LIMIT 2;
        "
      done <<< "$assoc_ids" | head -6
    } | jq -R . | jq -s 'unique | .[0:3]'
  )"

  local minter_input
  minter_input="$(jq -cn \
    --argjson labels "$(jq '.sample_labels' <<< "$cluster")" \
    --argjson sits "$samples" \
    --argjson count "$count" \
    --argjson reinf "$reinf" \
    '{sample_labels: $labels, sample_situations: $sits, count: $count, total_reinforcement: $reinf}')"

  local minter_out
  if ! minter_out="$(_attachments:run-agent attachment-minter "$minter_input" 2> /dev/null)"; then
    return 0
  fi

  local confirm
  confirm="$(jq -r '.confirm // false' <<< "$minter_out" 2> /dev/null)" || return 0
  [[ "$confirm" != "true" ]] && return 0

  local prediction inner_voice affect confidence
  prediction="$(jq -r '.prediction' <<< "$minter_out")"
  inner_voice="$(jq -r '.inner_voice' <<< "$minter_out")"
  affect="$(jq -r '.affect' <<< "$minter_out")"
  confidence="$(jq -r '.confidence' <<< "$minter_out")"

  if ! attachments:affect-valid "$affect"; then
    return 0
  fi

  # Build provenance: every substrate event + association in the cluster.
  local substrate_ids
  substrate_ids="$(
    {
      local aid
      while IFS= read -r aid; do
        [[ -z "$aid" ]] && continue
        db:query "$db" "SELECT a_id FROM associations WHERE id = $aid; SELECT b_id FROM associations WHERE id = $aid;"
      done <<< "$assoc_ids"
    } | sort -u
  )"

  local provenance
  provenance="$(
    {
      local sid
      while IFS= read -r sid; do
        [[ -z "$sid" ]] && continue
        jq -cn --argjson id "$sid" '{kind:"substrate", ref_id:$id, weight:1.0}'
      done <<< "$substrate_ids"

      local aid
      while IFS= read -r aid; do
        [[ -z "$aid" ]] && continue
        jq -cn --argjson id "$aid" '{kind:"association", ref_id:$id, weight:1.0}'
      done <<< "$assoc_ids"
    } | jq -sc '.'
  )"

  attachments:mint "$project" "$prediction" "$centroid" "$inner_voice" "$affect" "$confidence" "$provenance"
}

export -f attachments:mint-cluster

#-------------------------------------------------------------------------------
# attachments:embed-pending PROJECT
#
# Populate situation_embedding for any substrate_events rows that are
# missing one. Pipes rows through embed:pool (stateful elixir worker).
# If embedding fails or is unavailable, returns 0 — callers must tolerate
# situations where the substrate remains un-embedded and consolidation
# simply produces fewer associations that round.
#
# Prints 'ok embed-pending <N>' to stdout when N > 0 so the progress UI
# can tick.
#-------------------------------------------------------------------------------
attachments:embed-pending() {
  local project="$1"

  attachments:ensure "$project"
  local db
  db="$(attachments:db-path "$project")"

  # Lazy-source embed.sh. Degrade gracefully if elixir is missing.
  if ! declare -F embed:pool > /dev/null 2>&1; then
    # shellcheck source=/dev/null
    source "$_ATTACHMENTS_SCRIPTDIR/embed.sh" 2> /dev/null || return 0
  fi
  command -v elixir > /dev/null 2>&1 || return 0

  local rows
  rows="$(db:query "$db" "
    SELECT id, situation
    FROM substrate_events
    WHERE situation_embedding IS NULL;
  ")"
  [[ -z "$rows" ]] && return 0

  # Convert rows to JSONL for embed:pool ({id, text}), capture output.
  local input_jsonl
  input_jsonl="$(
    while IFS=$'\t' read -r sid text; do
      [[ -z "$sid" ]] && continue
      jq -cn --arg id "$sid" --arg text "$text" '{id: $id, text: $text}'
    done <<< "$rows"
  )"

  local output_jsonl
  if ! output_jsonl="$(printf '%s\n' "$input_jsonl" | embed:pool 4 2> /dev/null)"; then
    return 0
  fi

  local n=0
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    local sid emb
    sid="$(jq -r '.id' <<< "$line")"
    emb="$(jq -c '.embedding' <<< "$line")"
    [[ -z "$sid" || "$emb" == "null" ]] && continue

    local q_emb
    q_emb="$(db:quote "$emb")"
    db:exec "$db" "UPDATE substrate_events SET situation_embedding = $q_emb WHERE id = $sid;"
    n=$((n + 1))
  done <<< "$output_jsonl"

  [[ "$n" -gt 0 ]] && printf 'ok embed-pending %d\n' "$n"
  return 0
}

export -f attachments:embed-pending

#-------------------------------------------------------------------------------
# attachments:consolidate PROJECT [MIN_ASSOCIATIONS]
#
# Run the full consolidation pipeline once. Called during `scratch index`
# via helpers/index/consolidate-attachments. Emits progress lines to
# stdout; best-effort on every phase.
#
# Minting is gated by MIN_ASSOCIATIONS (default 50): below that the
# pool is too small to cluster without noise, so we skip the mint pass
# and just let substrate / associations accumulate until there's enough
# signal. This threshold is documented in the plan as a day-one guard
# against early bad attachments.
#
# Reads metadata.last_consolidation_at to scope pair discovery to new
# substrate; writes the new timestamp at the end.
#-------------------------------------------------------------------------------
attachments:consolidate() {
  local project="$1"
  local min_assoc="${2:-50}"

  attachments:ensure "$project"
  local db
  db="$(attachments:db-path "$project")"

  # 1. Embed outstanding substrate (no-op if elixir missing)
  attachments:embed-pending "$project" || true

  # 2. Pair discovery. Scope to substrate since last consolidation so we
  #    don't redo work. If there's no last_consolidation_at, do a full
  #    pass the first time.
  local since=""
  since="$(index:get-meta "$project" "last_consolidation_at" 2> /dev/null || true)"

  local pairs
  pairs="$(attachments:substrate-neighbors "$project" "$since" 8 2> /dev/null || true)"

  local pair_count=0
  if [[ -n "$pairs" ]]; then
    local a b
    while IFS=$'\t' read -r a b; do
      [[ -z "$a" || -z "$b" ]] && continue
      attachments:label-pair "$project" "$a" "$b" > /dev/null 2>&1 || true
      pair_count=$((pair_count + 1))
    done <<< "$pairs"
  fi
  printf 'ok pairs %d\n' "$pair_count"

  # 3. Clustering + minting. Gate on association count.
  local total_assoc
  total_assoc="$(db:query "$db" "SELECT count(*) FROM associations;")"
  total_assoc="${total_assoc:-0}"

  local minted=0
  if [[ "$total_assoc" -ge "$min_assoc" ]]; then
    local clusters
    clusters="$(attachments:cluster-associations "$project" 2> /dev/null || true)"
    if [[ -n "$clusters" ]]; then
      local cluster
      while IFS= read -r cluster; do
        [[ -z "$cluster" ]] && continue
        local aid
        aid="$(attachments:mint-cluster "$project" "$cluster" 2> /dev/null || true)"
        [[ -n "$aid" ]] && minted=$((minted + 1))
      done <<< "$clusters"
    fi
  fi
  printf 'ok mint %d\n' "$minted"

  # 4. Decay pass
  attachments:decay "$project" || true
  printf 'ok decay\n'

  # 5. Record timestamp
  index:set-meta "$project" "last_consolidation_at" "$(date -u +%Y-%m-%dT%H:%M:%S)"
  printf 'ok consolidation\n'
}

export -f attachments:consolidate

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

  # Texture components: dominant affect, optional secondary if it carries
  # at least 25% of the fires, and a tension line if any declared
  # opposing-pair appears in the set.
  local tallies
  tallies="$(jq -c '
    group_by(.affect)
    | map({affect: .[0].affect, n: length})
    | sort_by(-.n)
  ' <<< "$fired")"

  local dominant
  dominant="$(jq -r '.[0].affect' <<< "$tallies")"

  local secondary
  secondary="$(jq -r --argjson total "$count" '
    if length < 2 then empty
    elif (.[1].n / $total) < 0.25 then empty
    else .[1].affect
    end
  ' <<< "$tallies")"

  local tension
  tension="$(attachments:_detect-tension "$fired")"

  local texture="Texture: mostly $dominant"
  if [[ -n "$secondary" ]]; then
    texture="$texture, threads of $secondary"
  fi
  if [[ -n "$tension" ]]; then
    texture="$texture ($tension)"
  fi

  printf '## Priming (from attachments, not facts — tendencies that may be wrong)\n'
  printf '%s\n' "$texture"

  jq -r '
    .[]
    | "- [\(.affect), \(.score | tostring | .[0:4])] \(.prediction) → \(.inner_voice)"
  ' <<< "$fired"
}

export -f attachments:format-priming

# Declared tension pairs — opposing stances whose co-occurrence is
# always worth surfacing in the texture line. Space-separated
# "a:b" tokens; the caller iterates both directions.
_ATTACHMENTS_TENSION_PAIRS="wary:confident uneasy:eager resigned:curious"

#-------------------------------------------------------------------------------
# attachments:_detect-tension FIRED_JSON
#
# Return a string like "tension: X ↔ Y" if any declared tension pair has
# both members present in the fired set. Returns empty if no pair
# conflicts.
#-------------------------------------------------------------------------------
attachments:_detect-tension() {
  local fired="$1"

  local present
  present=" $(jq -r 'map(.affect) | unique | .[]' <<< "$fired" | tr '\n' ' ') "

  local pair a b
  for pair in $_ATTACHMENTS_TENSION_PAIRS; do
    a="${pair%%:*}"
    b="${pair##*:}"
    if [[ "$present" == *" $a "* && "$present" == *" $b "* ]]; then
      # First tension we find wins; one line is plenty.
      printf 'tension: %s ↔ %s' "$a" "$b"
      return 0
    fi
  done
  return 0
}

export -f attachments:_detect-tension

#-------------------------------------------------------------------------------
# attachments:fires PROJECT_NAME SINCE
#
# Print recent fires as a tab-delimited table:
#   FIRED_AT<TAB>ID<TAB>CONFIRMED<TAB>AFFECT<TAB>PREDICTION
#
# SINCE is a SQLite modifier like '-1 hour', '-30 minutes', '-1 day'.
# No since ("") means everything. The CONFIRMED column is 'yes', 'no',
# or '?' (unresolved). PREDICTION is truncated to 80 chars so the table
# stays scannable.
#-------------------------------------------------------------------------------
attachments:fires() {
  local project="$1"
  local since="${2:-}"

  attachments:ensure "$project"
  local db
  db="$(attachments:db-path "$project")"

  local where=""
  if [[ -n "$since" ]]; then
    local q_since
    q_since="$(db:quote "$since")"
    where="WHERE af.fired_at >= datetime('now', $q_since)"
  fi

  printf 'FIRED_AT\tID\tCONFIRMED\tAFFECT\tPREDICTION\n'

  db:query "$db" "
    SELECT af.fired_at,
           af.attachment_id,
           CASE
             WHEN af.was_confirmed IS NULL THEN '?'
             WHEN af.was_confirmed = 1 THEN 'yes'
             ELSE 'no'
           END AS confirmed,
           a.affect,
           substr(a.prediction, 1, 80) AS prediction
    FROM attachment_fires af
    JOIN attachments a ON a.id = af.attachment_id
    $where
    ORDER BY af.fired_at DESC;
  "
}

export -f attachments:fires

#-------------------------------------------------------------------------------
# attachments:setting PROJECT_NAME KEY [DEFAULT]
#
# Read a setting from the project's settings.json under
# .attachments.<key>. Returns DEFAULT (or empty) if the key is missing
# or the file is absent. Used by scratch-chat to find the firing
# timeout and feature flags.
#
# Examples:
#   attachments:setting myproject firing_timeout_ms 1500
#   attachments:setting myproject enabled true
#-------------------------------------------------------------------------------
attachments:setting() {
  local project="$1"
  local key="$2"
  local default="${3:-}"

  local settings_file
  settings_file="$(project:config-dir "$project" 2> /dev/null)/settings.json"
  if [[ ! -f "$settings_file" ]]; then
    printf '%s' "$default"
    return 0
  fi

  # Use an explicit null check instead of `// empty` because jq's //
  # treats the boolean literal `false` as missing, and `enabled: false`
  # is a perfectly valid setting we must honor.
  local value
  value="$(jq -r --arg k "$key" '
    if (.attachments // {})[$k] == null then empty
    else (.attachments[$k] | tostring)
    end
  ' "$settings_file" 2> /dev/null)" || value=""

  if [[ -z "$value" ]]; then
    printf '%s' "$default"
  else
    printf '%s' "$value"
  fi
}

export -f attachments:setting
