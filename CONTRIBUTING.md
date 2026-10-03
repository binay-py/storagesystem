# Contributing to Sanduk

Thanks for helping improve Sanduk.

## Before you start

- Read [README.md](README.md) and relevant docs in [`docs/`](docs/README.md)
- Search existing issues/PRs before opening a new one
- Keep changes focused and minimal

## Development notes

Sanduk is a Cloudflare Worker + static frontend project.

- Worker entry: `src/worker.js`
- Frontend app: `public/app.js`
- Database schema: `schema.sql`
- Migrations: `migration-v3.sql`, `src/migration-v4.sql`

## Local validation expectations

For documentation-only changes:

- verify markdown links and paths still resolve

For code changes:

- run syntax checks (for example: `node --check src/worker.js`)
- manually smoke-test impacted flows

## Pull request checklist

- [ ] Changes are scoped to the issue
- [ ] No secrets were added to tracked files
- [ ] Docs were updated when behavior/setup changed
- [ ] Migration/schema changes are clearly explained (if any)
