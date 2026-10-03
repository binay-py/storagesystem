# Sanduk roadmap

This roadmap separates what is already present from potential next work.

## Shipped (current repository)

- [x] Browser-side AES-GCM encryption before upload
- [x] HKDF-derived auth/encryption split from user secret
- [x] Cloudflare Worker + D1 metadata API
- [x] Telegram ciphertext chunk storage
- [x] Timeline, favorites, albums, trash lifecycle
- [x] Backup dedupe via content hashes
- [x] Setup helper page for resolving Telegram channel ID
- [x] Optional chest-creation gate via `SETUP_CODE`

## Proposed (near-term ideas)

- [ ] Minimal automated tests for critical API/auth and setup behavior
- [ ] Safer key-backup UX guidance in app (copy/verify reminder flow)
- [ ] Optional encrypted export/import for metadata portability
- [ ] Better observability for operator errors (without exposing secrets)
- [ ] Additional deployment docs for custom domains and worker environments

## Proposed (longer-term exploration)

- [ ] Review feasibility of encrypted metadata minimization
- [ ] Evaluate optional integrity/audit logging strategy
- [ ] Assess chunk retry/backoff tuning for large first-time backups

> Proposed items are directional and not delivery guarantees.
