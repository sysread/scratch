-- Cross-project attachments store — the "global" layer of the memory
-- model. Attachments start per-project and are promoted here when their
-- shape_signature is fired across multiple projects within a recent
-- window. See /root/.claude/plans/piped-prancing-cat.md (Phase 5).
--
-- Two tables:
--
--   global_attachments  Promoted tendencies, keyed by shape_signature.
--                       No FKs back to project DBs — those may not
--                       exist on disk anymore (project deletion).
--                       origin_project is a soft hint, not an integrity
--                       constraint.
--
--   global_fires        One row per fire in any project. Used by the
--                       promotion query ("how many distinct projects
--                       fired signature X in the last 30 days?").

CREATE TABLE global_attachments (
  id INTEGER PRIMARY KEY,
  shape_signature TEXT NOT NULL UNIQUE,
  prediction TEXT NOT NULL,
  prediction_embedding TEXT NOT NULL,
  inner_voice TEXT NOT NULL,
  affect TEXT NOT NULL,
  confidence REAL NOT NULL DEFAULT 0.5,
  fire_count INTEGER NOT NULL DEFAULT 0,
  scope TEXT NOT NULL DEFAULT 'global_candidate',   -- 'global_candidate' | 'global'
  health REAL NOT NULL DEFAULT 1.0,
  origin_project TEXT,                              -- soft pointer, not FK
  last_fired_at TEXT,
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX idx_global_attachments_scope ON global_attachments(scope);

CREATE TABLE global_fires (
  id INTEGER PRIMARY KEY,
  shape_signature TEXT NOT NULL,
  project TEXT NOT NULL,
  fired_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX idx_global_fires_signature ON global_fires(shape_signature);
CREATE INDEX idx_global_fires_fired_at ON global_fires(fired_at);
