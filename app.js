import { JumpDetector, LM } from './detector.js';

// Uses models/pose_landmarker_lite.task next to the app if it's there,
// otherwise downloads it from Google once (the service worker then caches it).
const CDN = 'https://cdn.jsdelivr.net/npm/@mediapipe/tasks-vision@1.2.3';
const LOCAL_MODEL = './models/pose_landmarker_lite.task';
const MODEL_URL =
  'https://storage.googleapis.com/mediapipe-models/pose_landmarker/pose_landmarker_lite/float16/latest/pose_landmarker_lite.task';

const $ = (id) => document.getElementById(id);
const video = $('video'), overlay = $('overlay'), ctx = overlay.getContext('2d');

// ------------------------------------------------------------------ settings
const DEF = {
  front: false, res: '1080', aspect: '4:3', zoom: 0, exposure: 0,
  shots: 10, fps: 10, pre: 2, quality: 0.92,
  sens: 50, push: true, cooldown: 2, armed: true,
};
let S = (() => {
  try { return { ...DEF, ...JSON.parse(localStorage.getItem('jumpshot') || '{}') }; }
  catch { return { ...DEF }; }
})();
const save = () => { try { localStorage.setItem('jumpshot', JSON.stringify(S)); } catch {} };

const FMT = {
  zoom: (v) => (v == 0 ? 'widest' : Math.round(v * 100) + '%'),
  exposure: (v) => (v == 0 ? '0 EV' : (v > 0 ? '+' : '') + Number(v).toFixed(1) + ' EV'),
  shots: (v) => String(v),
  fps: (v) => v + ' fps',
  pre: (v) => (v == 0 ? 'off' : v + (v == 1 ? ' frame' : ' frames')),
  quality: (v) => String(Math.round(v * 100)),
  sens: (v) => String(v),
  cooldown: (v) => Number(v).toFixed(1) + ' s',
};

for (const el of document.querySelectorAll('[data-k]')) {
  const k = el.dataset.k;
  const out = document.querySelector(`output[data-for="${k}"]`);
  if (el.type === 'checkbox') el.checked = !!S[k]; else el.value = S[k];
  if (out) out.textContent = FMT[k](S[k]);
  el.addEventListener('input', () => {
    S[k] = el.type === 'checkbox' ? el.checked : el.type === 'range' ? Number(el.value) : el.value;
    if (out) out.textContent = FMT[k](S[k]);
    save();
  });
}

// ------------------------------------------------------------------ storage (IndexedDB)
const dbp = new Promise((res, rej) => {
  const r = indexedDB.open('jumpshot', 1);
  r.onupgradeneeded = () => r.result.createObjectStore('photos', { keyPath: 'id', autoIncrement: true });
  r.onsuccess = () => res(r.result);
  r.onerror = () => rej(r.error);
});
async function store(mode, fn) {
  const db = await dbp;
  return new Promise((res, rej) => {
    const tx = db.transaction('photos', mode);
    const req = fn(tx.objectStore('photos'));
    tx.oncomplete = () => res(req && req.result);
    tx.onerror = () => rej(tx.error);
  });
}
const addPhoto = (p) => store('readwrite', (s) => s.add(p));
const allPhotos = async () => (await store('readonly', (s) => s.getAll())) || [];
const delPhotos = (ids) => store('readwrite', (s) => { ids.forEach((id) => s.delete(id)); });

// ------------------------------------------------------------------ camera
const det = new JumpDetector();
let stream = null, track = null, caps = {}, running = false;
let landmarker = null, poseLoading = null;
let bursting = false, ring = [], ringTimer = null, wakeLock = null;
let fpsN = 0, fpsT = 0, fps = 0;

function frameSize() {
  const h = Number(S.res);
  const w = S.aspect === '16:9' ? Math.round((h * 16) / 9) : Math.round((h * 4) / 3);
  return [w, h];
}

async function startCamera() {
  stopCamera();
  showMsg(null);
  setStatus('Starting camera…');
  if (!navigator.mediaDevices?.getUserMedia) {
    return showMsg(location.protocol === 'https:' || location.hostname === 'localhost'
      ? 'This browser has no camera access.'
      : 'The camera only works over HTTPS. Open this app from its https:// address.', false);
  }
  const [w, h] = frameSize();
  try {
    stream = await navigator.mediaDevices.getUserMedia({
      audio: false,
      video: {
        facingMode: S.front ? 'user' : { ideal: 'environment' },
        width: { ideal: w }, height: { ideal: h }, frameRate: { ideal: 30 },
      },
    });
  } catch (e) {
    return showMsg(e.name === 'NotAllowedError'
      ? 'Camera permission was blocked. Allow the camera for this site in the browser settings, then try again.'
      : 'Could not open the camera: ' + e.message);
  }
  track = stream.getVideoTracks()[0];
  caps = track.getCapabilities ? track.getCapabilities() : {};
  try { localStorage.setItem('jumpshot-caps', JSON.stringify({ zoom: !!caps.zoom, exp: !!caps.exposureCompensation })); } catch {}
  video.srcObject = stream;
  video.classList.toggle('mirror', S.front);
  try { await video.play(); } catch {}
  applyTrack();
  det.mode = S.push ? 'push' : 'air';
  det.sensitivity = S.sens / 100;
  det.cooldown = S.cooldown;
  det.reset();
  running = true;
  requestWake();
  startRing();
  if (!landmarker) loadPose();
  schedule();
}

function stopCamera() {
  running = false;
  stopRing();
  if (stream) stream.getTracks().forEach((t) => t.stop());
  stream = track = null;
  video.srcObject = null;
  ctx.clearRect(0, 0, overlay.width, overlay.height);
  try { wakeLock?.release(); } catch {}
  wakeLock = null;
}

async function applyTrack() {
  if (!track) return;
  const adv = {};
  if (caps.zoom) adv.zoom = caps.zoom.min + S.zoom * (caps.zoom.max - caps.zoom.min);
  if (caps.exposureCompensation) {
    const c = caps.exposureCompensation;
    adv.exposureCompensation = Math.min(c.max, Math.max(c.min, S.exposure));
    if (caps.exposureMode?.includes('continuous')) adv.exposureMode = 'continuous';
  }
  if (caps.focusMode?.includes('continuous')) adv.focusMode = 'continuous';
  if (Object.keys(adv).length) { try { await track.applyConstraints({ advanced: [adv] }); } catch {} }
}

async function requestWake() {
  try { wakeLock = await navigator.wakeLock?.request('screen'); } catch {}
}

function loadPose() {
  if (poseLoading) return poseLoading;
  setStatus('Loading pose model…');
  poseLoading = (async () => {
    // Bundled copy if it's deployed next to the app, otherwise the same version from jsDelivr.
    let vision, base;
    try { vision = await import('./vendor/mediapipe/vision_bundle.mjs'); base = new URL('./vendor/mediapipe/', location.href).href; }
    catch { vision = await import(CDN + '/vision_bundle.mjs'); base = CDN + '/'; }
    const files = await vision.FilesetResolver.forVisionTasks(base + 'wasm');
    let model = MODEL_URL;
    try { if ((await fetch(LOCAL_MODEL, { method: 'HEAD' })).ok) model = LOCAL_MODEL; } catch {}
    for (const delegate of ['GPU', 'CPU']) {
      try {
        landmarker = await vision.PoseLandmarker.createFromOptions(files, {
          baseOptions: { modelAssetPath: model, delegate },
          runningMode: 'VIDEO', numPoses: 1,
        });
        return;
      } catch (e) { console.warn('Pose init failed on', delegate, e); }
    }
    throw new Error('no delegate');
  })().catch((e) => {
    poseLoading = null;
    showMsg('Could not load the pose model. The first launch needs internet; after that it works offline.');
  });
  return poseLoading;
}

// ------------------------------------------------------------------ detection loop
function schedule() {
  if (!running) return;
  if (video.requestVideoFrameCallback) video.requestVideoFrameCallback(tick);
  else requestAnimationFrame(tick);
}

let lastTs = 0;
function tick() {
  if (!running) return;
  if (landmarker && video.readyState >= 2 && video.videoWidth) {
    let ts = performance.now();
    if (ts <= lastTs) ts = lastTs + 1;
    lastTs = ts;
    let lm;
    try { lm = landmarker.detectForVideo(video, ts).landmarks?.[0]; } catch (e) { console.warn(e); }
    const vw = video.videoWidth, vh = video.videoHeight;
    const r = det.update(lm, vw, vh, ts, S.armed && !bursting);
    draw(lm, r, vw, vh);
    countFps();
    showState(r, vw, vh);
    if (r.triggered) fireBurst();
  }
  schedule();
}

function countFps() {
  const now = performance.now();
  fpsN++;
  if (now - fpsT >= 1000) { fps = fpsN; fpsN = 0; fpsT = now; }
}

const BONES = [
  [LM.L_SHOULDER, LM.R_SHOULDER], [LM.L_SHOULDER, LM.L_ELBOW], [LM.L_ELBOW, LM.L_WRIST],
  [LM.R_SHOULDER, LM.R_ELBOW], [LM.R_ELBOW, LM.R_WRIST], [LM.L_SHOULDER, LM.L_HIP],
  [LM.R_SHOULDER, LM.R_HIP], [LM.L_HIP, LM.R_HIP], [LM.L_HIP, LM.L_KNEE], [LM.L_KNEE, LM.L_ANKLE],
  [LM.R_HIP, LM.R_KNEE], [LM.R_KNEE, LM.R_ANKLE],
];

function draw(lm, r, vw, vh) {
  const dpr = devicePixelRatio || 1;
  const cw = overlay.clientWidth, ch = overlay.clientHeight;
  if (overlay.width !== Math.round(cw * dpr) || overlay.height !== Math.round(ch * dpr)) {
    overlay.width = Math.round(cw * dpr); overlay.height = Math.round(ch * dpr);
  }
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  ctx.clearRect(0, 0, cw, ch);
  if (!lm) return;
  // object-fit: cover mapping, mirrored for the front camera
  const sc = Math.max(cw / vw, ch / vh), dx = (cw - vw * sc) / 2, dy = (ch - vh * sc) / 2;
  const X = (x) => { const v = x * sc + dx; return S.front ? cw - v : v; };
  const Y = (y) => y * sc + dy;

  ctx.lineCap = 'round';
  ctx.strokeStyle = 'rgba(255,255,255,.8)'; ctx.lineWidth = 3;
  for (const [a, b] of BONES) {
    const p = lm[a], q = lm[b];
    if (!p || !q || (p.visibility ?? 1) < 0.5 || (q.visibility ?? 1) < 0.5) continue;
    ctx.beginPath(); ctx.moveTo(X(p.x * vw), Y(p.y * vh)); ctx.lineTo(X(q.x * vw), Y(q.y * vh)); ctx.stroke();
  }
  ctx.font = '14px system-ui,sans-serif'; ctx.shadowColor = '#000'; ctx.shadowBlur = 4;
  const line = (y, color, dash, label, below) => {
    if (y == null) return;
    ctx.strokeStyle = color; ctx.lineWidth = 2; ctx.setLineDash(dash);
    ctx.beginPath(); ctx.moveTo(0, Y(y)); ctx.lineTo(cw, Y(y)); ctx.stroke(); ctx.setLineDash([]);
    ctx.fillStyle = '#fff'; ctx.fillText(label, 10, Y(y) + (below ? 18 : -6));
  };
  line(r.baselineY, '#4caf50', [], 'stance');
  line(r.riseLineY, '#ffeb3b', [12, 8], 'airborne');
  line(r.dipLineY, '#26c6da', [6, 6], 'dip', true);
  ctx.shadowBlur = 0;
  if (r.hipY != null) {
    ctx.fillStyle = '#e040fb';
    ctx.beginPath(); ctx.arc(X(r.hipX), Y(r.hipY), 8, 0, Math.PI * 2); ctx.fill();
  }
}

function showState(r, vw, vh) {
  if (!bursting) {
    setStatus({
      none: 'Step into frame — whole body',
      learning: 'Stand still…',
      ready: 'Ready — jump!',
      dipping: 'Ready — jump!',
      cooldown: 'Cooldown',
      disarmed: 'Auto-trigger off',
    }[r.state]);
  }
  const z = caps.zoom && track ? ' · ' + (track.getSettings().zoom ?? 1).toFixed(1) + '×' : '';
  $('info').textContent =
    `rise ${r.rise >= 0 ? '+' : ''}${r.rise.toFixed(2)} · up ${r.vUp.toFixed(1)}/s · ${fps} fps · ${vw}×${vh}${z}`;
}
const setStatus = (t) => { $('status').textContent = t; };

// ------------------------------------------------------------------ pre-trigger ring buffer
function startRing() {
  stopRing();
  if (S.pre <= 0) return;
  ringTimer = setInterval(async () => {
    if (!running || bursting || !video.videoWidth || document.hidden) return;
    try {
      const b = await createImageBitmap(video);
      ring.push(b);
      while (ring.length > S.pre) ring.shift().close();
    } catch {}
  }, 1000 / S.fps);
}
function stopRing() {
  clearInterval(ringTimer); ringTimer = null;
  ring.forEach((b) => b.close()); ring = [];
}

// ------------------------------------------------------------------ burst
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const enc = document.createElement('canvas');
const encode = (bmp, w, h, q) => {
  enc.width = w; enc.height = h;
  enc.getContext('2d').drawImage(bmp, 0, 0, w, h);
  return new Promise((r) => enc.toBlob(r, 'image/jpeg', q));
};

async function fireBurst() {
  if (bursting || !running || !video.videoWidth) return;
  bursting = true;
  navigator.vibrate?.(60);
  $('border').classList.add('on'); $('shootBtn').classList.add('busy');
  setStatus('Shooting…');
  const t0 = performance.now();
  const frames = ring.splice(0);              // frames from just before the trigger
  const gap = 1000 / S.fps;
  for (let i = 0; i < S.shots; i++) {
    const s = performance.now();
    try { frames.push(await createImageBitmap(video)); } catch {}
    const left = gap - (performance.now() - s);
    if (i < S.shots - 1 && left > 0) await sleep(left);
  }
  $('border').classList.remove('on'); $('shootBtn').classList.remove('busy');
  setStatus('Saving…');

  const burst = Date.now();
  let saved = 0;
  for (let i = 0; i < frames.length; i++) {
    const b = frames[i];
    try {
      const blob = await encode(b, b.width, b.height, S.quality);
      const tw = 320, th = Math.round((b.height * tw) / b.width);
      const thumb = await encode(b, tw, th, 0.7);
      await addPhoto({ burst, idx: i + 1, t: burst, w: b.width, h: b.height, blob, thumb });
      saved++;
    } catch (e) { console.warn('save failed', e); }
    b.close();
  }
  const secs = ((performance.now() - t0) / 1000).toFixed(1);
  $('last').textContent = `Saved ${saved} shots in ${secs} s — tap the thumbnail to see them`;
  bursting = false;
  navigator.storage?.persist?.().catch(() => {});
  refreshThumb();
}

// ------------------------------------------------------------------ thumbnail + photos
let thumbUrl = null;
async function refreshThumb() {
  const all = await allPhotos().catch(() => []);
  const last = all[all.length - 1];
  if (thumbUrl) URL.revokeObjectURL(thumbUrl);
  thumbUrl = last ? URL.createObjectURL(last.thumb || last.blob) : null;
  $('thumbImg').hidden = !thumbUrl; $('thumbIcon').style.display = thumbUrl ? 'none' : '';
  if (thumbUrl) $('thumbImg').src = thumbUrl;
}

const pad = (n) => String(n).padStart(2, '0');
const fileName = (p) => {
  const d = new Date(p.t);
  return `JUMP_${d.getFullYear()}${pad(d.getMonth() + 1)}${pad(d.getDate())}_${pad(d.getHours())}${pad(d.getMinutes())}${pad(d.getSeconds())}_${pad(p.idx)}.jpg`;
};
const toFile = (p) => new File([p.blob], fileName(p), { type: 'image/jpeg' });

let photoUrls = [], groups = [];
async function renderPhotos() {
  photoUrls.forEach(URL.revokeObjectURL); photoUrls = [];
  const all = await allPhotos().catch(() => []);
  const by = new Map();
  for (const p of all) (by.get(p.burst) || by.set(p.burst, []).get(p.burst)).push(p);
  groups = [...by.values()].sort((a, b) => b[0].burst - a[0].burst).map((g) => g.sort((a, b) => a.idx - b.idx));
  let bytes = 0; all.forEach((p) => (bytes += p.blob.size));
  const size = bytes < 1048576 ? Math.max(1, Math.round(bytes / 1024)) + ' KB' : (bytes / 1048576).toFixed(bytes < 10485760 ? 1 : 0) + ' MB';
  const plural = (n, w) => `${n} ${w}${n === 1 ? '' : 's'}`;
  const info = all.length ? `${plural(all.length, 'photo')} in ${plural(groups.length, 'burst')} · ${size} on this device` : '';
  $('photoInfo').textContent = info;
  $('storeInfo').textContent = info || 'No photos yet. Photos are kept inside the app on this device.';
  $('clearAll').hidden = !all.length;
  const box = $('bursts');
  box.textContent = '';
  if (!groups.length) {
    box.innerHTML = '<p class="empty">No photos yet.<br>Jump in front of the camera, or press the shutter.</p>';
    return;
  }
  groups.forEach((g, gi) => {
    const sec = document.createElement('section'); sec.className = 'burst';
    const h = document.createElement('div'); h.className = 'burst-h';
    const title = document.createElement('b');
    title.textContent = new Date(g[0].t).toLocaleString([], { dateStyle: 'medium', timeStyle: 'short' }) + ` · ${g.length} shots`;
    h.append(title, mkBtn('Share all', () => share(g)), mkBtn('Download all', () => download(g)),
      mkBtn('Delete', async () => { await delPhotos(g.map((p) => p.id)); renderPhotos(); refreshThumb(); }));
    const grid = document.createElement('div'); grid.className = 'grid';
    g.forEach((p, pi) => {
      const u = URL.createObjectURL(p.thumb || p.blob); photoUrls.push(u);
      const b = document.createElement('button'); b.setAttribute('aria-label', `Photo ${pi + 1}`);
      const img = document.createElement('img'); img.src = u; img.loading = 'lazy'; img.alt = '';
      b.append(img); b.onclick = () => openViewer(gi, pi);
      grid.append(b);
    });
    sec.append(h, grid); box.append(sec);
  });
}
const mkBtn = (label, fn) => { const b = document.createElement('button'); b.textContent = label; b.onclick = fn; return b; };

async function share(list) {
  const files = list.map(toFile);
  if (navigator.canShare?.({ files })) {
    try { await navigator.share({ files, title: 'JumpShot' }); } catch {}
  } else download(list);
}
async function download(list) {
  for (const p of list) {
    const a = document.createElement('a');
    a.href = URL.createObjectURL(p.blob); a.download = fileName(p);
    document.body.append(a); a.click(); a.remove();
    setTimeout(() => URL.revokeObjectURL(a.href), 4000);
    await sleep(250);
  }
}

// ------------------------------------------------------------------ viewer
let vGroup = 0, vUrls = [];
function openViewer(gi, pi) {
  vGroup = gi;
  vUrls.forEach(URL.revokeObjectURL);
  const strip = $('vStrip'); strip.textContent = '';
  vUrls = groups[gi].map((p) => URL.createObjectURL(p.blob));
  vUrls.forEach((u) => {
    const f = document.createElement('figure'); const img = document.createElement('img');
    img.src = u; img.alt = ''; f.append(img); strip.append(f);
  });
  $('viewer').hidden = false;
  requestAnimationFrame(() => { strip.scrollLeft = pi * strip.clientWidth; updCount(); });
}
const vIndex = () => Math.round($('vStrip').scrollLeft / Math.max(1, $('vStrip').clientWidth));
const updCount = () => { $('vCount').textContent = `${vIndex() + 1} / ${groups[vGroup]?.length || 0}`; };
const vGo = (d) => { const s = $('vStrip'); s.scrollTo({ left: (vIndex() + d) * s.clientWidth, behavior: 'smooth' }); };
function closeViewer() { $('viewer').hidden = true; vUrls.forEach(URL.revokeObjectURL); vUrls = []; $('vStrip').textContent = ''; }
$('vStrip').addEventListener('scroll', updCount, { passive: true });
$('vClose').onclick = closeViewer;
$('vPrev').onclick = () => vGo(-1);
$('vNext').onclick = () => vGo(1);
$('vShare').onclick = () => share([groups[vGroup][vIndex()]]);
$('vSave').onclick = () => download([groups[vGroup][vIndex()]]);
$('vDelete').onclick = async () => {
  await delPhotos([groups[vGroup][vIndex()].id]);
  closeViewer(); await renderPhotos(); refreshThumb();
};
addEventListener('keydown', (e) => {
  if ($('viewer').hidden) return;
  if (e.key === 'ArrowLeft') vGo(-1); else if (e.key === 'ArrowRight') vGo(1); else if (e.key === 'Escape') closeViewer();
});
$('clearAll').onclick = async () => {
  if ($('clearAll').dataset.sure) {
    await delPhotos((await allPhotos()).map((p) => p.id));
    delete $('clearAll').dataset.sure; $('clearAll').textContent = 'Delete all';
    renderPhotos(); refreshThumb();
  } else {
    $('clearAll').dataset.sure = '1'; $('clearAll').textContent = 'Tap again to delete';
    setTimeout(() => { delete $('clearAll').dataset.sure; $('clearAll').textContent = 'Delete all'; }, 3000);
  }
};

// ------------------------------------------------------------------ camera controls
function refreshArm() {
  $('armBtn').classList.toggle('off', !S.armed);
  $('armBtn').setAttribute('aria-label', S.armed ? 'Auto-trigger on' : 'Auto-trigger off');
}
$('armBtn').onclick = () => { S.armed = !S.armed; save(); refreshArm(); };
$('shootBtn').onclick = () => fireBurst();
$('settingsBtn').onclick = () => { location.hash = 'settings'; };
$('galleryBtn').onclick = () => { location.hash = 'photos'; };
$('msgBtn').onclick = () => startCamera();
for (const b of document.querySelectorAll('.back')) b.onclick = () => { location.hash = ''; };

function showMsg(text, retry = true) {
  $('msg').hidden = !text;
  if (text) { $('msgText').textContent = text; $('msgBtn').hidden = !retry; setStatus(''); }
}

// pinch to zoom
const pts = new Map();
let pinch0 = null;
$('v-camera').addEventListener('pointerdown', (e) => { pts.set(e.pointerId, e); });
$('v-camera').addEventListener('pointermove', (e) => {
  if (!pts.has(e.pointerId)) return;
  pts.set(e.pointerId, e);
  if (pts.size !== 2 || !caps.zoom || !track) return;
  const [a, b] = [...pts.values()];
  const d = Math.hypot(a.clientX - b.clientX, a.clientY - b.clientY);
  const z = caps.zoom;
  if (!pinch0) { pinch0 = { d, z: track.getSettings().zoom ?? z.min }; return; }
  const zoom = Math.min(z.max, Math.max(z.min, (pinch0.z * d) / pinch0.d));
  track.applyConstraints({ advanced: [{ zoom }] }).catch(() => {});
  S.zoom = (zoom - z.min) / (z.max - z.min || 1);
});
const endPtr = (e) => {
  pts.delete(e.pointerId);
  if (pts.size < 2 && pinch0) { pinch0 = null; save(); const el = $('s-zoom'); el.value = S.zoom; document.querySelector('output[data-for="zoom"]').textContent = FMT.zoom(S.zoom); }
};
['pointerup', 'pointercancel', 'pointerleave'].forEach((t) => $('v-camera').addEventListener(t, endPtr));

// ------------------------------------------------------------------ views (hash routing)
function route() {
  const v = location.hash.slice(1);
  const view = v === 'settings' || v === 'photos' ? v : 'camera';
  $('v-camera').hidden = view !== 'camera';
  $('v-settings').hidden = view !== 'settings';
  $('v-photos').hidden = view !== 'photos';
  if (view !== 'photos') closeViewer();
  if (view === 'camera') { if (!running) startCamera(); }
  else {
    stopCamera();
    window.scrollTo(0, 0);
    renderPhotos();
    if (view === 'settings') {
      let c = {}; try { c = JSON.parse(localStorage.getItem('jumpshot-caps') || '{}'); } catch {}
      $('zoomHint').textContent = c.zoom === false ? 'This camera / browser does not offer zoom.' : 'You can also pinch on the camera preview.';
      $('expHint').textContent = c.exp === false ? 'This camera / browser does not offer exposure control.' : 'Brighten for backlit jumpers, darken against a bright sky.';
    }
  }
}
addEventListener('hashchange', route);
document.addEventListener('visibilitychange', () => {
  if (document.hidden) { if (running) stopCamera(); }
  else if ($('v-camera').hidden === false) startCamera();
});

// ------------------------------------------------------------------ install + offline
let installEvt = null;
addEventListener('beforeinstallprompt', (e) => { e.preventDefault(); installEvt = e; $('install').hidden = false; });
$('install').onclick = async () => { $('install').hidden = true; await installEvt?.prompt(); installEvt = null; };
addEventListener('appinstalled', () => { $('install').hidden = true; });
if ('serviceWorker' in navigator) navigator.serviceWorker.register('./sw.js').catch((e) => console.warn('SW', e));

refreshArm();
refreshThumb();
route();
