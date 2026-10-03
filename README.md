# Sanduk

A zero-knowledge personal photo and video vault using browser encryption, Cloudflare Workers, and Telegram storage.

- Browser encrypts files and metadata before upload (AES-GCM-256)
- Cloudflare Worker routes ciphertext and stores encrypted metadata in D1
- Telegram stores encrypted file chunks only
- No password reset flow: your generated chest key is your identity and recovery key

<p align="center">
  <img src="docs/sanduk-flow.gif" alt="A photo is encrypted in the browser, split into chunks, routed by a Cloudflare Worker into a private Telegram channel. The key never leaves the browser." width="100%">
</p>

> Repository name is `storagesystem`; product name is **Sanduk**.

## What you need

| Requirement | Why |
|---|---|
| Telegram account | Create the bot and private channel |
| Cloudflare account | Run Worker + D1 |
| Node.js 18+ | Install and run Wrangler CLI |

## Quick start

1. **Clone and install Wrangler**

```bash
git clone https://github.com/binay-py/storagesystem.git
cd storagesystem
npm install -g wrangler
wrangler login
```

2. **Create local config**

```bash
cp wrangler.toml.example wrangler.toml
```

3. **Create and initialize D1**

```bash
wrangler d1 create sanduk
wrangler d1 execute sanduk --remote --file=./schema.sql
```

Copy the returned `database_id` into your local `wrangler.toml`.

4. **Set Telegram bot token**

```bash
wrangler secret put TG_BOT_TOKEN
```

5. **Set setup mode, deploy, and discover channel ID**

Set this in `wrangler.toml`:

```toml
[vars]
TG_CHAT_ID = "SETUP"
```

Deploy:

```bash
wrangler deploy
```

Open `https://<your-worker>.workers.dev/setup.html` and use **Find My Channel**.

6. **Set real chat ID and deploy again**

```toml
[vars]
TG_CHAT_ID = "-1001234567890"
```

```bash
wrangler deploy
```

7. **Create your chest and back up your key**

Open your Worker URL, create a chest, and store the generated key in at least two secure places.

## Setup and trust boundaries

| Component | Can see plaintext file content? | Can see encrypted metadata blobs? | Holds your key? |
|---|---|---|---|
| Browser | Yes | Yes | Yes (local/session only) |
| Cloudflare Worker + D1 | No | Yes | No |
| Telegram channel | No | No (only encrypted chunks) | No |

`/api/setup/*` endpoints are intentionally open only while `TG_CHAT_ID` is unset or set to `"SETUP"`. After you set a real channel ID and redeploy, setup endpoints return closed responses.

## API highlights

All normal routes are under `/api` and require auth derived from your chest key.

| Route | Purpose |
|---|---|
| `POST /hello` | Create/update user (new users can be gated by `SETUP_CODE`) |
| `GET /files` | Paginated timeline |
| `POST /files` | Register file metadata |
| `PUT /files/:id/chunks/:idx` | Upload encrypted chunk |
| `POST /files/:id/complete` | Mark file ready after all chunks |
| `GET /hashes` | Return existing content hashes for dedupe |
| `POST /files/bulk` | Bulk favorite/trash/restore/delete/add-to-album |
| `GET/POST /albums` | List/create albums |
| `GET /setup/status` | Setup health while setup mode is open |
| `GET /setup/chat-id` | List channels visible to bot while setup mode is open |

## Limits and practical constraints

- Chunk uploads are capped at 20 MB each (`/src/worker.js` enforces Telegram getFile compatibility).
- Large backups are slower due to Telegram Bot API throughput limits.
- Losing the chest key means losing access.
- This project has no formal third-party security audit.

## Upgrades

If upgrading from older deployments, run migrations in order as needed:

```bash
wrangler d1 execute sanduk --remote --file=./migration-v3.sql
wrangler d1 execute sanduk --remote --file=./src/migration-v4.sql
wrangler deploy
```

## Troubleshooting

- **`setup is closed`**: Set `TG_CHAT_ID = "SETUP"` and redeploy.
- **No channels listed in setup**: Ensure bot is admin in your private channel and send a message in that channel first.
- **Unauthorized API responses**: Verify you are using the exact saved chest key from creation.
- **Upload stalls on large batches**: Retry later; Telegram API limits are burst-sensitive.

## Documentation

- [Documentation index](docs/README.md)
- [Launch kit](docs/launch-kit.md)
- [Deployment verification and post-deploy checks](docs/deployment-verification.md)
- [Contributing guide](CONTRIBUTING.md)
- [Security policy](SECURITY.md)
- [Changelog](CHANGELOG.md)

## License

AGPL-3.0. See [LICENSE](LICENSE).
