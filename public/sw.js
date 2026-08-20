// sanduk service worker
// jobs:
//   1. receive photos shared from other apps (android share target)
//   2. cache the shell for offline opens, NETWORK-FIRST so updates land instantly

const CACHE = 'sanduk-static-v3';

self.addEventListener('install', (e) => self.skipWaiting());
self.addEventListener('activate', (e) => {
  e.waitUntil(
    caches.keys().then((keys) =>
      Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k)))
    ).then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', (e) => {
  const url = new URL(e.request.url);

  // android share target: other apps POST files here
  if (e.request.method === 'POST' && url.pathname === '/share') {
    e.respondWith(handleShare(e.request));
    return;
  }

  if (e.request.method !== 'GET') return;
  if (url.origin !== location.origin) return;
  if (url.pathname.startsWith('/api/')) return; // never cache api

  e.respondWith(networkFirst(e.request));
});

async function networkFirst(request) {
  try {
    const fresh = await fetch(request);
    if (fresh.ok) {
      const cache = await caches.open(CACHE);
      cache.put(request, fresh.clone());
    }
    return fresh;
  } catch {
    const cached = await caches.match(request);
    if (cached) return cached;
    throw new Error('offline and not cached');
  }
}

async function handleShare(request) {
  try {
    const form = await request.formData();
    const files = form.getAll('media').filter((f) => f && f.size > 0);
    if (files.length) {
      const db = await openShareDb();
      const tx = db.transaction('shared', 'readwrite');
      const store = tx.objectStore('shared');
      for (const f of files) {
        store.add({ name: f.name, type: f.type, blob: f });
      }
      await new Promise((res, rej) => {
        tx.oncomplete = res;
        tx.onerror = () => rej(tx.error);
      });
    }
  } catch (err) {
    // fall through to the app either way
  }
  return Response.redirect(new URL('/?shared=1', self.location.origin).href, 303);
}

function openShareDb() {
  return new Promise((resolve, reject) => {
    const req = indexedDB.open('sanduk-share', 1);
    req.onupgradeneeded = () => {
      req.result.createObjectStore('shared', { autoIncrement: true });
    };
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
}
