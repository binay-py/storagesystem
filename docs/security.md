# Sanduk security model

This document describes Sanduk's **current** security properties based on the repository implementation. It is not a formal audit.

## Scope and design intent

Sanduk is built to keep media confidential from infrastructure operators by encrypting content in the browser before upload.

- Encryption/decryption happens client-side in `public/app.js` via WebCrypto (`AES-GCM`, key derivation via `HKDF`)
- Server logic in `src/worker.js` handles ciphertext routing and metadata persistence
- Telegram stores encrypted chunks and encrypted thumbnails

## Key handling

- A random user secret ("chest key") is the root credential.
- Browser derives:
  - `authToken` (sent as bearer token; server stores only SHA-256 hash in `users.id`)
  - `encKey` (AES-GCM key, not sent to server)
- Sanduk does **not** implement key escrow or key recovery.

## What is encrypted

Encrypted in browser before upload:

- file bytes/chunks
- filenames
- album names
- thumbnails

Stored server-side (D1) as metadata/ciphertext references:

- encrypted names (`name_enc`, `name_iv`)
- chunk map (`chunks` table Telegram file/message IDs, per-chunk IV, chunk sizes)
- media attributes and state flags (mime, size, favorites, trash status, timestamps)

## Trust boundaries

### Browser/device

Trusted for confidentiality. If device/session is compromised, plaintext and key material may be exposed.

### Cloudflare Worker

Not trusted with plaintext. Worker can observe:

- request timing and frequency
- ciphertext sizes and counts
- user token hash identity
- operational metadata needed for routing

### Telegram

Not trusted with plaintext. Telegram can observe:

- encrypted document objects/chunk sizes
- bot/channel metadata and traffic patterns

### D1 database

Not trusted with plaintext media. D1 stores encrypted fields plus operational metadata.

## Threat model notes

Sanduk helps against:

- casual/administrative inspection of server-side stored media content
- plaintext exposure from storage backend compromise alone (without client key)

Sanduk does not fully address:

- compromised client devices, browsers, or active sessions
- traffic analysis/metadata privacy
- malicious modified frontend delivery (no remote attestation)
- loss of key material

## Operational risks and backup guidance

- If chest key is lost: data is unrecoverable.
- If Telegram channel is deleted or bot access revoked: stored ciphertext may become unavailable.
- Keep key backups in at least two secure places.
- Maintain independent backups for irreplaceable media.

## Security-sensitive changes

Changes to cryptography, auth, setup endpoints, storage mapping, or data deletion behavior should receive extra review and targeted testing.

## Responsible disclosure

Please do **not** post suspected vulnerabilities publicly first.

1. Prefer a private GitHub security advisory for this repository (Security tab).
2. If private advisory is unavailable, contact the maintainer via public GitHub profile: <https://github.com/binay-py>
3. Include:
   - affected commit/branch/version
   - impact assessment
   - reproduction steps or proof of concept
   - suggested remediation (if available)
