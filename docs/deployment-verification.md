# Deployment verification and post-deployment checks

Use this checklist after every fresh deployment or major configuration change.

## 1) Safe configuration checklist

- [ ] `wrangler.toml` is local-only and not committed
- [ ] `database_id` in `wrangler.toml` matches the D1 database you created
- [ ] `TG_BOT_TOKEN` was set using `wrangler secret put TG_BOT_TOKEN` (not stored in docs/code)
- [ ] Telegram private channel exists and bot is admin
- [ ] You posted at least one message in the channel before channel-ID discovery
- [ ] During setup only: `TG_CHAT_ID = "SETUP"`
- [ ] After setup: replace `TG_CHAT_ID` with the real `-100...` channel ID and redeploy

## 2) Verify setup-mode behavior

While `TG_CHAT_ID = "SETUP"`:

- [ ] `GET /api/setup/status` returns an open/setup-ready response
- [ ] `GET /api/setup/chat-id` lists your target channel

After replacing `TG_CHAT_ID` with the real value and redeploying:

- [ ] `GET /api/setup/status` is closed (setup endpoints disabled)
- [ ] `GET /api/setup/chat-id` is closed (setup endpoints disabled)

This confirms setup routes are not left open after provisioning.

## 3) Smoke test checklist

- [ ] Open app URL and create a new chest
- [ ] Copy chest key into two secure backup locations
- [ ] Upload one photo and one video
- [ ] Refresh and verify both files still render
- [ ] Mark one file favorite, move to trash, restore it
- [ ] Create an album and add/remove at least one file
- [ ] Download a file and verify it opens correctly

## 4) Key backup checklist

- [ ] Keep at least two offline backups of the chest key
- [ ] Do not store the key in public notes, commits, or screenshots
- [ ] Verify you can re-open the chest key in a fresh/incognito browser session

## 5) Operational checks

- [ ] Review Worker logs for repeated Telegram API errors
- [ ] Confirm D1 schema was initialized from `schema.sql`
- [ ] If upgrading, apply migrations in sequence and redeploy

## 6) Incident response basics (no secrets in repo)

If a token or channel was misconfigured:

1. Rotate `TG_BOT_TOKEN` in Telegram/BotFather.
2. Update secret with `wrangler secret put TG_BOT_TOKEN`.
3. Redeploy and re-run smoke tests.
4. Ensure no credentials were committed.
