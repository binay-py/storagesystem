# sanduk

your locked chest in the cloud. a private photo and video library that runs on
infrastructure you own, for roughly nothing a month.

telegram holds the bytes. cloudflare runs the app. your browser holds the only key.

everything (files, filenames, album names, thumbnails) is AES-GCM-256 encrypted
in your browser before upload. the server and telegram only ever see ciphertext.
there are no accounts: a random secret key is your identity.

---

## what you need

| thing | cost | notes |
|---|---|---|
| a telegram account | free | for the bot and the private channel |
| a cloudflare account | free | workers + D1 both fit the free tier |
| node.js 18+ | free | only to run wrangler |

no credit card. no R2. no object storage bill.

## install

**1. get the code and the cli**

```bash
git clone https://github.com/YOUR-USERNAME/sanduk.git
cd sanduk
npm install -g wrangler
wrangler login
```

**2. create the database**

```bash
wrangler d1 create sanduk
```

it prints a `database_id`. paste it into `wrangler.toml`, replacing
`PASTE_YOUR_D1_ID_HERE`.

**3. create the tables**

```bash
wrangler d1 execute sanduk --remote --file=./schema.sql
```

**4. make a telegram bot**

message [@BotFather](https://t.me/botfather), send `/newbot`, follow the prompts.
he gives you a token. hand it to the worker:

```bash
wrangler secret put TG_BOT_TOKEN
```

**5. make a private channel**

in telegram: new channel, set it private, add your bot as an admin with permission
to post. then send any message in the channel, so the bot has seen something.

**6. deploy, then find your channel id**

```bash
wrangler deploy
```

open `https://your-worker.workers.dev/setup.html` and press **find my channel**.
it lists every channel your bot can see, with the id ready to copy. put that id in
`wrangler.toml`:

```toml
[vars]
TG_CHAT_ID = "-1001234567890"
```

**7. deploy again**

```bash
wrangler deploy
```

that's it. open the worker url, press **create a new chest**, and save the key it
gives you somewhere safe. the setup endpoints switch themselves off the moment
`TG_CHAT_ID` holds a real id.

## upgrading an existing install

```bash
wrangler d1 execute sanduk --remote --file=./migration-v3.sql
wrangler deploy
```

migrations keep your data. run them in order if you skipped versions.

---

## features

- photos timeline grouped by date, videos tab, favorites, albums, trash (30-day purge)
- backup with dedupe: select your whole camera roll, already-stored files are skipped (sha-256 content hashing)
- multi-select everywhere: long-press (or the select button) then bulk favorite / trash / restore / delete / add-to-album
- search by filename, sort by newest / oldest / largest
- live photos: upload the .heic/.jpg + .mov pair together, press-and-hold in the viewer plays the motion
- slideshow mode in the viewer (space bar toggles on desktop)
- parallel encrypted transfers: 3-way chunk downloads, 2-way uploads
- android share target: share photos from any app straight into sanduk (after installing the pwa)
- optional invite gate: set a `SETUP_CODE` secret and only people with the code can create chests
- installable pwa, network-first service worker, ultrawide-aware layout

## optional: lock down chest creation

if your worker url might get shared around:

```bash
wrangler secret put SETUP_CODE     # any code you like
```

new chests then require the code. existing chests are unaffected. skip this
entirely for personal use.

---

## how it works

```
browser                 worker                  telegram
  |                       |                        |
  |-- encrypt chunk ----->|                        |
  |   (AES-GCM, your key) |-- sendDocument ------->|  private channel
  |                       |                        |
  |                       |<-- file_id ------------|
  |                       |
  |                    [ D1 ] metadata only:
  |                    encrypted names, ivs, chunk map
```

the worker never holds your key and never sees plaintext. it is a router: chunks
to telegram, metadata to D1.

your identity is one 32-byte secret. HKDF derives two things from it: an auth
token (sent to the server, which stores only its sha-256) and an encryption key
(never leaves the browser). so the server cannot decrypt your files even if it
wanted to, and cannot recover your account if you lose the key.

## limits

| thing | limit | why |
|---|---|---|
| chunk size | 18MB | telegram's getFile caps downloads at 20MB |
| single file size | unlimited | files are chunked |
| library size | unlimited | the timeline pages 500 rows at a time |
| upload throughput | ~20 chunks/min | telegram's bot rate limit into one channel |
| worker requests | 100k/day free | plenty for one household |

the throughput limit is the one that bites: a large first backup takes hours.
later backups are fast, because dedupe skips everything already stored.

## rules for not losing your stuff

1. the key exists in at least two places you control
2. never delete the telegram channel or remove the bot from it
3. keep a second copy of irreplaceable things somewhere else

this is a chest only you can open. that also means only you can lose it.

## license

AGPL-3.0. run it, fork it, change it. if you run a modified version as a service
for other people, publish your changes.
