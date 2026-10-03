# Sanduk launch kit

This document is the quick-start launch plan for the Sanduk project. It is designed to help the project look polished, credible, and easy to understand for privacy-conscious users and self-hosters.

## 1. Core positioning

### Short pitch

Zero-knowledge personal photo vault using browser-side encryption, Cloudflare Workers, and Telegram storage.

### Tagline

Your private photo vault. Your key. Your infrastructure.

### One-paragraph description

Sanduk is a self-hosted, zero-knowledge photo and video library. Files are encrypted in the browser before upload, Cloudflare Workers route encrypted chunks, and Telegram stores the ciphertext. There are no traditional user accounts, and the storage model is designed to avoid a large object-storage bill.

### Why this is a strong GitHub story

- Clear problem: personal backup and private media storage
- Strong trust angle: encryption happens in the browser
- Great self-hosting story: uses Cloudflare free tiers and Telegram as storage
- Strong “bare minimum infrastructure” story: no object storage bill, no SaaS lock-in
- Easy to explain in plain English

## 2. Target audience

The project is most relevant to:

- privacy-conscious users
- self-hosters
- people seeking a Google Photos alternative
- photographers and families who want encrypted backups
- developers who want a simple architecture with realistic constraints

## 3. Repository framing

The repository is currently named `storagesystem`, but the product is `sanduk`.

Use the product name in public-facing content:

- Product: Sanduk
- Repository: `binay-py/storagesystem`
- Project description: “sanduk - your locked chest in the cloud”

This gives the project a memorable identity without hiding the actual GitHub location.

## 4. Repository metadata suggestions

These topics are useful and aligned with the current stack and product concept:

```text
sanduk
privacy
self-hosted
photo-backup
google-photos-alternative
zero-knowledge
client-side-encryption
cloudflare-workers
telegram
pwa
encrypted-storage
```

Avoid exaggerated or unsupported wording such as:

- “unhackable”
- “military-grade encryption”
- “perfect privacy”
- “completely secure”

Instead, keep language precise and grounded in the project’s actual properties.

## 5. Launch-ready positioning

### Product description for README and social posts

> Sanduk is a zero-knowledge personal photo and video vault. It encrypts files in the browser before they leave your device, routes encrypted data through Cloudflare Workers, and stores the raw chunks in a private Telegram channel. The key stays with the user.

### Friendly project summary

> A private photo library you control: encrypted in the browser, stored in Telegram, routed through Cloudflare, and kept self-hosted by design.

## 6. 30-day growth plan

### Week 1: credibility and trust

- finish the documentation polish
- clarify the threat model and key-loss warning
- add screenshots or a short demo GIF
- ensure installation steps work on a fresh machine
- confirm the README reads well for new users

### Week 2: onboarding and friction reduction

- document Telegram bot setup and Cloudflare Worker setup step by step
- add troubleshooting notes for common setup failures
- improve key backup and restore guidance
- add an issue template and contribution guide
- open a few small, useful issue discussions to show activity

### Week 3: social proof and public validation

- create a first release tag if the current state is stable enough
- add a clear changelog section
- ask a few early testers to validate the installation flow
- publish a short launch post to the right communities

### Week 4: public launch

- share the project in relevant Reddit communities
- post to Hacker News once the README feels polished
- cross-post to social accounts and developer communities
- answer setup questions quickly, especially on the first day

## 7. Launch posts

### Reddit / Indie Hackers version

Title:

> I built a zero-knowledge photo vault using Cloudflare Workers and Telegram

Body:

> I built Sanduk, a self-hosted photo and video vault for people who want private backups without paying for another object-storage service.
>
> The basic design is:
>
> - files are encrypted in the browser before upload
> - Cloudflare Workers route encrypted chunks
> - Telegram stores ciphertext
> - D1 stores encrypted metadata
> - the key stays in the browser and with the user
>
> This is not a SaaS product; it is designed to be inexpensive, private, and self-controlled.
>
> The project is still early, so I’m especially looking for feedback on:
>
> - setup difficulty
> - security documentation
> - backup and recovery flow
> - upload reliability
> - whether the Telegram-backed storage model feels practical
>
> Repo: https://github.com/binay-py/storagesystem
>
> I’d appreciate testing feedback more than empty stars. If the project is useful to you, a star helps others discover it too.

### Hacker News version

Title:

> Show HN: Sanduk – zero-knowledge photo storage using Telegram and Cloudflare

Body:

> Sanduk is a self-hosted photo and video vault that encrypts files in the browser before sending them to a Cloudflare Worker. The Worker routes ciphertext to a private Telegram channel, while D1 stores encrypted metadata.
>
> The goal is inexpensive private storage without an object-storage bill or a traditional account system.
>
> The important tradeoff is that the user owns the key: the server cannot decrypt the files, but the key cannot be recovered if it is lost.
>
> I’m looking for technical feedback on the architecture, threat model, and operational constraints — especially Telegram Bot API throughput and recovery workflows.

## 8. Specific “do not say” list

Avoid claims like:

- “fully secure”
- “bulletproof backup”
- “no risk”
- “industry-standard secure storage”
- “unbreakable encryption”
- “works for everyone”

Instead, use language like:

- “browser-side encryption”
- “zero-knowledge design”
- “ciphertext-only storage on Telegram”
- “key remains with the user”
- “not a formal security audit”
- “key loss can make data inaccessible”

## 9. What to highlight in the README before launching

These sections matter most:

1. Why Sanduk?
2. What is encrypted and what is not?
3. What data Cloudflare and Telegram can see
4. What the key-loss tradeoff is
5. What the product is good at
6. What it is not good at
7. Quick setup steps
8. Troubleshooting and known limits

If the README communicates these clearly, the project will feel far more serious and trustworthy.

## 10. Community and contributor expectations

Before launching publicly, make sure the repo includes:

- CONTRIBUTING.md
- SECURITY.md
- CODE_OF_CONDUCT.md
- issue templates for bug reports and feature requests
- a PR template
- a changelog that begins with an Unreleased section

These files make the project feel maintained, not just dumped on GitHub.

## 11. Product health checklist

Before sharing widely, verify all of the following:

- [ ] README is clear to a first-time reader
- [ ] setup steps are tested from a clean environment
- [ ] security model explains the trust boundaries accurately
- [ ] key loss warning is visible and plain
- [ ] project screenshots or GIF are included
- [ ] there is a clear way to ask questions or report bugs
- [ ] the repo has community guidelines and issue templates
- [ ] the launch materials are ready for public sharing

## 12. Best next action

The highest-value next improvement is to ship the polished documentation package and then launch with a small, honest, user-focused post.

Do not lead with “look at my amazing project.”

Lead with:

- privacy
- simplicity
- low cost
- browser-side encryption
- self-hosted control

That is the story that gets people to click and understand the idea quickly.

## 13. Suggested plan for social sharing

Use this order:

1. self-hosted communities
2. privacy communities
3. Cloudflare communities
4. general developer communities
5. Hacker News after the docs and onboarding are polished

This keeps the launch credible, reduces early confusion, and gives the intro post a better chance to be understood.

## 14. Final recommendation

Treat Sanduk as a serious privacy tool, not a quick script.

The strongest angle is:

> zero-knowledge personal photo storage that fits into a normal developer workflow and avoids object-storage costs.

That is the story most likely to be understandable, interesting, and shareable.

This project has a good core idea. The next step is not more complexity — it is polish, trust, and clear communication.
