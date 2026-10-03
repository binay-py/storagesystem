# Contributing to Sanduk

Thanks for your interest in improving Sanduk.

## Before you start

- Read [`README.md`](README.md), [`docs/architecture.md`](docs/architecture.md), and [`docs/security.md`](docs/security.md)
- Search existing issues before opening a new one

## Local setup

```bash
git clone https://github.com/binay-py/storagesystem.git
cd storagesystem
npm install -g wrangler
wrangler login
cp wrangler.toml.example wrangler.toml
```

Then follow the setup steps in [`README.md`](README.md).

## How to propose a change

1. Open an issue (bug/feature) if the change is substantial
2. Fork and create a focused branch
3. Keep pull requests small and scoped
4. Update docs when behavior or setup expectations change
5. Submit a PR using the provided template

## Testing expectations

This repository currently does not include an automated unit/integration test suite.

When contributing:

- Run relevant existing commands (deploy/config/schema commands) only as needed
- Manually verify affected flows in the browser and Worker API
- Include clear reproduction/verification steps in your PR description

## Security-sensitive changes

Extra care is required for changes affecting:

- key derivation or encryption/decryption logic
- auth token handling
- setup endpoint exposure and closure behavior
- deletion/retention logic
- Telegram chunk mapping and retrieval

For vulnerabilities, follow [`SECURITY.md`](SECURITY.md) and avoid public exploit details.

## Community behavior

Please follow [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md).
