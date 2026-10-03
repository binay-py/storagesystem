# Sanduk launch kit

Practical launch guidance for sharing Sanduk responsibly, without overstating security or deployment status.

## Positioning

### One-line pitch

Zero-knowledge personal photo vault using browser-side encryption, Cloudflare Workers, and Telegram storage.

### Tagline

Your private photo vault. Your key. Your infrastructure.

### Product paragraph

Sanduk is a self-hosted photo and video vault. Files are encrypted in the browser before upload, Cloudflare Workers route encrypted chunks, and Telegram stores ciphertext. The user keeps the key; key loss means recovery is not possible.

## Claims to avoid

Do **not** claim:

- unhackable / bulletproof / perfect privacy
- formal security certification or audit
- guaranteed performance numbers for all users
- deployment completed for all environments

## Launch readiness checklist

Before posting publicly:

- [ ] README quick start was tested from a clean environment
- [ ] `docs/deployment-verification.md` checklist completed
- [ ] key-loss warning is visible in README
- [ ] setup route behavior (`TG_CHAT_ID = "SETUP"`) verified
- [ ] at least one screenshot or GIF in repo (currently `docs/sanduk-flow.gif`)
- [ ] community files are present and linked

## Suggested launch post (editable)

### Reddit / Indie Hackers

**Title:**

> I built a zero-knowledge photo vault using Cloudflare Workers and Telegram

**Body:**

> I built Sanduk, a self-hosted photo and video vault for private backups.
>
> - Files are encrypted in the browser before upload.
> - Cloudflare Workers route encrypted chunks.
> - Telegram stores ciphertext chunks.
> - D1 stores encrypted metadata.
> - The key stays with the user.
>
> It is early-stage and I’m looking for feedback on setup reliability, threat-model clarity, and backup/recovery workflow.
>
> Repo: https://github.com/binay-py/storagesystem

### Hacker News

**Title:**

> Show HN: Sanduk – zero-knowledge photo storage using Telegram and Cloudflare

**Body:**

> Sanduk is a self-hosted photo vault that encrypts files in the browser before they are uploaded. A Cloudflare Worker routes ciphertext to a private Telegram channel, while encrypted metadata is stored in D1.
>
> I’m looking for technical feedback on architecture limits, setup experience, and key management tradeoffs.

## Suggested social-share order

1. self-hosting communities
2. privacy communities
3. Cloudflare/dev communities
4. broader developer channels

## Reference docs

- [README](../README.md)
- [Deployment verification](./deployment-verification.md)
- [Contributing](../CONTRIBUTING.md)
- [Security policy](../SECURITY.md)
