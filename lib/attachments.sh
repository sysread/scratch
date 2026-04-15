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
# Phase 1 (this file) implements only the substrate-recording primitives.
# Firing, consolidation, and learning arrive in later phases. See
# /root/.claude/plans/piped-prancing-cat.md for the full design.
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
