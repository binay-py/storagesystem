# Security policy

## Reporting a vulnerability

Please do **not** disclose vulnerabilities publicly in issues, pull requests, or discussions before maintainers have time to respond.

Preferred reporting path:

1. Open a private GitHub security advisory for this repository (Security tab), if available.
2. If private advisories are unavailable, contact the maintainer through the public GitHub profile: <https://github.com/binay-py>

## What to include

Please include as much of the following as possible:

- affected commit/branch and deployment context
- vulnerability type and impact
- clear reproduction steps or proof of concept
- prerequisites/configuration needed to reproduce
- suggested mitigation (if known)

## Scope guidance

Security-sensitive areas include:

- `public/app.js` key derivation and encryption/decryption flows
- `src/worker.js` authentication, setup-route exposure, and Telegram routing
- `schema.sql` / migrations that affect metadata integrity or retention behavior

Thank you for helping keep Sanduk and its users safer.
