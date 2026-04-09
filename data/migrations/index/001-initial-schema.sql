-- Unified index entries. `type` discriminates file/commit/conversation/etc.
-- For files, `identifier` is the relative path from project root.
-- `content_sha` is SHA-256 of the raw content, used for change detection.
CREATE TABLE entries (
  id INTEGER PRIMARY KEY,
  type TEXT NOT NULL,
  identifier TEXT NOT NULL,
  content_sha TEXT NOT NULL,
  summary TEXT NOT NULL,
  embedding TEXT,
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at TEXT NOT NULL DEFAULT (datetime('now')),
  UNIQUE(type, identifier)
);

CREATE INDEX idx_entries_type ON entries(type);

-- Per-project metadata (e.g., last_indexed_at timestamp)
CREATE TABLE metadata (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
