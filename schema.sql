-- sanduk d1 schema v3
-- fresh install / reset:
--   wrangler d1 execute sanduk --remote --command "DROP TABLE IF EXISTS album_files; DROP TABLE IF EXISTS albums; DROP TABLE IF EXISTS chunks; DROP TABLE IF EXISTS files; DROP TABLE IF EXISTS users;"
--   wrangler d1 execute sanduk --remote --file=./schema.sql

CREATE TABLE IF NOT EXISTS users (
  id TEXT PRIMARY KEY,            -- sha256 hex of the client auth token
  created_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS files (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL,
  name_enc TEXT NOT NULL,         -- base64 AES-GCM ciphertext of filename
  name_iv TEXT NOT NULL,
  mime TEXT NOT NULL,
  size INTEGER NOT NULL,          -- plaintext size in bytes
  chunk_count INTEGER NOT NULL,
  status TEXT NOT NULL DEFAULT 'uploading',  -- uploading | ready
  has_thumb INTEGER NOT NULL DEFAULT 0,
  thumb_iv TEXT,
  thumb_tg_file_id TEXT,          -- thumbnails live in telegram too
  thumb_tg_message_id INTEGER,
  is_favorite INTEGER NOT NULL DEFAULT 0,
  deleted_at INTEGER,             -- set = in trash; purged 30 days later
  live_video_id TEXT,             -- photo half of a live photo points at its video half
  is_live_hidden INTEGER NOT NULL DEFAULT 0,  -- video half hidden from timeline
  content_hash TEXT,              -- dedupe key so backups skip already-stored files
  created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_files_user ON files(user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_files_hash ON files(user_id, content_hash);

CREATE TABLE IF NOT EXISTS chunks (
  file_id TEXT NOT NULL,
  idx INTEGER NOT NULL,
  tg_file_id TEXT NOT NULL,
  tg_message_id INTEGER,
  iv TEXT NOT NULL,
  size INTEGER NOT NULL,
  PRIMARY KEY (file_id, idx)
);

CREATE TABLE IF NOT EXISTS albums (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL,
  name_enc TEXT NOT NULL,
  name_iv TEXT NOT NULL,
  created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_albums_user ON albums(user_id, created_at DESC);

CREATE TABLE IF NOT EXISTS album_files (
  album_id TEXT NOT NULL,
  file_id TEXT NOT NULL,
  added_at INTEGER NOT NULL,
  PRIMARY KEY (album_id, file_id)
);
