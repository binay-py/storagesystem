# sanduk v3

your locked chest in the cloud. free unlimited photo/video storage:
telegram holds the bytes, cloudflare runs the app, your browser holds the only key.

everything (files, filenames, album names, thumbnails) is AES-GCM-256
encrypted in the browser before upload. the server and telegram only
ever see ciphertext. no accounts: a random secret key is your identity.

## features
- photos timeline grouped by date, videos tab, favorites, albums, trash (30-day purge)
- backup with dedupe: select your whole camera roll, already-stored files are skipped (sha-256 content hashing)
- multi-select everywhere: long-press (or the select button) then bulk favorite / trash / restore / delete / add-to-album
- search by filename + sort by newest / oldest / largest
- live photos: upload the .heic/.jpg + .mov pair together, press-and-hold in the viewer plays the motion
- slideshow mode in the viewer (space bar toggles on desktop)
- parallel encrypted transfers: 3-way chunk downloads, 2-way uploads
- android share target: share photos from any app straight into sanduk (after installing the pwa)
- optional invite gate: set a SETUP_CODE secret and only people with the code can create chests
- storage stats chip, ultrawide-aware layout, installable pwa, network-first service worker (updates land instantly)

## deploy / upgrade from v2 (keeps your data)
```bash
wrangler d1 execute sanduk --remote --file=./migration-v3.sql
wrangler deploy
```

## fresh install
see schema.sql header for the reset commands, then wrangler deploy.

## optional invite gate
```bash
wrangler secret put SETUP_CODE     # any code you like
```
new chest creation then requires it. existing chests are unaffected. skip this entirely for open personal use.

## limits
| thing | limit | why |
|---|---|---|
| chunk size | 18MB | telegram bot getFile caps downloads at 20MB |
| single file size | unlimited | files are chunked |
| worker requests | 100k/day free | plenty for personal use |
| video playback | full download first | streaming (MSE) needs fragmented mp4, future work |

## rules for not losing your stuff
1. the key exists in at least 2 places you control
2. never delete the telegram channel or remove the bot from it
3. keep a second copy of irreplaceable stuff somewhere else
