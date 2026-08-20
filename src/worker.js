// sanduk worker v2
// files are encrypted in the browser BEFORE they reach this worker.
// this worker only ever sees ciphertext. it routes:
//   encrypted chunks + thumbs -> telegram (your bot, your private channel)
//   metadata, albums, flags   -> D1

const CHUNK_LIMIT = 20 * 1024 * 1024; // telegram getFile caps downloads at 20MB
const TRASH_TTL = 30 * 24 * 60 * 60 * 1000; // 30 days

const json = (data, status = 200) =>
  new Response(JSON.stringify(data), {
    status,
    headers: { 'content-type': 'application/json' },
  });

const err = (msg, status) => json({ error: msg }, status);

async function sha256hex(text) {
  const buf = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text));
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

// identity = sha256(bearer token). the token is derived client-side from the
// user's secret via HKDF; the server never sees the secret or the enc key.
async function auth(request) {
  const h = request.headers.get('authorization') || '';
  const m = h.match(/^Bearer ([a-f0-9]{64})$/);
  if (!m) return null;
  return sha256hex(m[1]);
}

// ---- telegram ----

async function tgSendDocument(env, bytes, filename) {
  const form = new FormData();
  form.append('chat_id', env.TG_CHAT_ID);
  form.append('disable_notification', 'true');
  form.append('document', new Blob([bytes], { type: 'application/octet-stream' }), filename);
  const res = await fetch(`https://api.telegram.org/bot${env.TG_BOT_TOKEN}/sendDocument`, {
    method: 'POST',
    body: form,
  });
  const data = await res.json();
  if (!data.ok) throw new Error(`telegram upload failed: ${data.description}`);
  return { fileId: data.result.document.file_id, messageId: data.result.message_id };
}

async function tgFetchFile(env, tgFileId) {
  const meta = await fetch(
    `https://api.telegram.org/bot${env.TG_BOT_TOKEN}/getFile?file_id=${encodeURIComponent(tgFileId)}`
  ).then((r) => r.json());
  if (!meta.ok) throw new Error(`telegram fetch failed: ${meta.description}`);
  const res = await fetch(
    `https://api.telegram.org/file/bot${env.TG_BOT_TOKEN}/${meta.result.file_path}`
  );
  if (!res.ok) throw new Error('telegram file download failed');
  return res;
}

async function tgDeleteMessage(env, messageId) {
  try {
    await fetch(
      `https://api.telegram.org/bot${env.TG_BOT_TOKEN}/deleteMessage?chat_id=${env.TG_CHAT_ID}&message_id=${messageId}`
    );
  } catch {}
}

// ---- entry ----

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (!url.pathname.startsWith('/api/')) {
      return env.ASSETS.fetch(request);
    }
    const userId = await auth(request);
    if (!userId) return err('missing or bad auth token', 401);
    try {
      return await route(request, env, url, userId);
    } catch (e) {
      return err(e.message || 'internal error', 500);
    }
  },
};

const FILE_COLS = `id, name_enc, name_iv, mime, size, chunk_count, has_thumb, thumb_iv,
  is_favorite, deleted_at, live_video_id, is_live_hidden, created_at`;

async function route(request, env, url, userId) {
  const path = url.pathname.replace(/^\/api/, '');
  const method = request.method;
  const now = Date.now();
  let m;

  // POST /hello -> upsert user (optionally gated by SETUP_CODE for NEW users)
  if (method === 'POST' && path === '/hello') {
    const existing = await env.DB.prepare('SELECT id FROM users WHERE id = ?')
      .bind(userId)
      .first();
    if (!existing && env.SETUP_CODE) {
      const invite = request.headers.get('x-invite') || '';
      if (invite !== env.SETUP_CODE)
        return json({ error: 'invite code required', code: 'invite_required' }, 403);
    }
    await env.DB.prepare('INSERT OR IGNORE INTO users (id, created_at) VALUES (?, ?)')
      .bind(userId, now)
      .run();
    return json({ ok: true });
  }

  // GET /files?view=active|trash
  if (method === 'GET' && path === '/files') {
    const view = url.searchParams.get('view') || 'active';
    if (view === 'trash') {
      // lazy purge of expired trash
      const { results: expired } = await env.DB.prepare(
        `SELECT id FROM files WHERE user_id = ? AND deleted_at IS NOT NULL AND deleted_at < ?`
      )
        .bind(userId, now - TRASH_TTL)
        .all();
      for (const f of expired) await destroyFile(env, f.id, userId);

      const { results } = await env.DB.prepare(
        `SELECT ${FILE_COLS} FROM files
         WHERE user_id = ? AND status = 'ready' AND deleted_at IS NOT NULL
         ORDER BY deleted_at DESC LIMIT 500`
      )
        .bind(userId)
        .all();
      return json({ files: results });
    }
    const { results } = await env.DB.prepare(
      `SELECT ${FILE_COLS} FROM files
       WHERE user_id = ? AND status = 'ready' AND deleted_at IS NULL AND is_live_hidden = 0
       ORDER BY created_at DESC LIMIT 1000`
    )
      .bind(userId)
      .all();
    return json({ files: results });
  }

  // POST /files -> create record
  if (method === 'POST' && path === '/files') {
    const { nameEnc, nameIv, mime, size, chunkCount, contentHash } = await request.json();
    if (!nameEnc || !nameIv || !mime || !size || !chunkCount) return err('missing fields', 400);
    const id = crypto.randomUUID();
    await env.DB.prepare(
      `INSERT INTO files (id, user_id, name_enc, name_iv, mime, size, chunk_count, content_hash, created_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`
    )
      .bind(id, userId, nameEnc, nameIv, mime, size, chunkCount, contentHash || null, now)
      .run();
    return json({ id });
  }

  // GET /hashes -> content hashes of everything already stored (for backup dedupe)
  if (method === 'GET' && path === '/hashes') {
    const { results } = await env.DB.prepare(
      `SELECT DISTINCT content_hash AS h FROM files
       WHERE user_id = ? AND content_hash IS NOT NULL AND deleted_at IS NULL AND status = 'ready'`
    )
      .bind(userId)
      .all();
    return json({ hashes: results.map((r) => r.h) });
  }

  // POST /files/bulk {action, fileIds} -> trash | restore | delete | favorite | unfavorite
  if (method === 'POST' && path === '/files/bulk') {
    const { action, fileIds } = await request.json();
    if (!Array.isArray(fileIds) || !fileIds.length) return err('missing fileIds', 400);
    const ids = fileIds.slice(0, 200);
    let done = 0;
    for (const fid of ids) {
      const f = await ownedFile(env, fid, userId);
      if (!f) continue;
      if (action === 'trash' || action === 'restore') {
        const val = action === 'trash' ? now : null;
        await env.DB.prepare('UPDATE files SET deleted_at = ? WHERE id = ?').bind(val, fid).run();
        if (f.live_video_id)
          await env.DB.prepare('UPDATE files SET deleted_at = ? WHERE id = ? AND user_id = ?')
            .bind(val, f.live_video_id, userId)
            .run();
      } else if (action === 'delete') {
        await destroyFile(env, fid, userId);
        if (f.live_video_id) await destroyFile(env, f.live_video_id, userId);
      } else if (action === 'favorite' || action === 'unfavorite') {
        await env.DB.prepare('UPDATE files SET is_favorite = ? WHERE id = ?')
          .bind(action === 'favorite' ? 1 : 0, fid)
          .run();
      } else {
        return err('bad action', 400);
      }
      done++;
    }
    return json({ ok: true, done });
  }

  // PUT /files/:id/chunks/:idx?iv=
  if ((m = path.match(/^\/files\/([\w-]+)\/chunks\/(\d+)$/)) && method === 'PUT') {
    const [, fileId, idxStr] = m;
    const iv = url.searchParams.get('iv');
    if (!iv) return err('missing iv', 400);
    const file = await ownedFile(env, fileId, userId);
    if (!file) return err('not found', 404);

    const bytes = await request.arrayBuffer();
    if (bytes.byteLength === 0) return err('empty chunk', 400);
    if (bytes.byteLength > CHUNK_LIMIT) return err(`chunk too large`, 413);

    const tg = await tgSendDocument(env, bytes, `${fileId}.${idxStr}.bin`);
    await env.DB.prepare(
      `INSERT OR REPLACE INTO chunks (file_id, idx, tg_file_id, tg_message_id, iv, size)
       VALUES (?, ?, ?, ?, ?, ?)`
    )
      .bind(fileId, Number(idxStr), tg.fileId, tg.messageId, iv, bytes.byteLength)
      .run();
    return json({ ok: true });
  }

  // POST /files/:id/complete
  if ((m = path.match(/^\/files\/([\w-]+)\/complete$/)) && method === 'POST') {
    const [, fileId] = m;
    const file = await ownedFile(env, fileId, userId);
    if (!file) return err('not found', 404);
    const row = await env.DB.prepare('SELECT COUNT(*) AS n FROM chunks WHERE file_id = ?')
      .bind(fileId)
      .first();
    if (row.n !== file.chunk_count)
      return err(`expected ${file.chunk_count} chunks, got ${row.n}`, 409);
    await env.DB.prepare("UPDATE files SET status = 'ready' WHERE id = ?").bind(fileId).run();
    return json({ ok: true });
  }

  // GET /files/:id -> meta + chunk map
  if ((m = path.match(/^\/files\/([\w-]+)$/)) && method === 'GET') {
    const [, fileId] = m;
    const file = await ownedFile(env, fileId, userId);
    if (!file) return err('not found', 404);
    const { results: chunks } = await env.DB.prepare(
      'SELECT idx, iv, size FROM chunks WHERE file_id = ? ORDER BY idx'
    )
      .bind(fileId)
      .all();
    return json({ file, chunks });
  }

  // GET /files/:id/chunks/:idx -> stream encrypted bytes
  if ((m = path.match(/^\/files\/([\w-]+)\/chunks\/(\d+)$/)) && method === 'GET') {
    const [, fileId, idxStr] = m;
    const file = await ownedFile(env, fileId, userId);
    if (!file) return err('not found', 404);
    const chunk = await env.DB.prepare(
      'SELECT tg_file_id, iv FROM chunks WHERE file_id = ? AND idx = ?'
    )
      .bind(fileId, Number(idxStr))
      .first();
    if (!chunk) return err('chunk not found', 404);
    const tgRes = await tgFetchFile(env, chunk.tg_file_id);
    return new Response(tgRes.body, {
      headers: {
        'content-type': 'application/octet-stream',
        'x-iv': chunk.iv,
        'cache-control': 'private, max-age=31536000, immutable',
      },
    });
  }

  // PUT /files/:id/thumb?iv=
  if ((m = path.match(/^\/files\/([\w-]+)\/thumb$/)) && method === 'PUT') {
    const [, fileId] = m;
    const iv = url.searchParams.get('iv');
    if (!iv) return err('missing iv', 400);
    const file = await ownedFile(env, fileId, userId);
    if (!file) return err('not found', 404);
    const bytes = await request.arrayBuffer();
    const tg = await tgSendDocument(env, bytes, `${fileId}.thumb.bin`);
    await env.DB.prepare(
      'UPDATE files SET has_thumb = 1, thumb_iv = ?, thumb_tg_file_id = ?, thumb_tg_message_id = ? WHERE id = ?'
    )
      .bind(iv, tg.fileId, tg.messageId, fileId)
      .run();
    return json({ ok: true });
  }

  // GET /files/:id/thumb
  if ((m = path.match(/^\/files\/([\w-]+)\/thumb$/)) && method === 'GET') {
    const [, fileId] = m;
    const file = await ownedFile(env, fileId, userId);
    if (!file || !file.has_thumb || !file.thumb_tg_file_id) return err('not found', 404);
    const tgRes = await tgFetchFile(env, file.thumb_tg_file_id);
    return new Response(tgRes.body, {
      headers: {
        'content-type': 'application/octet-stream',
        'x-iv': file.thumb_iv,
        'cache-control': 'private, max-age=31536000, immutable',
      },
    });
  }

  // POST /files/:id/favorite {value}
  if ((m = path.match(/^\/files\/([\w-]+)\/favorite$/)) && method === 'POST') {
    const [, fileId] = m;
    const { value } = await request.json();
    const file = await ownedFile(env, fileId, userId);
    if (!file) return err('not found', 404);
    await env.DB.prepare('UPDATE files SET is_favorite = ? WHERE id = ?')
      .bind(value ? 1 : 0, fileId)
      .run();
    return json({ ok: true });
  }

  // POST /files/:id/trash  |  /files/:id/restore
  if ((m = path.match(/^\/files\/([\w-]+)\/(trash|restore)$/)) && method === 'POST') {
    const [, fileId, action] = m;
    const file = await ownedFile(env, fileId, userId);
    if (!file) return err('not found', 404);
    const val = action === 'trash' ? now : null;
    await env.DB.prepare('UPDATE files SET deleted_at = ? WHERE id = ?').bind(val, fileId).run();
    if (file.live_video_id)
      await env.DB.prepare('UPDATE files SET deleted_at = ? WHERE id = ? AND user_id = ?')
        .bind(val, file.live_video_id, userId)
        .run();
    return json({ ok: true });
  }

  // POST /files/:id/live {videoId} -> pair a photo with its live-motion video
  if ((m = path.match(/^\/files\/([\w-]+)\/live$/)) && method === 'POST') {
    const [, photoId] = m;
    const { videoId } = await request.json();
    const photo = await ownedFile(env, photoId, userId);
    const video = await ownedFile(env, videoId, userId);
    if (!photo || !video) return err('not found', 404);
    await env.DB.batch([
      env.DB.prepare('UPDATE files SET live_video_id = ? WHERE id = ?').bind(videoId, photoId),
      env.DB.prepare('UPDATE files SET is_live_hidden = 1 WHERE id = ?').bind(videoId),
    ]);
    return json({ ok: true });
  }

  // DELETE /files/:id -> permanent
  if ((m = path.match(/^\/files\/([\w-]+)$/)) && method === 'DELETE') {
    const [, fileId] = m;
    const file = await ownedFile(env, fileId, userId);
    if (!file) return err('not found', 404);
    await destroyFile(env, fileId, userId);
    if (file.live_video_id) await destroyFile(env, file.live_video_id, userId);
    return json({ ok: true });
  }

  // ---- albums ----

  // GET /albums -> albums with counts and a cover file id
  if (method === 'GET' && path === '/albums') {
    const { results } = await env.DB.prepare(
      `SELECT a.id, a.name_enc, a.name_iv, a.created_at,
              COUNT(af.file_id) AS file_count,
              (SELECT af2.file_id FROM album_files af2
               JOIN files f2 ON f2.id = af2.file_id AND f2.deleted_at IS NULL AND f2.has_thumb = 1
               WHERE af2.album_id = a.id ORDER BY af2.added_at DESC LIMIT 1) AS cover_id
       FROM albums a
       LEFT JOIN album_files af ON af.album_id = a.id
       WHERE a.user_id = ?
       GROUP BY a.id
       ORDER BY a.created_at DESC`
    )
      .bind(userId)
      .all();
    return json({ albums: results });
  }

  // POST /albums {nameEnc, nameIv}
  if (method === 'POST' && path === '/albums') {
    const { nameEnc, nameIv } = await request.json();
    if (!nameEnc || !nameIv) return err('missing fields', 400);
    const id = crypto.randomUUID();
    await env.DB.prepare(
      'INSERT INTO albums (id, user_id, name_enc, name_iv, created_at) VALUES (?, ?, ?, ?, ?)'
    )
      .bind(id, userId, nameEnc, nameIv, now)
      .run();
    return json({ id });
  }

  // GET /albums/:id -> album meta + its files
  if ((m = path.match(/^\/albums\/([\w-]+)$/)) && method === 'GET') {
    const [, albumId] = m;
    const album = await ownedAlbum(env, albumId, userId);
    if (!album) return err('not found', 404);
    const { results: files } = await env.DB.prepare(
      `SELECT f.id, f.name_enc, f.name_iv, f.mime, f.size, f.chunk_count, f.has_thumb, f.thumb_iv,
              f.is_favorite, f.deleted_at, f.live_video_id, f.is_live_hidden, f.created_at
       FROM files f
       JOIN album_files af ON af.file_id = f.id
       WHERE af.album_id = ? AND f.user_id = ? AND f.deleted_at IS NULL AND f.status = 'ready'
       ORDER BY af.added_at DESC`
    )
      .bind(albumId, userId)
      .all();
    return json({ album, files });
  }

  // POST /albums/:id/add {fileIds} | /albums/:id/remove {fileIds}
  if ((m = path.match(/^\/albums\/([\w-]+)\/(add|remove)$/)) && method === 'POST') {
    const [, albumId, action] = m;
    const album = await ownedAlbum(env, albumId, userId);
    if (!album) return err('not found', 404);
    const { fileIds } = await request.json();
    if (!Array.isArray(fileIds) || !fileIds.length) return err('missing fileIds', 400);
    const stmts = [];
    for (const fid of fileIds.slice(0, 200)) {
      if (action === 'add') {
        const f = await ownedFile(env, fid, userId);
        if (f)
          stmts.push(
            env.DB.prepare(
              'INSERT OR IGNORE INTO album_files (album_id, file_id, added_at) VALUES (?, ?, ?)'
            ).bind(albumId, fid, now)
          );
      } else {
        stmts.push(
          env.DB.prepare('DELETE FROM album_files WHERE album_id = ? AND file_id = ?').bind(
            albumId,
            fid
          )
        );
      }
    }
    if (stmts.length) await env.DB.batch(stmts);
    return json({ ok: true });
  }

  // DELETE /albums/:id -> delete album only, files stay
  if ((m = path.match(/^\/albums\/([\w-]+)$/)) && method === 'DELETE') {
    const [, albumId] = m;
    const album = await ownedAlbum(env, albumId, userId);
    if (!album) return err('not found', 404);
    await env.DB.batch([
      env.DB.prepare('DELETE FROM album_files WHERE album_id = ?').bind(albumId),
      env.DB.prepare('DELETE FROM albums WHERE id = ?').bind(albumId),
    ]);
    return json({ ok: true });
  }

  return err('not found', 404);
}

// permanent removal: telegram messages, chunks, album links, row
async function destroyFile(env, fileId, userId) {
  const file = await ownedFile(env, fileId, userId);
  if (!file) return;
  const { results: chunks } = await env.DB.prepare(
    'SELECT tg_message_id FROM chunks WHERE file_id = ?'
  )
    .bind(fileId)
    .all();
  for (const c of chunks) if (c.tg_message_id) await tgDeleteMessage(env, c.tg_message_id);
  if (file.thumb_tg_message_id) await tgDeleteMessage(env, file.thumb_tg_message_id);
  await env.DB.batch([
    env.DB.prepare('DELETE FROM chunks WHERE file_id = ?').bind(fileId),
    env.DB.prepare('DELETE FROM album_files WHERE file_id = ?').bind(fileId),
    env.DB.prepare('DELETE FROM files WHERE id = ?').bind(fileId),
  ]);
}

async function ownedFile(env, fileId, userId) {
  return env.DB.prepare('SELECT * FROM files WHERE id = ? AND user_id = ?')
    .bind(fileId, userId)
    .first();
}

async function ownedAlbum(env, albumId, userId) {
  return env.DB.prepare('SELECT * FROM albums WHERE id = ? AND user_id = ?')
    .bind(albumId, userId)
    .first();
}
