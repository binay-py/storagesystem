# Security policy

## Supported versions

Sanduk is currently maintained as a single rolling mainline. Report issues against the latest `main` branch state.

## Reporting a vulnerability

Please do **not** open public issues for suspected vulnerabilities.

Preferred path:

1. Use GitHub private vulnerability reporting for this repository (Security tab).
2. If private reporting is unavailable, contact the maintainer via GitHub profile: https://github.com/binay-py

Include:

- affected component (`src/worker.js`, `public/app.js`, setup flow, etc.)
- reproduction steps
- impact assessment
- suggested fix (if available)

## Scope and trust model reminders

Sanduk aims for browser-side encryption and ciphertext-only storage on Telegram, but it has **not** undergone a formal third-party security audit.

Users are responsible for safe key backup. If the chest key is lost, recovery is not possible.
