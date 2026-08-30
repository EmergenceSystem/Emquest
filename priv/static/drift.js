/**
 * drift.js — em_drift feed client
 *
 * Infinite scroll feed driven by Emquest /query SSE.
 * Cards lazy-fetch their preview via /preview?url=... when they
 * enter the viewport (IntersectionObserver).
 */

/* ================================================================== */
/* Config                                                             */
/* ================================================================== */
const DEFAULT_TOPICS = [
    'Erlang',
    'Claude AI',
    'distributed systems',
    'functional programming',
    'software architecture',
];
const SUGGESTED_TOPICS = [
    'Rust', 'Linux', 'space', 'science', 'AI safety', 'cryptography',
    'philosophy', 'music', 'design', 'mathematics', 'biology', 'economics',
    'privacy', 'open source', 'robotics', 'climate', 'history', 'security',
];
let TOPICS = DEFAULT_TOPICS.slice();

/* ── IndexedDB: persist the user's chosen themes ─────────────────── */
const IDB_NAME = 'emdrift', IDB_STORE = 'prefs', IDB_KEY = 'topics';
function idbOpen() {
    return new Promise((resolve, reject) => {
        const r = indexedDB.open(IDB_NAME, 1);
        r.onupgradeneeded = () => r.result.createObjectStore(IDB_STORE);
        r.onsuccess = () => resolve(r.result);
        r.onerror   = () => reject(r.error);
    });
}
async function loadTopics() {
    try {
        const db = await idbOpen();
        const val = await new Promise(res => {
            const req = db.transaction(IDB_STORE, 'readonly')
                          .objectStore(IDB_STORE).get(IDB_KEY);
            req.onsuccess = () => res(req.result);
            req.onerror   = () => res(undefined);
        });
        if (Array.isArray(val) && val.length) TOPICS = val;
    } catch (_) { /* IndexedDB unavailable → keep defaults */ }
}
async function persistTopics() {
    try {
        const db = await idbOpen();
        await new Promise(res => {
            const req = db.transaction(IDB_STORE, 'readwrite')
                          .objectStore(IDB_STORE).put(TOPICS.slice(), IDB_KEY);
            req.onsuccess = () => res();
            req.onerror   = () => res();
        });
    } catch (_) {}
}

/** Trigger next batch when sentinel is within this many px of viewport */
const LOAD_THRESHOLD = '200px';

/* ================================================================== */
/* State                                                              */
/* ================================================================== */
let activeTopic   = 0;
let loading       = false;
let totalItems    = 0;
/** Index of the keyboard-focused card (-1 = none) */
let focusedIndex  = -1;
/** @type {IntersectionObserver} watches cards for preview fetch */
let previewObserver;
/** @type {IntersectionObserver} watches sentinel for next batch */
let sentinelObserver;

/* ================================================================== */
/* Ambient canvas (shared with emergence.js pattern)                  */
/* ================================================================== */
(function initCanvas() {
    const canvas = document.getElementById('bg-canvas');
    if (!canvas) return;
    const ctx = canvas.getContext('2d');
    let dots = [];
    function resize() {
        canvas.width  = window.innerWidth;
        canvas.height = window.innerHeight;
        const spacing = canvas.width / 40;
        const rows    = Math.ceil(canvas.height / spacing) + 1;
        dots = [];
        for (let r = 0; r <= rows; r++)
            for (let c = 0; c <= 40; c++)
                dots.push({ x: c*spacing, y: r*spacing,
                    phase: Math.random()*Math.PI*2,
                    speed: 0.4+Math.random()*0.6 });
    }
    function draw(ts) {
        ctx.clearRect(0, 0, canvas.width, canvas.height);
        const t = ts * 0.001;
        dots.forEach(d => {
            const a = 0.05 + 0.05*Math.sin(t*d.speed+d.phase);
            ctx.beginPath();
            ctx.arc(d.x, d.y, 1.5, 0, Math.PI*2);
            ctx.fillStyle = `rgba(0,220,100,${a})`;
            ctx.fill();
        });
        requestAnimationFrame(draw);
    }
    window.addEventListener('resize', resize);
    resize();
    requestAnimationFrame(draw);
})();

/* ================================================================== */
/* Clock                                                              */
/* ================================================================== */
function updateClock() {
    const el = document.getElementById('clock');
    if (!el) return;
    const n = new Date(), p = v => String(v).padStart(2,'0');
    el.textContent =
        `${n.getFullYear()}-${p(n.getMonth()+1)}-${p(n.getDate())} `
        +`${p(n.getHours())}:${p(n.getMinutes())}:${p(n.getSeconds())}`;
}
setInterval(updateClock, 1000);
updateClock();

/* ================================================================== */
/* Header scroll shadow                                               */
/* ================================================================== */
window.addEventListener('scroll', () => {
    document.getElementById('drift-header')
        ?.classList.toggle('scrolled', window.scrollY > 8);
}, { passive: true });

/* ================================================================== */
/* Topic chips                                                        */
/* ================================================================== */
function buildTopics() {
    const nav = document.getElementById('drift-topics');
    if (!nav) return;
    nav.innerHTML = '';
    if (activeTopic >= TOPICS.length) activeTopic = 0;
    TOPICS.forEach((label, i) => {
        const chip = document.createElement('div');
        chip.className = 'topic-chip' + (i === activeTopic ? ' active' : '');
        const name = document.createElement('span');
        name.className = 'chip-label';
        name.textContent = label;
        name.addEventListener('click', () => selectTopic(i));
        const x = document.createElement('button');
        x.className = 'chip-x';
        x.type = 'button';
        x.textContent = '\u00d7';
        x.title = 'Remove theme';
        x.addEventListener('click', (e) => { e.stopPropagation(); removeTopic(i); });
        chip.appendChild(name);
        chip.appendChild(x);
        nav.appendChild(chip);
    });
    const add = document.createElement('button');
    add.className = 'topic-add';
    add.type = 'button';
    add.textContent = '+';
    add.title = 'Add a theme';
    add.addEventListener('click', (e) => { e.stopPropagation(); toggleAddPanel(add); });
    nav.appendChild(add);
}

function removeTopic(i) {
    TOPICS.splice(i, 1);
    if (activeTopic >= TOPICS.length) activeTopic = Math.max(0, TOPICS.length - 1);
    persistTopics();
    buildTopics();
    clearFeed();
    if (TOPICS.length) loadBatch();
}

function addTopic(label) {
    const t = (label || '').trim();
    if (!t) return;
    if (TOPICS.some(x => x.toLowerCase() === t.toLowerCase())) { closeAddPanel(); return; }
    TOPICS.push(t);
    persistTopics();
    activeTopic = TOPICS.length - 1;
    buildTopics();
    clearFeed();
    loadBatch();
    closeAddPanel();
}

function toggleAddPanel(anchorEl) {
    if (document.getElementById('topic-panel')) { closeAddPanel(); return; }
    const panel = document.createElement('div');
    panel.id = 'topic-panel';
    panel.className = 'topic-panel';
    const input = document.createElement('input');
    input.type = 'text';
    input.placeholder = 'add a theme\u2026';
    input.className = 'topic-panel-input';
    input.addEventListener('keydown', e => {
        if (e.key === 'Enter') addTopic(input.value);
        else if (e.key === 'Escape') closeAddPanel();
    });
    panel.appendChild(input);
    const sugg = document.createElement('div');
    sugg.className = 'topic-suggest';
    SUGGESTED_TOPICS
        .filter(s => !TOPICS.some(x => x.toLowerCase() === s.toLowerCase()))
        .forEach(s => {
            const b = document.createElement('button');
            b.type = 'button';
            b.className = 'suggest-chip';
            b.textContent = s;
            b.addEventListener('click', () => addTopic(s));
            sugg.appendChild(b);
        });
    panel.appendChild(sugg);
    document.body.appendChild(panel);
    const r = anchorEl.getBoundingClientRect();
    panel.style.top  = (r.bottom + 6) + 'px';
    panel.style.left = Math.max(8, Math.min(r.left, window.innerWidth - 296)) + 'px';
    input.focus();
    setTimeout(() => document.addEventListener('click', outsideAddPanel), 0);
}
function outsideAddPanel(e) {
    const panel = document.getElementById('topic-panel');
    if (panel && !panel.contains(e.target) && !e.target.classList.contains('topic-add')) {
        closeAddPanel();
    }
}
function closeAddPanel() {
    const panel = document.getElementById('topic-panel');
    if (panel) panel.remove();
    document.removeEventListener('click', outsideAddPanel);
}

function selectTopic(index) {
    if (index === activeTopic) return;
    activeTopic = index;
    document.querySelectorAll('.topic-chip').forEach((c, i) =>
        c.classList.toggle('active', i === index));
    clearFeed();
    loadBatch();
}

/* ================================================================== */
/* Feed management                                                    */
/* ================================================================== */
function clearFeed() {
    const feed = document.getElementById('drift-feed');
    if (feed) feed.innerHTML = '';
    totalItems = 0;
    updateFooter();
}

function updateFooter() {
    const el = document.getElementById('footer-count');
    if (el) el.textContent = `${totalItems} item${totalItems !== 1 ? 's' : ''}`;
}

/* ================================================================== */
/* Batch loading via /query SSE                                       */
/* ================================================================== */
async function loadBatch() {
    if (loading || !TOPICS.length) return;
    loading = true;

    const sentinel = document.getElementById('drift-sentinel');
    if (sentinel) sentinel.style.opacity = '1';

    const query = TOPICS[activeTopic];
    const topicIndex = activeTopic;

    try {
        const resp = await fetch('/query', {
            method:  'POST',
            headers: { 'Content-Type': 'application/json' },
            body:    JSON.stringify({ query }),
        });
        if (!resp.ok) throw new Error(`HTTP ${resp.status}`);

        const reader  = resp.body.getReader();
        const decoder = new TextDecoder();
        let   buffer  = '';

        while (true) {
            const { done, value } = await reader.read();
            if (done) break;
            buffer += decoder.decode(value, { stream: true });
            const parts = buffer.split('\n\n');
            buffer = parts.pop();
            for (const part of parts) {
                const line = part.trim();
                if (!line.startsWith('data: ')) continue;
                try {
                    const ev = JSON.parse(line.slice(6));
                    if (ev.type === 'item' && ev.item?.url) {
                        appendCard(ev.item, topicIndex);
                    }
                } catch (_) {}
            }
        }
    } catch (err) {
        console.error('[drift]', err);
    } finally {
        loading = false;
        if (sentinel) sentinel.style.opacity = '0.4';
    }
}

/* ================================================================== */
/* Card creation                                                      */
/* ================================================================== */
/* ── Media card rendering (shared look with the search page) ─────── */
function safeUrl(s) {
    if (!s) return null;
    const t = String(s).trim();
    return /^https?:\/\//i.test(t) ? t : null;
}
function mediaFooter(item) {
    const bits = [];
    if (item.source)  bits.push(escHtml(item.source));
    if (item.license) bits.push(escHtml(item.license));
    if (item.author)  bits.push(escHtml(item.author));
    return bits.length ? `<span class="media-license">${bits.join(' · ')}</span>` : '';
}
function fmtDur(s) {
    s = parseInt(s, 10) || 0;
    const m = Math.floor(s / 60), ss = String(s % 60).padStart(2, '0');
    return `${m}:${ss}`;
}
function buildMediaBody(item) {
    const t     = item.media_type;
    const title = (item.label && item.label !== 'Result') ? escHtml(item.label) : '';
    const foot  = mediaFooter(item);
    const thumb = item.thumbnail ? safeUrl(item.thumbnail) : '';

    if (t === 'audio') {
        const src = safeUrl(item.media_url) || '';
        return `
            <div class="media-card media-audio">
                <div class="media-audio-head">
                    ${thumb ? `<img class="media-thumb media-thumb--audio" loading="lazy"
                         referrerpolicy="no-referrer" src="${escAttr(thumb)}" alt=""
                         onerror="this.remove()">` : ''}
                    <div class="media-meta">
                        ${title ? `<span class="item-title">${title}</span>` : ''}
                        ${item.value ? `<p class="item-resume">${escHtml(item.value)}</p>` : ''}
                        ${foot}
                    </div>
                </div>
                ${src ? `<div class="aplayer">
                    <button class="aplayer-play" type="button" aria-label="Play / pause">
                        <svg class="ic-play" viewBox="0 0 24 24"><polygon points="6 4 20 12 6 20"/></svg>
                        <svg class="ic-pause" viewBox="0 0 24 24"><rect x="6" y="4" width="4" height="16"/><rect x="14" y="4" width="4" height="16"/></svg>
                    </button>
                    <div class="aplayer-bar"><div class="aplayer-fill"></div></div>
                    <span class="aplayer-time">0:00</span>
                    <button class="aplayer-vol-btn" type="button" aria-label="Mute">
                        <svg class="ic-vol" viewBox="0 0 24 24"><polygon points="4 9 4 15 8 15 13 20 13 4 8 9"/><path d="M16 8.5a4 4 0 0 1 0 7"/></svg>
                        <svg class="ic-mute" viewBox="0 0 24 24"><polygon points="4 9 4 15 8 15 13 20 13 4 8 9"/><line x1="16" y1="9" x2="21" y2="15"/><line x1="21" y1="9" x2="16" y2="15"/></svg>
                    </button>
                    <input class="aplayer-vol" type="range" min="0" max="1" step="0.05" value="1" aria-label="Volume">
                    <a class="aplayer-dl" href="${escAttr(src)}" target="_blank" rel="noopener" aria-label="Open URL" title="Open URL">
                        <svg viewBox="0 0 24 24"><path d="M14 4h6v6"/><line x1="20" y1="4" x2="10" y2="14"/><path d="M18 13v6a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1V7a1 1 0 0 1 1-1h6"/></svg>
                    </a>
                    <audio class="aplayer-audio" preload="none" src="${escAttr(src)}"></audio>
                </div>` : ''}
            </div>`;
    }

    const durBadge = (t === 'video' && item.duration)
        ? `<span class="media-duration">${escHtml(fmtDur(item.duration))}</span>` : '';
    const play     = (t === 'video') ? `<span class="media-play">▶</span>` : '';
    const thumbHtml = thumb
        ? `<img class="media-thumb" loading="lazy" referrerpolicy="no-referrer"
             src="${escAttr(thumb)}" alt="${escAttr(item.label || '')}"
             onerror="mediaImgError(this)">`
        : `<span class="media-thumb media-thumb--placeholder" data-type="${escAttr(t)}"></span>`;
    return `
        <div class="media-card media-${escAttr(t)}">
            <div class="media-thumb-wrap">${thumbHtml}${play}${durBadge}</div>
            <div class="media-meta">
                ${title ? `<span class="item-title">${title}</span>` : ''}
                ${item.value ? `<p class="item-resume">${escHtml(item.value)}</p>` : ''}
                ${foot}
            </div>
        </div>`;
}
function mediaImgError(img) {
  if (img.closest('.media-image')) {
    const card = img.closest('.item-card, .drift-card');
    if (card) { card.remove(); return; }
  }
  img.classList.add('media-thumb--broken');
}

let _lightbox = null;
function openLightbox(src) {
    if (!_lightbox) {
        _lightbox = document.createElement('div');
        _lightbox.id = 'media-lightbox';
        _lightbox.className = 'lightbox';
        _lightbox.innerHTML = '<img class="lightbox-img" referrerpolicy="no-referrer" alt="">';
        _lightbox.addEventListener('click', () => _lightbox.classList.remove('open'));
        document.addEventListener('keydown', e => {
            if (e.key === 'Escape' && _lightbox) _lightbox.classList.remove('open');
        });
        document.body.appendChild(_lightbox);
    }
    _lightbox.querySelector('img').src = src;
    _lightbox.classList.add('open');
}
function initAudioPlayer(root) {
  const el    = root.querySelector('.aplayer');
  const audio = root.querySelector('audio.aplayer-audio');
  const btn   = root.querySelector('.aplayer-play');
  const bar   = root.querySelector('.aplayer-bar');
  const fill  = root.querySelector('.aplayer-fill');
  const tEl   = root.querySelector('.aplayer-time');
  if (!el || !audio || !btn) return;
  const fmt = s => { s = Math.floor(s || 0); return Math.floor(s / 60) + ':' + String(s % 60).padStart(2, '0'); };
  btn.addEventListener('click', e => { e.stopPropagation(); if (audio.paused) audio.play(); else audio.pause(); });
  audio.addEventListener('play',  () => el.classList.add('playing'));
  audio.addEventListener('pause', () => el.classList.remove('playing'));
  audio.addEventListener('ended', () => el.classList.remove('playing'));
  audio.addEventListener('loadedmetadata', () => { if (tEl) tEl.textContent = '0:00 / ' + fmt(audio.duration); });
  audio.addEventListener('timeupdate', () => {
    const d = audio.duration || 0, c = audio.currentTime || 0;
    if (fill) fill.style.width = d ? (c / d * 100) + '%' : '0%';
    if (tEl)  tEl.textContent  = fmt(c) + (d ? ' / ' + fmt(d) : '');
  });
  if (bar) bar.addEventListener('click', e => {
    e.stopPropagation();
    const r = bar.getBoundingClientRect();
    const p = Math.min(1, Math.max(0, (e.clientX - r.left) / r.width));
    if (audio.duration) audio.currentTime = p * audio.duration;
  });
  const volBtn = root.querySelector('.aplayer-vol-btn');
  const vol    = root.querySelector('.aplayer-vol');
  const dl     = root.querySelector('.aplayer-dl');
  if (vol) vol.addEventListener('input', e => {
    e.stopPropagation();
    audio.volume = parseFloat(vol.value);
    audio.muted = audio.volume === 0;
    el.classList.toggle('muted', audio.muted);
  });
  if (volBtn) volBtn.addEventListener('click', e => {
    e.stopPropagation();
    audio.muted = !audio.muted;
    el.classList.toggle('muted', audio.muted);
    if (vol) vol.value = audio.muted ? 0 : (audio.volume || 1);
  });
  if (dl) dl.addEventListener('click', e => e.stopPropagation());
}

function appendCard(item, topicIndex) {
    const feed = document.getElementById('drift-feed');
    if (!feed) return;

    const card = document.createElement('article');
    card.className = `drift-card active-topic-${topicIndex % 5}`;
    card.style.animationDelay = `${Math.min((totalItems % 10) * 40, 300)}ms`;
    card.dataset.url = item.url;
    card.dataset.mtype = item.media_type || 'text';
    {
        const bar = document.getElementById('drift-typebar');
        if (bar) {
            const checked = [...bar.querySelectorAll('input:checked')].map(c => c.value);
            if (checked.length && !checked.includes(card.dataset.mtype)) card.classList.add('type-hidden');
        }
    }

    if (item.media_type) {
        /* Media item — same media card as the search page */
        card.classList.add('drift-card--media');
        card.innerHTML =
            `<div class="card-topic-tag">${escHtml(TOPICS[topicIndex])}</div>` +
            buildMediaBody(item);
        if (item.media_type === 'audio') {
            initAudioPlayer(card);
        } else if (item.media_type === 'image') {
            card.addEventListener('click', e => {
                if (e.target.closest('a')) return;
                const full = safeUrl(item.media_url) || safeUrl(item.thumbnail);
                if (full) openLightbox(full);
            });
        } else if (item.media_type === 'video') {
            card.addEventListener('click', e => {
                if (e.target.closest('a, audio')) return;
                const u = safeUrl(item.url) || safeUrl(item.media_url);
                if (u) window.open(u, '_blank', 'noopener');
            });
        }
        feed.appendChild(card);
        totalItems++;
        updateFooter();
        return;
    }

    const previewUrl = escAttr(item.url);
    const label   = item.label && item.label !== 'Result' ? item.label : hostnameOf(item.url);

    card.innerHTML = `
        <div class="card-topic-tag">${escHtml(TOPICS[topicIndex])}</div>
        <div class="card-title">${escHtml(label)}</div>
        <div class="card-url">${escHtml(item.url)}</div>
        <div class="card-preview loading" data-preview-url="${previewUrl}"></div>
        <button class="card-open-btn" aria-label="Open link" tabindex="0">↗</button>
    `;

    /* Desktop: single click on the ↗ button */
    card.querySelector('.card-open-btn').addEventListener('click', e => {
        e.stopPropagation();
        window.open(item.url, '_blank', 'noopener');
    });

    /* Mobile: double-tap anywhere on the card */
    let lastTap = 0;
    card.addEventListener('touchend', e => {
        const now = Date.now();
        if (now - lastTap < 300) {
            e.preventDefault();
            window.open(item.url, '_blank', 'noopener');
        }
        lastTap = now;
    }, { passive: false });

    feed.appendChild(card);
    totalItems++;
    updateFooter();

    /* watch for viewport entry to fetch preview */
    const previewEl = card.querySelector('.card-preview');
    if (previewEl && previewObserver) previewObserver.observe(previewEl);
}

/* ================================================================== */
/* Lazy preview fetch (IntersectionObserver)                          */
/* ================================================================== */
function initPreviewObserver() {
    previewObserver = new IntersectionObserver((entries) => {
        entries.forEach(entry => {
            if (!entry.isIntersecting) return;
            const el  = entry.target;
            const url = el.dataset.previewUrl;
            if (!url) return;
            previewObserver.unobserve(el);
            fetchPreview(el, url);
        });
    }, { rootMargin: '150px' });
}

async function fetchPreview(el, url) {
    try {
        const resp = await fetch(`/preview?url=${encodeURIComponent(url)}`);
        if (!resp.ok) throw new Error('preview fetch failed');
        const data = await resp.json();
        el.classList.remove('loading');
        el.textContent = data.description || '';
    } catch (_) {
        el.classList.remove('loading');
        el.textContent = '';
    }
}

/* ================================================================== */
/* Keyboard navigation                                                */
/* ================================================================== */
function cards() {
    return Array.from(document.querySelectorAll('#drift-feed .drift-card'));
}

function focusCard(index) {
    const all = cards();
    if (!all.length) return;
    const next = Math.max(0, Math.min(index, all.length - 1));

    all.forEach((c, i) => c.classList.toggle('card-focused', i === next));
    focusedIndex = next;

    all[next].scrollIntoView({ behavior: 'smooth', block: 'nearest' });
}

function initKeyboard() {
    document.addEventListener('keydown', e => {
        /* Don't hijack input fields */
        if (e.target.tagName === 'INPUT' || e.target.tagName === 'TEXTAREA') return;

        switch (e.key) {
            case 'ArrowDown':
            case 'j':
                e.preventDefault();
                focusCard(focusedIndex < 0 ? 0 : focusedIndex + 1);
                break;
            case 'ArrowUp':
            case 'k':
                e.preventDefault();
                focusCard(focusedIndex <= 0 ? 0 : focusedIndex - 1);
                break;
            case 'Enter':
            case 'o': {
                if (focusedIndex < 0) return;
                const c = cards()[focusedIndex];
                if (c?.dataset.url) window.open(c.dataset.url, '_blank', 'noopener');
                break;
            }
            case 'Escape':
                cards().forEach(c => c.classList.remove('card-focused'));
                focusedIndex = -1;
                break;
        }
    });
}

/* ================================================================== */
/* Mouse drag-to-scroll                                               */
/* ================================================================== */
function initDrag() {
    const feed = document.getElementById('drift-feed');
    if (!feed) return;

    let dragging  = false;
    let startY    = 0;
    let startScroll = 0;
    /** px moved — used to distinguish drag from click */
    let moved     = 0;

    feed.addEventListener('mousedown', e => {
        /* Only main button, ignore clicks on the ↗ button */
        if (e.button !== 0 || e.target.closest('.card-open-btn')) return;
        dragging    = true;
        startY      = e.clientY;
        startScroll = window.scrollY;
        moved       = 0;
        feed.classList.add('dragging');
        e.preventDefault();
    });

    document.addEventListener('mousemove', e => {
        if (!dragging) return;
        const delta = startY - e.clientY;
        moved = Math.abs(delta);
        window.scrollTo({ top: startScroll + delta, behavior: 'instant' });
    });

    document.addEventListener('mouseup', () => {
        if (!dragging) return;
        dragging = false;
        feed.classList.remove('dragging');
    });

    /* Prevent accidental card open after a drag */
    feed.addEventListener('click', e => {
        if (moved > 6) e.stopImmediatePropagation();
        moved = 0;
    }, true);
}

/* ================================================================== */
/* Infinite scroll sentinel                                           */
/* ================================================================== */
function initSentinelObserver() {
    const sentinel = document.getElementById('drift-sentinel');
    if (!sentinel) return;
    sentinelObserver = new IntersectionObserver((entries) => {
        if (entries[0].isIntersecting && !loading) loadBatch();
    }, { rootMargin: LOAD_THRESHOLD });
    sentinelObserver.observe(sentinel);
}

/* ================================================================== */
/* Utilities                                                          */
/* ================================================================== */
function escHtml(s) {
    if (s == null) return '';
    return String(s)
        .replace(/&/g,'&amp;').replace(/</g,'&lt;')
        .replace(/>/g,'&gt;').replace(/"/g,'&quot;')
        .replace(/'/g,'&#39;');
}
function escAttr(s) { return s ? String(s).replace(/"/g,'%22') : '#'; }
function hostnameOf(url) {
    try { return new URL(url).hostname; } catch (_) { return url; }
}

/* ================================================================== */
/* Boot                                                               */
/* ================================================================== */
/* ── Media-type filter (checkboxes) + IndexedDB persistence ─────── */
const _MT_DB = 'emergence', _MT_STORE = 'prefs', _MT_KEY = 'mediaTypes';
function _mtDbOpen() {
  return new Promise((res, rej) => {
    const r = indexedDB.open(_MT_DB, 1);
    r.onupgradeneeded = () => r.result.createObjectStore(_MT_STORE);
    r.onsuccess = () => res(r.result);
    r.onerror = () => rej(r.error);
  });
}
function applyDriftFilter() {
  const bar = document.getElementById('drift-typebar');
  if (!bar) return;
  const checked = [...bar.querySelectorAll('input:checked')].map(c => c.value);
  const showAll = checked.length === 0;
  document.querySelectorAll('#drift-feed .drift-card').forEach(card => {
    const t = card.dataset.mtype || 'text';
    card.classList.toggle('type-hidden', !showAll && !checked.includes(t));
  });
}
async function persistDriftTypes() {
  try {
    const bar = document.getElementById('drift-typebar');
    if (!bar) return;
    const vals = [...bar.querySelectorAll('input')].filter(c => c.checked).map(c => c.value);
    const db = await _mtDbOpen();
    await new Promise(res => {
      const req = db.transaction(_MT_STORE, 'readwrite').objectStore(_MT_STORE).put(vals, _MT_KEY);
      req.onsuccess = () => res(); req.onerror = () => res();
    });
  } catch (_) {}
}
async function restoreDriftTypes() {
  try {
    const db = await _mtDbOpen();
    const vals = await new Promise(res => {
      const req = db.transaction(_MT_STORE, 'readonly').objectStore(_MT_STORE).get(_MT_KEY);
      req.onsuccess = () => res(req.result); req.onerror = () => res(undefined);
    });
    const bar = document.getElementById('drift-typebar');
    if (!bar || !Array.isArray(vals)) return;
    bar.querySelectorAll('input').forEach(c => { c.checked = vals.includes(c.value); });
    applyDriftFilter();
  } catch (_) {}
}
function initDriftFilter() {
  const bar = document.getElementById('drift-typebar');
  if (bar) bar.addEventListener('change', () => { applyDriftFilter(); persistDriftTypes(); });
}

initPreviewObserver();
initSentinelObserver();
initKeyboard();
initDrag();
(async () => {
    await loadTopics();
    buildTopics();
    initDriftFilter();
    await restoreDriftTypes();
    if (TOPICS.length) loadBatch();
})();
