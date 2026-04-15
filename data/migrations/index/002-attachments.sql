-- Attachments memory model (Phase 1: substrate only; later phases add
-- associations, attachments, provenance, and fires). See
-- /root/.claude/plans/piped-prancing-cat.md for the full design.
--
-- All tables live in the per-project index.db alongside `entries` so
-- migrations and backups stay coherent. The tables intentionally do NOT
-- foreign-key to `entries` — entries hard-delete, but substrate must
-- persist so attachments orphan-and-decay rather than cascade-vanish.

-- Episodic substrate. Raw observations the assistant makes during
-- interactions. Write-once, self-contained, never user-visible, never
-- user-deleted. `situation` is the ground-truth record; `conversation_slug`
-- and `round_index` are soft pointers only and may dangle if conversations
-- are edited or deleted.
CREATE TABLE substrate_events (
  id INTEGER PRIMARY KEY,
  kind TEXT NOT NULL,                   -- 'turn', 'tool_call', 'genesis_review'
  project TEXT NOT NULL,                -- redundant with DB location; eases future global merge
  conversation_slug TEXT,               -- soft pointer; may dangle
  round_index INTEGER,                  -- soft pointer; may dangle
  situation TEXT NOT NULL,              -- human-readable "what happened"
  situation_embedding TEXT,             -- 384-dim JSON array; nullable until embedded
  outcome TEXT,                         -- what the user reacted with / what worked
  affect TEXT,                          -- optional affect tag captured at record time
  created_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX idx_substrate_kind ON substrate_events(kind);
CREATE INDEX idx_substrate_created ON substrate_events(created_at);

-- Associations (edges) between pairs of substrate events. Pair+label is
-- the uniqueness key — the same pair may carry multiple labels over time
-- (ambivalent relations are real). `relation_vector` is reserved for a
-- future use case; Phase 1 leaves it nullable and unpopulated.
CREATE TABLE associations (
  id INTEGER PRIMARY KEY,
  a_id INTEGER NOT NULL,
  b_id INTEGER NOT NULL,
  relation_vector TEXT,                 -- reserved; not populated in MVP
  articulated_relation TEXT NOT NULL,   -- short LLM-written relation label
  relation_embedding TEXT NOT NULL,     -- embedding of the articulated label
  reinforcement INTEGER NOT NULL DEFAULT 1,
  last_reinforced_at TEXT NOT NULL DEFAULT (datetime('now')),
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  UNIQUE(a_id, b_id, articulated_relation),
  FOREIGN KEY (a_id) REFERENCES substrate_events(id) ON DELETE CASCADE,
  FOREIGN KEY (b_id) REFERENCES substrate_events(id) ON DELETE CASCADE
);

CREATE INDEX idx_associations_pair ON associations(a_id, b_id);

-- Attachments. Emerge from clusters of associations. Carry a prediction,
-- inner-voice self-talk, and a controlled-vocabulary affect tag. `health`
-- drifts downward via `attachments:decay` when an attachment goes stale
-- or loses its provenance (e.g., project deletion). `shape_signature` is
-- a stable key used to prefilter cross-project dedup; cosine over
-- prediction_embedding remains authoritative.
CREATE TABLE attachments (
  id INTEGER PRIMARY KEY,
  shape_signature TEXT NOT NULL,
  prediction TEXT NOT NULL,             -- "in situations like X, user likely wants Y"
  prediction_embedding TEXT NOT NULL,   -- 384-dim JSON array
  inner_voice TEXT NOT NULL,            -- silent self-talk when firing
  affect TEXT NOT NULL,                 -- controlled vocab only
  confidence REAL NOT NULL DEFAULT 0.5,
  fire_count INTEGER NOT NULL DEFAULT 0,
  confirm_count INTEGER NOT NULL DEFAULT 0,
  disconfirm_count INTEGER NOT NULL DEFAULT 0,
  scope TEXT NOT NULL DEFAULT 'project',-- 'project' | 'global_candidate' | 'global'
  health REAL NOT NULL DEFAULT 1.0,     -- 0..1; orphan decay drives this down
  last_fired_at TEXT,
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX idx_attachments_scope_health ON attachments(scope, health);
CREATE INDEX idx_attachments_signature ON attachments(shape_signature);

-- Provenance: which substrate events and associations back each
-- attachment. Only cascades on attachment delete — substrate and
-- associations remain even when an attachment is pruned.
CREATE TABLE attachment_provenance (
  attachment_id INTEGER NOT NULL,
  kind TEXT NOT NULL,                   -- 'substrate' | 'association'
  ref_id INTEGER NOT NULL,
  weight REAL NOT NULL DEFAULT 1.0,
  PRIMARY KEY (attachment_id, kind, ref_id),
  FOREIGN KEY (attachment_id) REFERENCES attachments(id) ON DELETE CASCADE
);

-- Fire log. Each entry is one moment an attachment primed the coordinator.
-- Feeds reinforcement, cross-project promotion, and observability.
CREATE TABLE attachment_fires (
  id INTEGER PRIMARY KEY,
  attachment_id INTEGER NOT NULL,
  fired_at TEXT NOT NULL DEFAULT (datetime('now')),
  situation_embedding TEXT,
  was_confirmed INTEGER,                -- 1/0/NULL (unresolved)
  FOREIGN KEY (attachment_id) REFERENCES attachments(id) ON DELETE CASCADE
);

CREATE INDEX idx_fires_attachment ON attachment_fires(attachment_id);
