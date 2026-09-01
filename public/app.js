// sanduk client v3
// everything sensitive happens in this browser:
//   - the secret key is generated here and never sent anywhere
//   - authToken (sent) and encKey (never leaves) derive from it via HKDF
//   - files, filenames, album names, thumbnails: AES-GCM encrypted pre-upload

const CHUNK = 18 * 1024 * 1024;      // under telegram's 20MB download cap
const HASH_LIMIT = 64 * 1024 * 1024; // sha256 files up to this, meta-hash beyond
const DL_CONCURRENCY = 3;            // parallel chunk downloads
const UL_CONCURRENCY = 2;            // parallel chunk uploads

const $ = (id) => document.getElementById(id);
const te = new TextEncoder();
const td = new TextDecoder();

// ---- state ----
const state = {
  tab: 'photos',            // photos | videos | albums | favorites | trash
  files: [],
  trash: [],
  albums: [],
  albumOpen: null,
  albumFiles: [],
  selecting: false,
  selectCtx: null,          // 'bulk' | 'trash' | 'album-add'
  selected: new Set(),
  sort: 'new',              // new | old | big
  query: '',
  loadingMore: false,       // true while later pages are still coming in
};
let refreshToken = 0;
let encKey = null;
let authToken = null;
let viewerList = [];
let viewerIndex = -1;
let viewerToken = 0;
let renderToken = 0;
let currentBlobUrl = null;
let slideshowOn = false;
let slideTimer = null;
let pendingShared = [];
const liveCache = new Map();   // photoId -> object url of live video
const thumbCache = new Map();  // fileId -> object url
const nameCache = new Map();   // fileId -> decrypted name

// ---- base64 / bytes ----
const b64 = (buf) => {
  const bytes = new Uint8Array(buf);
  let s = '';
  for (let i = 0; i < bytes.length; i += 0x8000)
    s += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
  return btoa(s);
};
const b64d = (s) => Uint8Array.from(atob(s), (c) => c.charCodeAt(0));
const b64u = (buf) => b64(buf).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
const b64ud = (s) => b64d(s.replace(/-/g, '+').replace(/_/g, '/'));
const hex = (buf) =>
  [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, '0')).join('');
const randIv = () => crypto.getRandomValues(new Uint8Array(12));

// ---- crypto ----
async function deriveKeys(secretStr) {
  const raw = b64ud(secretStr.trim());
  if (raw.length < 16) throw new Error('key too short');
  const km = await crypto.subtle.importKey('raw', raw, 'HKDF', false, ['deriveBits', 'deriveKey']);
  const salt = new Uint8Array(32);
  const authBits = await crypto.subtle.deriveBits(
    { name: 'HKDF', hash: 'SHA-256', salt, info: te.encode('sanduk/auth/v1') },
    km, 256
  );
  const key = await crypto.subtle.deriveKey(
    { name: 'HKDF', hash: 'SHA-256', salt, info: te.encode('sanduk/enc/v1') },
    km, { name: 'AES-GCM', length: 256 }, false, ['encrypt', 'decrypt']
  );
  return { authToken: hex(authBits), encKey: key };
}
const enc = (iv, data) => crypto.subtle.encrypt({ name: 'AES-GCM', iv }, encKey, data);
const dec = (iv, data) => crypto.subtle.decrypt({ name: 'AES-GCM', iv }, encKey, data);
const encStr = async (str, iv) => b64(await enc(iv, te.encode(str)));
const decStr = async (ct, ivB64) => td.decode(await dec(b64d(ivB64), b64d(ct)));

async function getName(f) {
  if (nameCache.has(f.id)) return nameCache.get(f.id);
  let name = 'file';
  try { name = await decStr(f.name_enc, f.name_iv); } catch {}
  nameCache.set(f.id, name);
  return name;
}

async function hashFile(file) {
  if (file.size <= HASH_LIMIT) {
    const digest = await crypto.subtle.digest('SHA-256', await file.arrayBuffer());
    return 'sha256:' + hex(digest);
  }
  return `meta:${file.size}:${file.lastModified}:${file.name}`;
}

// ---- api ----
async function api(method, path, body, extraHeaders) {
  const res = await fetch('/api' + path, {
    method,
    headers: {
      authorization: 'Bearer ' + authToken,
      ...(body ? { 'content-type': 'application/json' } : {}),
      ...(extraHeaders || {}),
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  if (!res.ok) {
    const data = await res.json().catch(() => ({}));
    const e = new Error(data.error || res.statusText);
    e.code = data.code;
    throw e;
  }
  return res.json();
}
async function apiRaw(method, path, bytes) {
  const res = await fetch('/api' + path, {
    method,
    headers: { authorization: 'Bearer ' + authToken },
    body: bytes,
  });
  if (!res.ok) throw new Error((await res.json().catch(() => ({}))).error || res.statusText);
  return res;
}

// ---- concurrency pool ----
async function pool(items, limit, worker) {
  const results = new Array(items.length);
  let next = 0;
  async function runner() {
    while (next < items.length) {
      const i = next++;
      results[i] = await worker(items[i], i);
    }
  }
  await Promise.all(Array.from({ length: Math.min(limit, items.length) }, runner));
  return results;
}

// ---- small ui ----
let toastTimer;
function toast(msg) {
  const t = $('toast');
  t.textContent = msg;
  t.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => (t.hidden = true), 2600);
}
function show(screen) {
  for (const id of ['screen-lock', 'screen-reveal', 'screen-app'])
    $(id).hidden = id !== screen;
}
function fmtSize(bytes) {
  if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(0) + ' KB';
  if (bytes < 1024 * 1024 * 1024) return (bytes / 1024 / 1024).toFixed(1) + ' MB';
  return (bytes / 1024 / 1024 / 1024).toFixed(2) + ' GB';
}
function dayLabel(ms) {
  const d = new Date(ms);
  const today = new Date();
  const yest = new Date(Date.now() - 86400000);
  const same = (a, b) => a.toDateString() === b.toDateString();
  if (same(d, today)) return 'today';
  if (same(d, yest)) return 'yesterday';
  const opts = { month: 'short', day: 'numeric' };
  if (d.getFullYear() !== today.getFullYear()) opts.year = 'numeric';
  return d.toLocaleDateString(undefined, opts).toLowerCase();
}

// ---- auth ----
async function unlock(secret, remember, invite) {
  const keys = await deriveKeys(secret);
  authToken = keys.authToken;
  encKey = keys.encKey;
  await api('POST', '/hello', null, invite ? { 'x-invite': invite } : undefined);
  if (remember) localStorage.setItem('sanduk.secret', secret);
  show('screen-app');
  await refresh();
  if (pendingShared.length) {
    const shared = pendingShared;
    pendingShared = [];
    toast(`received ${shared.length} shared file${shared.length === 1 ? '' : 's'}`);
    uploadFiles(shared);
  }
}
function lockApp() {
  localStorage.removeItem('sanduk.secret');
  location.reload();
}

// ---- data ----
// pull every page of a list. names are encrypted, so search and sort have to
// happen on the client, which means we need the whole set of metadata. we render
// the first page immediately and keep filling in behind it.
async function loadAllPages(view, onPage) {
  const out = [];
  let cursor = null;
  let guard = 0;
  do {
    const qs = new URLSearchParams({ view });
    if (cursor) qs.set('cursor', cursor);
    const res = await api('GET', `/files?${qs}`);
    out.push(...res.files);
    cursor = res.nextCursor || null;
    if (onPage) onPage(out, Boolean(cursor));
  } while (cursor && ++guard < 200);
  return out;
}

async function refresh() {
  const loadToken = ++refreshToken;
  const [firstFiles, { albums }] = await Promise.all([
    loadAllPages('active', (sofar, more) => {
      if (loadToken !== refreshToken) return;
      state.files = sofar;
      state.loadingMore = more;
      updateStats();
      render();
    }),
    api('GET', '/albums'),
  ]);
  if (loadToken !== refreshToken) return;
  state.files = firstFiles;
  state.loadingMore = false;
  state.albums = albums;
  if (state.tab === 'trash') state.trash = await loadAllPages('trash');
  updateStats();
  render();
}
function updateStats() {
  const chip = $('stats-chip');
  const n = state.files.length;
  if (!n) { chip.hidden = true; return; }
  const bytes = state.files.reduce((a, f) => a + f.size, 0);
  chip.textContent = state.loadingMore
    ? `${n}+ \u00b7 loading...`
    : `${n} \u00b7 ${fmtSize(bytes)}`;
  chip.hidden = false;
}

// ---- list building (search + sort) ----
async function buildList(base) {
  let list = base;
  if (state.query) {
    const q = state.query.toLowerCase();
    await Promise.all(list.map(getName));
    list = list.filter((f) => (nameCache.get(f.id) || '').toLowerCase().includes(q));
  }
  list = [...list];
  if (state.sort === 'old') list.sort((a, b) => a.created_at - b.created_at);
  else if (state.sort === 'big') list.sort((a, b) => b.size - a.size);
  else list.sort((a, b) => b.created_at - a.created_at);
  return list;
}

// ---- render ----
function setTab(tab) {
  state.tab = tab;
  state.albumOpen = null;
  exitSelectState();
  document.querySelectorAll('.tab').forEach((b) =>
    b.classList.toggle('active', b.dataset.tab === tab)
  );
  if (tab === 'trash') {
    loadAllPages('trash', (sofar) => {
      state.trash = sofar;
      render();
    }).then((all) => {
      state.trash = all;
      render();
    });
  }
  render();
}

function exitSelectState() {
  state.selecting = false;
  state.selectCtx = null;
  state.selected.clear();
}

async function render() {
  const token = ++renderToken;
  const gallery = $('gallery');
  gallery.innerHTML = '';
  $('empty').hidden = true;

  const toolsTabs = ['photos', 'videos', 'favorites', 'trash'];
  $('list-tools').hidden = !(toolsTabs.includes(state.tab) && !state.selecting && !state.albumOpen);
  $('album-head').hidden = !state.albumOpen || state.selecting;
  $('select-bar').hidden = !state.selecting;
  $('fab').style.display = state.selecting || state.tab === 'trash' ? 'none' : '';
  configureSelectBar();

  if (state.selecting && state.selectCtx === 'album-add') return renderAlbumPicker(gallery);
  if (state.albumOpen) return renderAlbumContents(gallery);

  switch (state.tab) {
    case 'photos': {
      const list = await buildList(state.files);
      if (token !== renderToken) return;
      return renderTimeline(gallery, list, {
        title: state.query ? 'nothing matches' : 'the chest is empty',
        sub: state.query
          ? 'no names match that search.'
          : 'upload a photo or video. it gets encrypted right here, then locked away in the cloud.',
      });
    }
    case 'videos': {
      const list = await buildList(state.files.filter((f) => f.mime.startsWith('video/')));
      if (token !== renderToken) return;
      return renderTimeline(gallery, list, {
        title: 'no videos yet',
        sub: 'videos you upload will show up here.',
      });
    }
    case 'favorites': {
      const list = await buildList(state.files.filter((f) => f.is_favorite));
      if (token !== renderToken) return;
      return renderTimeline(gallery, list, {
        title: 'no favorites yet',
        sub: 'tap the star on any photo to keep it here.',
      });
    }
    case 'trash': {
      const list = await buildList(state.trash);
      if (token !== renderToken) return;
      return renderTimeline(gallery, list, {
        title: 'trash is empty',
        sub: 'deleted things wait here for 30 days, then vanish forever.',
      }, { trash: true });
    }
    case 'albums':
      return renderAlbums(gallery);
  }
}

function configureSelectBar() {
  if (!state.selecting) return;
  const ctx = state.selectCtx;
  $('btn-sel-fav').hidden = ctx !== 'bulk';
  $('btn-sel-album').hidden = ctx !== 'bulk';
  $('btn-sel-trash').hidden = ctx === 'album-add';
  $('btn-sel-trash').title = ctx === 'trash' ? 'delete forever' : 'move to trash';
  $('btn-sel-restore').hidden = ctx !== 'trash';
  $('btn-sel-done').hidden = ctx !== 'album-add';
  updateSelectCount();
}
function updateSelectCount() {
  $('select-count').textContent = `${state.selected.size} selected`;
  $('btn-sel-done').disabled = !state.selected.size;
}

function renderTimeline(root, files, emptyMsg, opts = {}) {
  if (!files.length) {
    $('empty-title').textContent = emptyMsg.title;
    $('empty-sub').textContent = emptyMsg.sub;
    $('btn-empty-upload').style.display = opts.trash || state.query ? 'none' : '';
    $('empty').hidden = false;
    return;
  }
  const grouped = state.sort === 'big';
  let currentLabel = null;
  let grid = null;
  files.forEach((f, i) => {
    const label = grouped ? 'largest first' : dayLabel(opts.trash ? f.deleted_at : f.created_at);
    if (label !== currentLabel) {
      currentLabel = label;
      const h = document.createElement('div');
      h.className = 'day-label';
      h.textContent = opts.trash && !grouped ? `deleted ${label}` : label;
      root.appendChild(h);
      grid = document.createElement('div');
      grid.className = 'day-grid';
      root.appendChild(grid);
    }
    grid.appendChild(makeTile(f, files, i, opts));
  });
}

function makeTile(f, list, index, opts = {}) {
  const tile = document.createElement('button');
  tile.className = 'tile skeleton';

  let suppressed = false;
  tile.addEventListener('click', () => {
    if (suppressed) { suppressed = false; return; }
    if (state.selecting) {
      toggleSelect(f, tile);
    } else {
      openViewer(list, index, opts);
    }
  });

  // long-press enters bulk select (except inside album-add picker)
  if (!opts.noLongPress) {
    let lp = null;
    tile.addEventListener('pointerdown', () => {
      lp = setTimeout(() => {
        suppressed = true;
        if (!state.selecting) {
          enterSelect(state.tab === 'trash' ? 'trash' : 'bulk');
          state.selected.add(f.id);
          render();
        }
      }, 550);
    });
    const clear = () => clearTimeout(lp);
    tile.addEventListener('pointerup', clear);
    tile.addEventListener('pointerleave', clear);
    tile.addEventListener('pointercancel', clear);
    tile.addEventListener('contextmenu', (e) => e.preventDefault());
  }

  if (state.selecting) {
    tile.classList.add('selectable');
    if (state.selected.has(f.id)) tile.classList.add('selected');
  }

  if (f.live_video_id) {
    const b = document.createElement('span');
    b.className = 'badge live';
    b.textContent = 'live';
    tile.appendChild(b);
  } else if (f.mime.startsWith('video/')) {
    const b = document.createElement('span');
    b.className = 'badge';
    b.textContent = 'video';
    tile.appendChild(b);
  }
  if (f.is_favorite && !state.selecting) {
    const s = document.createElement('span');
    s.className = 'fav-mark';
    s.textContent = '\u2605';
    tile.appendChild(s);
  }

  if (f.has_thumb) {
    loadThumb(f, tile).catch(() => fallbackTile(f, tile));
  } else {
    fallbackTile(f, tile);
  }
  return tile;
}

function toggleSelect(f, tile) {
  if (state.selected.has(f.id)) state.selected.delete(f.id);
  else state.selected.add(f.id);
  tile.classList.toggle('selected', state.selected.has(f.id));
  updateSelectCount();
}

async function loadThumb(f, tile) {
  let url = thumbCache.get(f.id);
  if (!url) {
    const res = await apiRaw('GET', `/files/${f.id}/thumb`);
    const iv = b64d(res.headers.get('x-iv'));
    const plain = await dec(iv, await res.arrayBuffer());
    url = URL.createObjectURL(new Blob([plain], { type: 'image/webp' }));
    thumbCache.set(f.id, url);
  }
  const img = document.createElement('img');
  img.alt = '';
  img.onload = () => {
    img.classList.add('ready');
    tile.classList.remove('skeleton');
  };
  img.src = url;
  tile.prepend(img);
}
async function fallbackTile(f, tile) {
  tile.classList.remove('skeleton');
  tile.classList.add('no-thumb');
  tile.insertAdjacentText('afterbegin', await getName(f));
}

// ---- select mode ----
function enterSelect(ctx) {
  state.selecting = true;
  state.selectCtx = ctx;
  state.selected.clear();
}

async function bulkAction(action) {
  const ids = [...state.selected];
  if (!ids.length) return;
  try {
    await api('POST', '/files/bulk', { action, fileIds: ids });
    const verbs = {
      favorite: 'starred', trash: 'moved to trash',
      restore: 'restored', delete: 'gone forever',
    };
    toast(`${ids.length} ${verbs[action] || action}`);
  } catch (e) {
    toast('failed: ' + e.message);
  }
  exitSelectState();
  refresh();
}

// album picker grid (adding to an open album)
function renderAlbumPicker(root) {
  const inAlbum = new Set(state.albumFiles.map((f) => f.id));
  const candidates = state.files.filter((f) => !inAlbum.has(f.id));
  if (!candidates.length) {
    $('empty-title').textContent = 'nothing to add';
    $('empty-sub').textContent = 'everything is already in this album.';
    $('btn-empty-upload').style.display = 'none';
    $('empty').hidden = false;
    return;
  }
  const grid = document.createElement('div');
  grid.className = 'day-grid';
  grid.style.paddingTop = '10px';
  root.appendChild(grid);
  candidates.forEach((f) => {
    const tile = makeTile(f, [], 0, { noLongPress: true });
    grid.appendChild(tile);
  });
}

// ---- albums ----
async function renderAlbums(root) {
  const grid = document.createElement('div');
  grid.className = 'album-grid';
  root.appendChild(grid);

  const add = document.createElement('button');
  add.className = 'album-card new';
  add.innerHTML =
    '<div class="album-cover">+</div><div class="album-name">new album</div><div class="album-count">&nbsp;</div>';
  add.addEventListener('click', () => {
    $('album-name-input').value = '';
    $('album-dialog').hidden = false;
    $('album-name-input').focus();
  });
  grid.appendChild(add);

  for (const a of state.albums) {
    const card = document.createElement('button');
    card.className = 'album-card';
    const cover = document.createElement('div');
    cover.className = 'album-cover';
    cover.textContent = '\u25A3';
    card.appendChild(cover);
    const name = document.createElement('div');
    name.className = 'album-name';
    name.textContent = '...';
    decStr(a.name_enc, a.name_iv).then((n) => (name.textContent = n)).catch(() => (name.textContent = 'album'));
    card.appendChild(name);
    const count = document.createElement('div');
    count.className = 'album-count';
    count.textContent = `${a.file_count} item${a.file_count === 1 ? '' : 's'}`;
    card.appendChild(count);
    card.addEventListener('click', () => openAlbum(a));
    grid.appendChild(card);

    if (a.cover_id) {
      const coverFile = state.files.find((f) => f.id === a.cover_id);
      if (coverFile) loadThumbInto(coverFile, cover).catch(() => {});
    }
  }
}
async function loadThumbInto(f, container) {
  let url = thumbCache.get(f.id);
  if (!url) {
    const res = await apiRaw('GET', `/files/${f.id}/thumb`);
    const iv = b64d(res.headers.get('x-iv'));
    const plain = await dec(iv, await res.arrayBuffer());
    url = URL.createObjectURL(new Blob([plain], { type: 'image/webp' }));
    thumbCache.set(f.id, url);
  }
  container.textContent = '';
  const img = document.createElement('img');
  img.src = url;
  img.alt = '';
  container.appendChild(img);
}

async function openAlbum(a) {
  const { album, files } = await api('GET', `/albums/${a.id}`);
  state.albumOpen = album;
  state.albumFiles = files;
  $('album-title').textContent = await decStr(album.name_enc, album.name_iv).catch(() => 'album');
  render();
}
function renderAlbumContents(root) {
  const files = state.albumFiles;
  if (!files.length) {
    $('empty-title').textContent = 'empty album';
    $('empty-sub').textContent = 'tap add to pick photos for this album.';
    $('btn-empty-upload').style.display = 'none';
    $('empty').hidden = false;
    return;
  }
  const grid = document.createElement('div');
  grid.className = 'day-grid';
  grid.style.paddingTop = '10px';
  root.appendChild(grid);
  files.forEach((f, i) => grid.appendChild(makeTile(f, files, i, { noLongPress: true })));
}

// album chooser (bulk add-to-album)
async function openChooser() {
  const list = $('chooser-list');
  list.innerHTML = '';
  const mk = (label, onClick) => {
    const b = document.createElement('button');
    b.className = 'btn btn-ghost chooser-item';
    b.textContent = label;
    b.addEventListener('click', onClick);
    list.appendChild(b);
  };
  mk('+ new album', () => {
    $('chooser-dialog').hidden = true;
    $('album-name-input').value = '';
    $('album-dialog').hidden = false;
    $('album-dialog').dataset.pending = '1';
    $('album-name-input').focus();
  });
  for (const a of state.albums) {
    const name = await decStr(a.name_enc, a.name_iv).catch(() => 'album');
    mk(name, () => addSelectedToAlbum(a.id));
  }
  $('chooser-dialog').hidden = false;
}
async function addSelectedToAlbum(albumId) {
  const ids = [...state.selected];
  $('chooser-dialog').hidden = true;
  try {
    await api('POST', `/albums/${albumId}/add`, { fileIds: ids });
    toast(`added ${ids.length} item${ids.length === 1 ? '' : 's'}`);
  } catch (e) {
    toast('failed: ' + e.message);
  }
  exitSelectState();
  refresh();
}

// ---- upload (dedupe + live pairs) ----
function stem(name) { return name.replace(/\.[^.]+$/, '').toLowerCase(); }
const IMG_EXT = /\.(jpe?g|png|heic|heif|webp)$/i;
const VID_EXT = /\.(mov|mp4|m4v)$/i;

function groupLivePairs(files) {
  const byStem = new Map();
  for (const f of files) {
    const s = stem(f.name);
    if (!byStem.has(s)) byStem.set(s, []);
    byStem.get(s).push(f);
  }
  const items = [];
  for (const group of byStem.values()) {
    const img = group.find((f) => IMG_EXT.test(f.name) || f.type.startsWith('image/'));
    const vid = group.find((f) => VID_EXT.test(f.name) || f.type.startsWith('video/'));
    if (group.length >= 2 && img && vid) {
      items.push({ photo: img, video: vid });
      for (const extra of group) if (extra !== img && extra !== vid) items.push({ photo: extra });
    } else {
      for (const f of group) items.push({ photo: f });
    }
  }
  return items;
}

async function uploadFiles(fileList) {
  const files = [...fileList].filter((f) => f.size > 0);
  if (!files.length) return;

  const status = $('upload-status');
  status.hidden = false;
  $('upload-label').textContent = 'checking for duplicates...';
  $('upload-pct').textContent = '';

  let hashSet = new Set();
  try {
    hashSet = new Set((await api('GET', '/hashes')).hashes);
  } catch {}

  const items = groupLivePairs(files);
  let ok = 0, skipped = 0;

  for (let n = 0; n < items.length; n++) {
    const item = items[n];
    const label = item.video ? `${item.photo.name} (live)` : item.photo.name;
    $('upload-label').textContent = `${n + 1}/${items.length} \u00b7 ${label}`;
    const setPct = (pct) => {
      $('upload-pct').textContent = pct + '%';
      $('upload-bar').style.width = pct + '%';
    };
    try {
      const photoHash = await hashFile(item.photo);
      if (hashSet.has(photoHash)) { skipped++; setPct(100); continue; }

      const photoId = await uploadOne(item.photo, photoHash,
        (p) => setPct(item.video ? Math.round(p * 0.6) : p));
      hashSet.add(photoHash);

      if (item.video) {
        const vidHash = await hashFile(item.video);
        const videoId = await uploadOne(item.video, vidHash,
          (p) => setPct(60 + Math.round(p * 0.4)));
        hashSet.add(vidHash);
        await api('POST', `/files/${photoId}/live`, { videoId });
      }
      ok++;
    } catch (e) {
      toast(`failed: ${item.photo.name} \u2014 ${e.message}`);
    }
  }

  status.hidden = true;
  $('upload-bar').style.width = '0%';
  const bits = [];
  if (ok) bits.push(`${ok} locked away`);
  if (skipped) bits.push(`${skipped} skipped (already in the chest)`);
  if (bits.length) toast(bits.join(' \u00b7 '));
  refresh();
}

async function uploadOne(file, contentHash, onProgress) {
  const nameIv = randIv();
  const nameEnc = await encStr(file.name, nameIv);
  const chunkCount = Math.max(1, Math.ceil(file.size / CHUNK));

  const { id } = await api('POST', '/files', {
    nameEnc,
    nameIv: b64(nameIv),
    mime: file.type || 'application/octet-stream',
    size: file.size,
    chunkCount,
    contentHash,
  });

  const idxs = Array.from({ length: chunkCount }, (_, i) => i);
  let done = 0;
  await pool(idxs, UL_CONCURRENCY, async (i) => {
    const slice = file.slice(i * CHUNK, Math.min(file.size, (i + 1) * CHUNK));
    const iv = randIv();
    const ct = await enc(iv, await slice.arrayBuffer());
    await apiRaw('PUT', `/files/${id}/chunks/${i}?iv=${encodeURIComponent(b64(iv))}`, ct);
    done++;
    onProgress(Math.round((done / chunkCount) * 100));
  });

  const thumb = await makeThumb(file).catch(() => null);
  if (thumb) {
    const tIv = randIv();
    const tCt = await enc(tIv, await thumb.arrayBuffer());
    try {
      await apiRaw('PUT', `/files/${id}/thumb?iv=${encodeURIComponent(b64(tIv))}`, tCt);
    } catch {}
  }

  await api('POST', `/files/${id}/complete`);
  return id;
}

// on-device thumbnails
async function makeThumb(file) {
  if (file.type.startsWith('image/')) {
    const bmp = await createImageBitmap(file);
    return drawThumb(bmp, bmp.width, bmp.height);
  }
  if (file.type.startsWith('video/')) return videoThumb(file);
  return null;
}
function drawThumb(source, w, h) {
  const MAX = 360;
  const scale = Math.min(1, MAX / Math.max(w, h));
  const canvas = document.createElement('canvas');
  canvas.width = Math.round(w * scale);
  canvas.height = Math.round(h * scale);
  canvas.getContext('2d').drawImage(source, 0, 0, canvas.width, canvas.height);
  return new Promise((res) => canvas.toBlob(res, 'image/webp', 0.72));
}
function videoThumb(file) {
  return new Promise((resolve, reject) => {
    const url = URL.createObjectURL(file);
    const v = document.createElement('video');
    v.muted = true;
    v.playsInline = true;
    v.preload = 'metadata';
    v.src = url;
    const cleanup = () => URL.revokeObjectURL(url);
    const timer = setTimeout(() => { cleanup(); reject(new Error('thumb timeout')); }, 8000);
    v.onloadedmetadata = () => { v.currentTime = Math.min(0.5, (v.duration || 1) / 2); };
    v.onseeked = async () => {
      clearTimeout(timer);
      try { resolve(await drawThumb(v, v.videoWidth, v.videoHeight)); }
      catch (e) { reject(e); }
      finally { cleanup(); }
    };
    v.onerror = () => { clearTimeout(timer); cleanup(); reject(new Error('video load failed')); };
  });
}

// ---- parallel fetch + decrypt ----
async function fetchDecrypted(f, token, onProgress) {
  const { chunks } = await api('GET', `/files/${f.id}`);
  let done = 0;
  const parts = await pool(chunks, DL_CONCURRENCY, async (c) => {
    if (token !== undefined && token !== viewerToken) return null;
    const res = await apiRaw('GET', `/files/${f.id}/chunks/${c.idx}`);
    const plain = await dec(b64d(c.iv), await res.arrayBuffer());
    done++;
    if (onProgress) onProgress(done, chunks.length);
    return plain;
  });
  if (token !== undefined && token !== viewerToken) return null;
  if (parts.some((p) => p === null)) return null;
  return URL.createObjectURL(new Blob(parts, { type: f.mime }));
}

// ---- viewer ----
async function openViewer(list, index, opts = {}) {
  viewerList = list;
  viewerIndex = index;
  const token = ++viewerToken;
  const f = list[index];
  if (!f) return;

  const viewer = $('viewer');
  const body = $('viewer-body');
  viewer.hidden = false;
  document.body.style.overflow = 'hidden';
  body.innerHTML =
    '<div class="viewer-progress"><div class="spinner"></div><span id="viewer-progress-text">fetching and decrypting...</span></div>';
  $('live-hint').hidden = true;

  if (currentBlobUrl) { URL.revokeObjectURL(currentBlobUrl); currentBlobUrl = null; }

  const name = await getName(f);
  $('viewer-name').textContent = name;
  $('viewer-sub').textContent = `${fmtSize(f.size)} \u00b7 ${dayLabel(f.created_at)}`;
  $('btn-prev').disabled = index >= list.length - 1;
  $('btn-next').disabled = index <= 0;

  const inTrash = !!opts.trash;
  $('btn-fav').hidden = inTrash;
  $('btn-slideshow').hidden = inTrash;
  $('btn-trash').hidden = false;
  $('btn-trash').title = inTrash ? 'delete forever' : 'move to trash';
  $('btn-restore').hidden = !inTrash;
  updateFavButton(f);

  $('btn-fav').onclick = async () => {
    const val = f.is_favorite ? 0 : 1;
    try {
      await api('POST', `/files/${f.id}/favorite`, { value: val });
      f.is_favorite = val;
      updateFavButton(f);
      toast(val ? 'added to favorites' : 'removed from favorites');
    } catch (e) { toast('failed: ' + e.message); }
  };
  $('btn-trash').onclick = async () => {
    try {
      if (inTrash) {
        if (!confirm('delete forever? this cannot be undone.')) return;
        await api('DELETE', `/files/${f.id}`);
        toast('gone forever');
      } else {
        await api('POST', `/files/${f.id}/trash`);
        toast('moved to trash');
      }
      closeViewer();
      refresh();
    } catch (e) { toast('failed: ' + e.message); }
  };
  $('btn-restore').onclick = async () => {
    try {
      await api('POST', `/files/${f.id}/restore`);
      toast('restored');
      closeViewer();
      refresh();
    } catch (e) { toast('failed: ' + e.message); }
  };

  try {
    const url = await fetchDecrypted(f, token, (i, n) => {
      const pt = $('viewer-progress-text');
      if (pt && n > 1) pt.textContent = `fetching and decrypting... ${i}/${n}`;
    });
    if (!url || token !== viewerToken) return;
    currentBlobUrl = url;

    body.innerHTML = '';
    let el;
    if (f.mime.startsWith('image/')) {
      el = document.createElement('img');
      el.src = url;
      el.alt = name;
      if (f.live_video_id && !inTrash) setupLive(f, el, body);
      if (slideshowOn) scheduleSlide(4000);
    } else if (f.mime.startsWith('video/')) {
      el = document.createElement('video');
      el.src = url;
      el.controls = true;
      el.playsInline = true;
      el.autoplay = true;
      if (slideshowOn) el.addEventListener('ended', () => slideAdvance());
    } else {
      el = document.createElement('a');
      el.href = url;
      el.textContent = 'download file';
      el.download = name;
      el.className = 'btn';
    }
    body.appendChild(el);

    $('btn-download').onclick = () => {
      const a = document.createElement('a');
      a.href = url;
      a.download = name || 'file';
      a.click();
    };
  } catch (e) {
    if (token === viewerToken)
      body.innerHTML = `<div class="viewer-progress">failed: ${e.message}</div>`;
  }
}

function updateFavButton(f) {
  const b = $('btn-fav');
  b.textContent = f.is_favorite ? '\u2605' : '\u2606';
  b.classList.toggle('active', !!f.is_favorite);
}

// slideshow
function scheduleSlide(ms) {
  clearTimeout(slideTimer);
  slideTimer = setTimeout(slideAdvance, ms);
}
function slideAdvance() {
  if (!slideshowOn) return;
  if (viewerIndex + 1 < viewerList.length) {
    openViewer(viewerList, viewerIndex + 1, { trash: state.tab === 'trash' });
  } else {
    stopSlideshow();
    toast('slideshow finished');
  }
}
function stopSlideshow() {
  slideshowOn = false;
  clearTimeout(slideTimer);
  $('btn-slideshow').classList.remove('active');
}

// live photo hold-to-play
function setupLive(f, imgEl, body) {
  $('live-hint').hidden = false;
  let overlay = null;
  let holdTimer = null;
  const start = () => {
    holdTimer = setTimeout(async () => {
      let url = liveCache.get(f.id);
      if (!url) {
        try {
          const videoFile = (await api('GET', `/files/${f.live_video_id}`)).file;
          url = await fetchDecrypted(videoFile);
          if (!url) return;
          liveCache.set(f.id, url);
        } catch { return; }
      }
      overlay = document.createElement('video');
      overlay.className = 'live-overlay';
      overlay.src = url;
      overlay.muted = true;
      overlay.playsInline = true;
      overlay.loop = true;
      overlay.autoplay = true;
      body.appendChild(overlay);
    }, 250);
  };
  const stop = () => {
    clearTimeout(holdTimer);
    if (overlay) { overlay.remove(); overlay = null; }
  };
  imgEl.addEventListener('pointerdown', start);
  imgEl.addEventListener('pointerup', stop);
  imgEl.addEventListener('pointerleave', stop);
  imgEl.addEventListener('contextmenu', (e) => e.preventDefault());
}

function viewerNav(delta) {
  stopSlideshow();
  const next = viewerIndex + delta;
  if (next < 0 || next >= viewerList.length) return;
  openViewer(viewerList, next, { trash: state.tab === 'trash' });
}
function closeViewer() {
  viewerToken++;
  stopSlideshow();
  $('viewer').hidden = true;
  $('viewer-body').innerHTML = '';
  $('live-hint').hidden = true;
  document.body.style.overflow = '';
  if (currentBlobUrl) { URL.revokeObjectURL(currentBlobUrl); currentBlobUrl = null; }
}

// ---- shared-files intake (android share target) ----
function readSharedFiles() {
  return new Promise((resolve) => {
    const req = indexedDB.open('sanduk-share', 1);
    req.onupgradeneeded = () => req.result.createObjectStore('shared', { autoIncrement: true });
    req.onerror = () => resolve([]);
    req.onsuccess = () => {
      const db = req.result;
      const tx = db.transaction('shared', 'readwrite');
      const store = tx.objectStore('shared');
      const getAll = store.getAll();
      getAll.onsuccess = () => {
        const rows = getAll.result || [];
        store.clear();
        resolve(rows.map((r) => new File([r.blob], r.name || 'shared', { type: r.type || r.blob.type })));
      };
      getAll.onerror = () => resolve([]);
    };
  });
}

// ---- wiring ----
$('btn-new-vault').addEventListener('click', () => {
  const secret = b64u(crypto.getRandomValues(new Uint8Array(32)));
  const plate = $('key-plate');
  plate.dataset.secret = secret;
  plate.textContent = secret.match(/.{1,4}/g).join(' ');
  show('screen-reveal');
});

async function copyKey() {
  try {
    await navigator.clipboard.writeText($('key-plate').dataset.secret);
    toast('key copied. now save it somewhere safe');
  } catch {
    toast('copy blocked, select the text manually');
  }
}
$('key-plate').addEventListener('click', copyKey);
$('key-plate').addEventListener('keydown', (e) => {
  if (e.key === 'Enter' || e.key === ' ') copyKey();
});
$('btn-copy-key').addEventListener('click', copyKey);

$('confirm-saved').addEventListener('change', (e) => {
  $('btn-enter').disabled = !e.target.checked;
});
$('btn-enter').addEventListener('click', async () => {
  const errEl = $('reveal-error');
  errEl.hidden = true;
  try {
    await unlock($('key-plate').dataset.secret, true, $('invite-input-reveal').value.trim());
  } catch (e) {
    if (e.code === 'invite_required') {
      $('invite-row-reveal').hidden = false;
      errEl.textContent = 'this chest server needs an invite code';
      $('invite-input-reveal').focus();
    } else {
      errEl.textContent = 'setup failed: ' + e.message;
    }
    errEl.hidden = false;
  }
});
$('btn-unlock').addEventListener('click', async () => {
  const errEl = $('lock-error');
  errEl.hidden = true;
  try {
    await unlock(
      $('key-input').value.replace(/\s+/g, ''),
      $('remember').checked,
      $('invite-input').value.trim()
    );
  } catch (e) {
    if (e.code === 'invite_required') {
      $('invite-row').hidden = false;
      errEl.textContent = 'this chest server needs an invite code';
      $('invite-input').focus();
    } else {
      errEl.textContent = 'that key did not work';
    }
    errEl.hidden = false;
  }
});
$('key-input').addEventListener('keydown', (e) => {
  if (e.key === 'Enter') $('btn-unlock').click();
});

const pickFiles = () => $('file-input').click();
$('btn-upload').addEventListener('click', pickFiles);
$('btn-backup').addEventListener('click', () => {
  toast('select everything you want backed up, duplicates get skipped automatically');
  pickFiles();
});
$('fab').addEventListener('click', pickFiles);
$('btn-empty-upload').addEventListener('click', pickFiles);
$('file-input').addEventListener('change', (e) => {
  if (e.target.files.length) uploadFiles(e.target.files);
  e.target.value = '';
});

$('btn-lock').addEventListener('click', () => {
  if (confirm('lock the chest? you will need your key to get back in.')) lockApp();
});

document.querySelectorAll('.tab').forEach((b) =>
  b.addEventListener('click', () => setTab(b.dataset.tab))
);

// list tools
let searchDebounce;
$('search-input').addEventListener('input', (e) => {
  clearTimeout(searchDebounce);
  searchDebounce = setTimeout(() => {
    state.query = e.target.value.trim();
    render();
  }, 200);
});
$('sort-select').addEventListener('change', (e) => {
  state.sort = e.target.value;
  render();
});
$('btn-select-mode').addEventListener('click', () => {
  enterSelect(state.tab === 'trash' ? 'trash' : 'bulk');
  render();
});

// select bar actions
$('btn-sel-cancel').addEventListener('click', () => {
  const wasAlbumAdd = state.selectCtx === 'album-add';
  exitSelectState();
  if (wasAlbumAdd && state.albumOpen) openAlbum(state.albumOpen);
  else render();
});
$('btn-sel-fav').addEventListener('click', () => bulkAction('favorite'));
$('btn-sel-trash').addEventListener('click', () => {
  if (state.selectCtx === 'trash') {
    if (!confirm(`delete ${state.selected.size} forever? this cannot be undone.`)) return;
    bulkAction('delete');
  } else {
    bulkAction('trash');
  }
});
$('btn-sel-restore').addEventListener('click', () => bulkAction('restore'));
$('btn-sel-album').addEventListener('click', openChooser);
$('btn-sel-done').addEventListener('click', async () => {
  const ids = [...state.selected];
  const album = state.albumOpen;
  exitSelectState();
  try {
    await api('POST', `/albums/${album.id}/add`, { fileIds: ids });
    toast(`added ${ids.length} item${ids.length === 1 ? '' : 's'}`);
  } catch (e) {
    toast('failed: ' + e.message);
  }
  const { albums } = await api('GET', '/albums');
  state.albums = albums;
  openAlbum(album);
});

// album chrome
$('btn-album-back').addEventListener('click', () => {
  state.albumOpen = null;
  refresh();
});
$('btn-album-add').addEventListener('click', () => {
  enterSelect('album-add');
  render();
});
$('btn-album-delete').addEventListener('click', async () => {
  if (!confirm('delete this album? photos inside stay in your chest.')) return;
  await api('DELETE', `/albums/${state.albumOpen.id}`);
  state.albumOpen = null;
  toast('album deleted');
  refresh();
});

// dialogs
$('btn-album-cancel').addEventListener('click', () => {
  $('album-dialog').hidden = true;
  delete $('album-dialog').dataset.pending;
});
$('btn-album-create').addEventListener('click', async () => {
  const name = $('album-name-input').value.trim();
  if (!name) return;
  const iv = randIv();
  const nameEnc = await encStr(name, iv);
  const { id } = await api('POST', '/albums', { nameEnc, nameIv: b64(iv) });
  const pending = $('album-dialog').dataset.pending;
  $('album-dialog').hidden = true;
  delete $('album-dialog').dataset.pending;
  const { albums } = await api('GET', '/albums');
  state.albums = albums;
  if (pending && state.selected.size) {
    await addSelectedToAlbum(id);
  } else {
    toast('album created');
    render();
  }
});
$('album-name-input').addEventListener('keydown', (e) => {
  if (e.key === 'Enter') $('btn-album-create').click();
});
$('btn-chooser-cancel').addEventListener('click', () => ($('chooser-dialog').hidden = true));

// viewer
$('btn-close').addEventListener('click', closeViewer);
$('btn-prev').addEventListener('click', () => viewerNav(1));
$('btn-next').addEventListener('click', () => viewerNav(-1));
$('btn-slideshow').addEventListener('click', () => {
  slideshowOn = !slideshowOn;
  $('btn-slideshow').classList.toggle('active', slideshowOn);
  if (slideshowOn) {
    toast('slideshow on');
    scheduleSlide(2500);
  } else {
    clearTimeout(slideTimer);
  }
});

document.addEventListener('keydown', (e) => {
  if (!$('album-dialog').hidden && e.key === 'Escape') { $('album-dialog').hidden = true; return; }
  if (!$('chooser-dialog').hidden && e.key === 'Escape') { $('chooser-dialog').hidden = true; return; }
  if ($('viewer').hidden) return;
  if (e.key === 'Escape') closeViewer();
  if (e.key === 'ArrowLeft') viewerNav(1);
  if (e.key === 'ArrowRight') viewerNav(-1);
  if (e.key === ' ') { e.preventDefault(); $('btn-slideshow').click(); }
});

// swipe: left/right navigate, down closes
let touchX = 0, touchY = 0;
$('viewer-body').addEventListener('touchstart', (e) => {
  touchX = e.changedTouches[0].clientX;
  touchY = e.changedTouches[0].clientY;
}, { passive: true });
$('viewer-body').addEventListener('touchend', (e) => {
  const dx = e.changedTouches[0].clientX - touchX;
  const dy = e.changedTouches[0].clientY - touchY;
  if (Math.abs(dx) > 60 && Math.abs(dx) > Math.abs(dy) * 1.5) {
    viewerNav(dx < 0 ? 1 : -1);
  } else if (dy > 90 && Math.abs(dy) > Math.abs(dx) * 1.5) {
    closeViewer();
  }
}, { passive: true });

// drag & drop
let dragDepth = 0;
window.addEventListener('dragenter', (e) => {
  if ($('screen-app').hidden || state.selecting) return;
  e.preventDefault();
  dragDepth++;
  $('dropzone').hidden = false;
});
window.addEventListener('dragover', (e) => e.preventDefault());
window.addEventListener('dragleave', () => {
  dragDepth = Math.max(0, dragDepth - 1);
  if (!dragDepth) $('dropzone').hidden = true;
});
window.addEventListener('drop', (e) => {
  e.preventDefault();
  dragDepth = 0;
  $('dropzone').hidden = true;
  if ($('screen-app').hidden || state.selecting) return;
  if (e.dataTransfer.files.length) uploadFiles(e.dataTransfer.files);
});

// boot
(async () => {
  if ('serviceWorker' in navigator) {
    navigator.serviceWorker.register('/sw.js').catch(() => {});
  }
  if (new URLSearchParams(location.search).has('shared')) {
    pendingShared = await readSharedFiles();
    history.replaceState(null, '', '/');
  }
  const saved = localStorage.getItem('sanduk.secret');
  if (saved) {
    try {
      await unlock(saved, true);
      return;
    } catch (e) {
      if (e.code !== 'invite_required') localStorage.removeItem('sanduk.secret');
    }
  }
  show('screen-lock');
})();
