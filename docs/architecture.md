# Sanduk architecture

## Overview

Sanduk is a browser-first encrypted media vault with three runtime components:

1. **Browser app** (`public/index.html`, `public/app.js`)
2. **Cloudflare Worker API + static asset host** (`src/worker.js`)
3. **Storage backends**
   - **Telegram bot + private channel**: encrypted file chunk storage
   - **Cloudflare D1**: metadata and chunk mapping

## Component responsibilities

### Browser app

- Generates/accepts user secret key
- Derives auth token and encryption key (HKDF)
- Encrypts/decrypts media and names (AES-GCM)
- Splits large files into chunks and uploads via API
- Handles search/sort UI, favorites, trash, albums, and PWA behavior

### Worker API

- Serves frontend assets for non-`/api/*` paths
- Authenticates API requests using bearer token hash
- Handles setup endpoints (`/api/setup/*`) only while `TG_CHAT_ID` is unset/`SETUP`
- Persists metadata in D1
- Streams encrypted chunks to/from Telegram APIs

### D1 schema

Core tables in `schema.sql`:

- `users`: user identity hash and created timestamp
- `files`: encrypted name fields + file metadata/status
- `chunks`: mapping of file chunks to Telegram file/message IDs + IV/size
- `albums`, `album_files`: encrypted album organization metadata

## Data flow

```text
[User file]
   |
   | (browser encrypts + chunks)
   v
PUT /api/files/:id/chunks/:idx?iv=... ---> Worker ---> Telegram sendDocument
   |                                              |
   |<----------- tg_file_id / message_id ---------|
   v
POST /api/files + POST /api/files/:id/complete ---> D1

Later read:
Browser -> Worker -> Telegram getFile/download -> Browser decrypt -> UI render
```

## Setup flow

1. Deploy Worker with `TG_CHAT_ID="SETUP"`
2. `setup.html` calls `/api/setup/status` and `/api/setup/chat-id`
3. Operator selects channel ID and updates `wrangler.toml`
4. Redeploy; setup endpoints automatically return 410 (closed)

## Operational constraints

- Chunk size target is 18 MB client-side to stay under Telegram download cap
- Timeline pagination is keyset-based (`<timestamp>_<id>`) for stable ordering
- Trash items are purged lazily after retention window

## Related docs

- Security model: [`security.md`](security.md)
- Roadmap: [`roadmap.md`](roadmap.md)
