-- v2 -> v3 migration: adds content-hash dedupe. keeps all existing data.
-- run: wrangler d1 execute sanduk --remote --file=./migration-v3.sql
ALTER TABLE files ADD COLUMN content_hash TEXT;
CREATE INDEX IF NOT EXISTS idx_files_hash ON files(user_id, content_hash);
