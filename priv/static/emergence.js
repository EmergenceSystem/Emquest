/**
 * emergence.js — Emquest Browser Client (SSE streaming)
 *
 * SSE events:
 *   {type:"status",  message:"..."}          → progress log line
 *   {type:"item",    sid:N, item:{...}}       → append result card immediately
 *   {type:"reorder", sids:[N,...],
 *          scores:{N:0-3,...}}                → reorder + score cards
 *   {type:"answer",  message:"..."}           → slide-in answer panel
 *   {type:"error",   message:"..."}           → error card
 *
 * Card types (auto-detected from item fields):
 *   item.url   → web   : title link + url + resume
 *   item.ips   → dns   : domain + IP badges
 *   neither    → generic: label + value
 */

/* ================================================================== */
/* Ambient canvas                                                     */
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
                dots.push({
                    x: c * spacing, y: r * spacing,
                    phase: Math.random() * Math.PI * 2,
                    speed: 0.4 + Math.random() * 0.6
                });
    }

    function draw(ts) {
        ctx.clearRect(0, 0, canvas.width, canvas.height);
        const t = ts * 0.001;
        dots.forEach(d => {
            const a = 0.05 + 0.05 * Math.sin(t * d.speed + d.phase);
            ctx.beginPath();
            ctx.arc(d.x, d.y, 1.5, 0, Math.PI * 2);
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
    const n = new Date(), p = v => String(v).padStart(2, '0');
    el.textContent =
        `${n.getFullYear()}-${p(n.getMonth()+1)}-${p(n.getDate())} `
        + `${p(n.getHours())}:${p(n.getMinutes())}:${p(n.getSeconds())}`;
}
setInterval(updateClock, 1000);
updateClock();

/* ================================================================== */
/* Header scroll shadow                                               */
/* ================================================================== */
window.addEventListener('scroll', () => {
    document.getElementById('app-header')
        ?.classList.toggle('scrolled', window.scrollY > 8);
}, { passive: true });

/* ================================================================== */
/* Peer count (from local em-pop table)                               */
/* ================================================================== */
async function refreshPeerCount() {
    try {
        const r = await fetch('/network/peers');
        if (!r.ok) return;
        const peers = await r.json();
        const n  = Array.isArray(peers) ? peers.length : 0;
        const el = document.getElementById('footer-agent-count');
        if (el) el.textContent = `${n} peer${n !== 1 ? 's' : ''} · network ↗`;
        if (el) { el.style.cursor = 'pointer'; el.onclick = () => location.href = '/network'; }
    } catch (_) {}
}
refreshPeerCount();
setInterval(refreshPeerCount, 15000);

/* ================================================================== */
/* Textarea auto-resize                                               */
/* ================================================================== */
const queryInput = document.getElementById('query-input');
queryInput?.addEventListener('input', function () {
    this.style.height = 'auto';
    this.style.height = Math.min(this.scrollHeight, 120) + 'px';
});

/* ================================================================== */
/* Submit                                                             */
/* ================================================================== */
queryInput?.addEventListener('keydown', e => {
    if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); submitQuery(); }
});
document.getElementById('send-btn')?.addEventListener('click', submitQuery);

/* ── Per-query state ─────────────────────────────────────────────── */
/** @type {Map<number, HTMLElement>} sid → card element */
let streamCards = new Map();

async function submitQuery() {
    const query = queryInput?.value.trim();
    if (!query) return;

    /* An image URL in the message is handled by velora, not the search pipeline. */
    const imgUrl = extractImageUrl(query);
    if (imgUrl) {
        runMedia(fetch('/media', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ url: imgUrl }),
        }), imgUrl);
        return;
    }

    const btn     = document.getElementById('send-btn');
    const results = document.getElementById('results');
    const empty   = document.getElementById('empty-state');

    /* Reset state */
    streamCards = new Map();

    btn.classList.add('loading');
    btn.disabled   = true;
    empty.hidden   = true;
    results.hidden = false;

    /* Pre-render layout: user prompt echo + progress log above results */
    results.innerHTML =
        userPromptHtml(query) + `
        <div class="progress-log" id="progress-log">
            <div class="pbar"><div class="pbar-fill" id="pbar-fill"></div></div>
            <span class="pbar-count" id="pbar-count">0 results</span>
        </div>
        <ul class="items-list" id="results-list"></ul>
    `;

    hideAnswerPanel();
    initTypeFilters();
    const tfbar = document.getElementById('type-filters');
    if (tfbar) tfbar.hidden = false;
    startProgress();

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
                if (line.startsWith('data: ')) {
                    try {
                        handleEvent(JSON.parse(line.slice(6)));
                    } catch (e) {
                        console.warn('[emquest] parse error', e);
                    }
                }
            }
        }
    } catch (err) {
        console.error('[emquest]', err);
        const results2 = document.getElementById('results');
        if (results2) results2.innerHTML = renderError(err.message);
    } finally {
        btn.classList.remove('loading');
        btn.disabled = false;
        /* Fallback: remove progress log if reorder never arrived */
        finishProgress();
        const log = document.getElementById('progress-log');
        if (log) {
            setTimeout(() => {
                log.style.transition = 'opacity 1.2s ease';
                log.style.opacity    = '0';
                setTimeout(() => log.remove(), 1200);
            }, 1000);
        }
    }
}

/* ================================================================== */
/* SSE event handler                                                  */
/* ================================================================== */
function handleEvent(event) {
    switch (event.type) {

        /* ── Progress line ─────────────────────────────────────── */
        case 'status':
            /* progress is shown as a bar + live count, not per-call lines */
            break;

        /* ── Stream one result card immediately ────────────────── */
        case 'item': {
            const list = document.getElementById('results-list');
            if (!list) return;
            const card = buildCard(event.item, event.sid, streamCards.size);
            list.appendChild(card);
            streamCards.set(event.sid, card);
            applyTypeFilter();
            bumpCount();
            break;
        }

        /* ── Reorder + score cards after ranking ───────────────── */
        case 'reorder': {
            const list   = document.getElementById('results-list');
            const sids   = event.sids   || [];
            const scores = event.scores || {};

            /* Safety: empty sids = LLM failed, keep cards as-is */
            if (sids.length === 0) break;

            /* Hide deduped items */
            streamCards.forEach((card, sid) => {
                if (!sids.includes(sid)) {
                    card.classList.add('card-removed');
                    setTimeout(() => card.remove(), 350);
                }
            });

            /* Reorder DOM + update score accent, re-number */
            sids.forEach((sid, pos) => {
                const card = streamCards.get(sid);
                if (!card || !list) return;

                /* Keys come as strings from JSON (integer_to_binary in Erlang) */
                const score = scores[String(sid)] ?? 0;
                card.dataset.score = score;
                card.className = card.className.replace(/\bscore-\d\b/g, '').trim();
                card.classList.add(`score-${score}`);

                /* Update index number */
                const idx = card.querySelector('.item-index');
                if (idx) idx.textContent = String(pos + 1).padStart(2, '0');

                list.appendChild(card); /* move to end in ranked order */
            });

            /* Finalise the progress bar + count, then fade it out */
            finishProgress();
            _resultCount = sids.length;
            updateCount();
            const log = document.getElementById('progress-log');
            if (log) {
                setTimeout(() => {
                    log.style.transition = 'opacity 1.2s ease';
                    log.style.opacity    = '0';
                    setTimeout(() => log.remove(), 1200);
                }, 2000);
            }
            break;
        }

        /* ── Error ─────────────────────────────────────────────── */
        case 'error': {
            const results = document.getElementById('results');
            if (results) results.innerHTML = renderError(event.message);
            break;
        }
    }
}

/* ================================================================== */
/* Card builder                                                        */
/* ================================================================== */

/**
 * Builds a result <li> card element.
 * @param {object} item  - normalised item from server
 * @param {number} sid   - stream id
 * @param {number} pos   - visual position index
 */
function buildCard(item, sid, pos) {
    const li = document.createElement('li');
    li.className = `item-card score-${item.score ?? 0}`;
    li.dataset.sid = sid;
    li.dataset.mtype = item.media_type || 'text';
    li.style.animationDelay = `${Math.min(pos * 50, 400)}ms`;

    li.innerHTML = buildCardBody(item, pos);

    /* Media cards: image → lightbox, video → source, audio → no navigation */
    if (item.media_type === 'image') {
        const full = safeUrl(item.media_url) || safeUrl(item.thumbnail);
        if (full) {
            li.classList.add('item-card--media');
            li.addEventListener('click', e => {
                if (e.target.closest('a')) return;
                openLightbox(full);
            });
        }
    } else if (item.media_type === 'video') {
        const u = safeUrl(item.url) || safeUrl(item.media_url);
        if (u) {
            li.classList.add('item-card--media');
            li.addEventListener('click', e => {
                if (e.target.closest('a, audio')) return;
                window.open(u, '_blank', 'noopener');
            });
        }
    } else if (item.media_type === 'audio') {
        li.classList.add('item-card--media');
        initAudioPlayer(li);
    } else if (item.url) {
        const url = safeUrl(item.url);
        if (url) {
            li.classList.add('item-card--link');
            li.addEventListener('click', e => {
                if (e.target.closest('a')) return; /* let native link work */
                window.open(url, '_blank', 'noopener');
            });
        }
    }

    return li;
}

function buildCardBody(item, pos) {
    const num = String(pos + 1).padStart(2, '0');
    let body = '';

    if (item.media_type) {
        body = buildMediaBody(item);
    } else if (item.url) {
        /* ── Web result ────────────────────────────────────────── */
        const url  = safeUrl(item.url) || '#';
        const hasTitle = item.label && item.label !== 'Result' && item.label !== item.url
                         && item.label !== hostnameOf(item.url);
        if (hasTitle) {
            /* title + url + resume */
            body = `
                <div class="item-web">
                    <a href="${escAttr(url)}" target="_blank" rel="noopener"
                       class="item-title">${escHtml(item.label)}</a>
                    <span class="item-url">${escHtml(item.url)}</span>
                    ${item.value ? `<p class="item-resume">${escHtml(item.value)}</p>` : ''}
                </div>
                <span class="item-arrow">↗</span>
            `;
        } else {
            /* url as main element + resume */
            body = `
                <div class="item-web">
                    <a href="${escAttr(url)}" target="_blank" rel="noopener"
                       class="item-url item-url--hero">${escHtml(item.url)}</a>
                    ${item.value ? `<p class="item-resume">${escHtml(item.value)}</p>` : ''}
                </div>
                <span class="item-arrow">↗</span>
            `;
        }
    } else if (Array.isArray(item.ips) && item.ips.length) {
        /* ── DNS result ────────────────────────────────────────── */
        const badges = item.ips
            .map(ip => `<span class="ip-badge">${escHtml(String(ip))}</span>`)
            .join('');
        body = `
            <div class="item-dns">
                <div class="item-dns-header">
                    <span class="item-domain">${escHtml(item.label)}</span>
                    <span class="dns-badge">DNS</span>
                </div>
                <div class="ip-list">${badges}</div>
                ${item.value ? `<p class="item-resume">${escHtml(item.value)}</p>` : ''}
            </div>
        `;
    } else {
        /* ── Generic ───────────────────────────────────────────── */
        const label = (item.label && item.label !== 'Result') ? item.label : null;
        body = `
            <div class="item-generic">
                ${label ? `<span class="item-title">${escHtml(label)}</span>` : ''}
                ${item.value ? `<p class="item-resume">${escHtml(item.value)}</p>` : ''}
            </div>
        `;
    }

    return `
        <span class="item-index">${escHtml(num)}</span>
        <div class="item-body">${body}</div>
    `;
}

/* ── Media cards ────────────────────────────────────────── */
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

    /* image or video */
    const durBadge = (t === 'video' && item.duration)
        ? `<span class="media-duration">${escHtml(fmtDur(item.duration))}</span>` : '';
    const play     = (t === 'video') ? `<span class="media-play">▶</span>` : '';
    const thumbHtml = thumb
        ? `<img class="media-thumb" loading="lazy" referrerpolicy="no-referrer"
             src="${escAttr(thumb)}" alt="${escAttr(item.label || '')}"
             onerror="this.classList.add('media-thumb--broken')">`
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

let _lightbox = null;
// Custom green audio player (native <audio> hidden, styled controls).
function initAudioPlayer(root) {
  const el    = root.querySelector('.aplayer');
  const audio = root.querySelector('audio.aplayer-audio');
  const btn   = root.querySelector('.aplayer-play');
  const bar   = root.querySelector('.aplayer-bar');
  const fill  = root.querySelector('.aplayer-fill');
  const tEl   = root.querySelector('.aplayer-time');
  if (!el || !audio || !btn) return;
  const fmt = s => { s = Math.floor(s || 0); return Math.floor(s / 60) + ':' + String(s % 60).padStart(2, '0'); };
  btn.addEventListener('click', e => {
    e.stopPropagation();
    if (audio.paused) audio.play(); else audio.pause();
  });
  audio.addEventListener('play',  () => el.classList.add('playing'));
  audio.addEventListener('pause', () => el.classList.remove('playing'));
  audio.addEventListener('ended', () => el.classList.remove('playing'));
  audio.addEventListener('loadedmetadata', () => {
    if (tEl) tEl.textContent = '0:00 / ' + fmt(audio.duration);
  });
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

// Media-type result filter (text / image / audio / video checkboxes).
// Query progress: a bar that fills over the ~8s collect deadline + a live
// result count that grows as items stream in.
let _resultCount = 0;
const PROGRESS_MS = 8000;
function startProgress() {
  _resultCount = 0;
  updateCount();
  /* the fill is a fresh element each search; its CSS animation runs on its own */
}
function bumpCount() { _resultCount++; updateCount(); }
function updateCount() {
  const c = document.getElementById('pbar-count');
  if (c) c.textContent = _resultCount + (_resultCount === 1 ? ' result' : ' results');
}
function finishProgress() {
  const fill = document.getElementById('pbar-fill');
  if (fill) {
    fill.style.animation = 'none';
    fill.style.transition = 'width 0.35s ease';
    fill.style.width = '100%';
  }
}

let _typeFiltersInit = false;
function initTypeFilters() {
  if (_typeFiltersInit) return;
  const tf = document.getElementById('type-filters');
  if (tf) { tf.addEventListener('change', applyTypeFilter); _typeFiltersInit = true; }
}
function applyTypeFilter() {
  const tf   = document.getElementById('type-filters');
  const list = document.getElementById('results-list');
  if (!tf || !list) return;
  const checked = [...tf.querySelectorAll('input:checked')].map(c => c.value);
  const showAll = checked.length === 0;
  list.querySelectorAll('li.item-card').forEach(li => {
    const t = li.dataset.mtype || 'text';
    li.classList.toggle('type-hidden', !showAll && !checked.includes(t));
  });
}

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

/* ================================================================== */
/* Answer panel                                                       */
/* ================================================================== */

/**
 * Renders the answer panel immediately with empty content.
 * The panel is always visible — text is filled later when the answer arrives.
 */
function renderAnswerPanel(text) {
    let panel = document.getElementById('answer-panel');
    if (!panel) {
        panel = document.createElement('aside');
        panel.id        = 'answer-panel';
        panel.className = 'answer-panel';
        panel.innerHTML = `
            <div class="answer-panel__header">
                <span class="answer-panel__label">AI SYNTHESIS</span>
            </div>
            <p class="answer-panel__text" id="answer-panel-text">${escHtml(text)}</p>
        `;
        document.body.appendChild(panel);
    } else {
        const el = document.getElementById('answer-panel-text');
        if (el) { el.textContent = text; el.classList.remove('has-content'); }
    }
    document.getElementById('main')?.classList.add('main--panel-open');
}

function hideAnswerPanel() {
    const panel = document.getElementById('answer-panel');
    if (panel) panel.remove();
    document.getElementById('main')?.classList.remove('main--panel-open');
}

/* ================================================================== */
/* Error                                                              */
/* ================================================================== */
function renderError(msg) {
    return `
        <div class="error-card">
            <span class="error-icon">⚠</span>
            <span>${escHtml(msg || 'Unexpected error.')}</span>
        </div>`;
}

/* ================================================================== */
/* Utilities                                                          */
/* ================================================================== */
function escHtml(s) {
    if (s == null) return '';
    return String(s)
        .replace(/&/g, '&amp;').replace(/</g, '&lt;')
        .replace(/>/g, '&gt;').replace(/"/g, '&quot;')
        .replace(/'/g, '&#39;');
}
function escAttr(s) { return s ? String(s).replace(/"/g, '%22') : '#'; }
function safeUrl(s) {
    if (!s) return null;
    const t = String(s).trim();
    return /^https?:\/\//i.test(t) ? t : null;
}
function hostnameOf(url) {
    try { return new URL(url).hostname; } catch (_) { return url; }
}

/* ── Image media (upload / URL) → velora ─────────────────────────────── */
const IMG_EXT = /\.(jpe?g|png|webp|gif|tiff?|jp2|bmp)(\?|#|$)/i;
const URL_RE  = /https?:\/\/[^\s]+/i;

function extractImageUrl(text) {
    const m = text.match(URL_RE);
    return (m && IMG_EXT.test(m[0])) ? m[0] : null;
}

document.getElementById('add-btn')?.addEventListener('click', () =>
    document.getElementById('media-file')?.click());

document.getElementById('media-file')?.addEventListener('change', function () {
    const f = this.files && this.files[0];
    this.value = '';
    if (!f) return;
    if (!f.type.startsWith('image/') && !IMG_EXT.test(f.name)) {
        showMediaMsg('Only images are supported for now.', true);
        return;
    }
    const fd = new FormData();
    fd.append('file', f, f.name);
    runMedia(fetch('/media', { method: 'POST', body: fd }), f.name);
});

async function runMedia(fetchPromise, label) {
    const results = document.getElementById('results');
    const empty   = document.getElementById('empty-state');
    if (empty) empty.hidden = true;
    if (results) {
        results.hidden = false;
        mediaPromptHtml = userPromptHtml(label || 'image', { image: true });
        results.innerHTML = mediaPromptHtml +
            '<div class="progress-log"><div class="progress-line">' +
            '<span class="progress-arrow">›</span>velora is rendering the image…' +
            '</div></div>';
    }
    try {
        const resp = await fetchPromise;
        const data = await resp.json();
        if (!resp.ok || data.error) { showMediaMsg(data.error || ('HTTP ' + resp.status), true); return; }
        // velora's warp is async: /media answers {status:processing, poll} and we
        // poll it (same origin) until the render is done, then draw the tiles.
        const card = await pollMediaPrepare(data);
        showRaster(card);
    } catch (e) {
        showMediaMsg(String((e && e.message) || e), true);
    }
}

// Poll /media/prepare/:id until velora's background warp is done (or errors).
async function pollMediaPrepare(resp) {
    if (!resp || resp.status !== 'processing') return resp; // already a ready card
    for (let i = 0; i < 200; i++) {          // ~5 min at 1.5s
        await new Promise(f => setTimeout(f, 1500));
        let st;
        try { st = await (await fetch(resp.poll)).json(); } catch (_) { continue; }
        if (st.status === 'done')  return st;
        if (st.status === 'error') throw new Error(st.error || 'render failed');
        if (st.status === 'not_found') throw new Error('render expired');
    }
    throw new Error('render timed out');
}

/* The user's message, echoed at the top of the results like a chat prompt.
 * Images show as a compact "🖼 name" chip (full source in the title). */
let mediaPromptHtml = '';

function userPromptHtml(text, opts) {
    opts = opts || {};
    const full  = String(text);
    const label = opts.image ? labelShort(full) : full;
    const icon  = opts.image ? '🖼' : '›';
    const cls   = 'user-prompt' + (opts.image ? ' user-prompt--image' : '');
    return '<div class="' + cls + '" title="' + escAttr(full) + '">' +
             '<span class="up-icon">' + icon + '</span>' +
             '<span class="up-text">' + escHtml(label) + '</span>' +
           '</div>';
}

function labelShort(s) {
    let t = String(s).split('#')[0].split('?')[0];
    if (/^https?:\/\//i.test(t)) { const p = t.split('/').filter(Boolean); t = p[p.length - 1] || t; }
    return t.length > 64 ? t.slice(0, 61) + '…' : t;
}

function showMediaMsg(msg, err) {
    const results = document.getElementById('results');
    if (results) results.innerHTML = mediaPromptHtml +
        '<div class="media-msg' + (err ? ' err' : '') + '">' + escHtml(msg) + '</div>';
}

function showRaster(card) {
    const results = document.getElementById('results');
    if (!results || typeof L === 'undefined') { showMediaMsg('map unavailable', true); return; }
    const nz = card.maxNativeZoom || 19;
    const stats = card.stats ? ' · NDVI mean ' + (+card.stats.mean).toFixed(3) : '';
    results.innerHTML = mediaPromptHtml +
        '<ul class="items-list"><li class="item-card item-raster">' +
          '<div class="raster-head">' +
            '<span class="raster-badge">🛰 VELORA</span>' +
            '<span class="raster-id">#' + escHtml(card.id || '') + '</span>' +
            (stats ? '<span class="raster-stats">' + escHtml(stats.replace(' · ', '')) + '</span>' : '') +
          '</div>' +
          '<div id="raster-map" class="raster-map"></div>' +
        '</li></ul>';
    const map = L.map('raster-map', { attributionControl: false, minZoom: 0, maxZoom: nz + 8 });
    const b = card.bounds ? L.latLngBounds(card.bounds) : null;
    L.tileLayer(card.tiles, {
        bounds: b, noWrap: true, maxNativeZoom: nz, maxZoom: nz + 8, tileSize: 256
    }).addTo(map);
    if (b) map.fitBounds(b); else map.setView([0, 0], 2);
}

// Voice search (local STT)
(function () {
  const micBtn = document.getElementById('mic-btn');
  const input  = document.getElementById('query-input');
  const status = document.getElementById('meta-status');
  if (!micBtn || !input) return;

  let recorder = null, chunks = [], stream = null, recording = false;
  let vadRAF = null, vadCtx = null;
  const setStatus = (m, rec) => {
    if (!status) return;
    status.textContent = m || '';
    status.classList.toggle('rec', !!rec);
  };

  function stopVad() {
    if (vadRAF) { cancelAnimationFrame(vadRAF); vadRAF = null; }
    if (vadCtx) { try { vadCtx.close(); } catch (_) {} vadCtx = null; }
  }

  // Auto-stop: calibrate ambient noise for the first ~350 ms, then once speech
  // is heard, stop after ~1.2 s of continuous silence (hard 15 s cap). A manual
  // click on the mic still stops immediately.
  function startVad(mediaStream) {
    const AC = window.AudioContext || window.webkitAudioContext;
    vadCtx = new AC();
    if (vadCtx.state === 'suspended') { try { vadCtx.resume(); } catch (_) {} }
    const src = vadCtx.createMediaStreamSource(mediaStream);
    const an = vadCtx.createAnalyser();
    an.fftSize = 1024;
    src.connect(an);
    const buf = new Float32Array(an.fftSize);
    const SILENCE_MS = 1200, MAX_MS = 15000, MIN_MS = 700, CAL_MS = 350;
    let noise = 0.005, calN = 0, spoke = false, silenceStart = 0;
    const t0 = performance.now();
    const tick = () => {
      if (!recording || !recorder) return;
      an.getFloatTimeDomainData(buf);
      let sum = 0;
      for (let i = 0; i < buf.length; i++) sum += buf[i] * buf[i];
      const rms = Math.sqrt(sum / buf.length);
      const now = performance.now(), elapsed = now - t0;
      if (elapsed < CAL_MS) { noise = (noise * calN + rms) / (calN + 1); calN++; }
      const speechThr  = Math.max(0.02,  noise * 3);
      const silenceThr = Math.max(0.012, noise * 2);
      if (rms > speechThr) {
        spoke = true; silenceStart = 0;
        setStatus('recording — pause to send', true);
      } else if (spoke && rms < silenceThr) {
        if (!silenceStart) silenceStart = now;
        else if (now - silenceStart > SILENCE_MS && elapsed > MIN_MS) { recorder.stop(); return; }
      } else if (spoke) { silenceStart = 0; }
      if (elapsed > MAX_MS) { recorder.stop(); return; }
      vadRAF = requestAnimationFrame(tick);
    };
    vadRAF = requestAnimationFrame(tick);
  }

  micBtn.addEventListener('click', async () => {
    if (recording) { recorder && recorder.stop(); return; }
    try {
      stream = await navigator.mediaDevices.getUserMedia({ audio: true });
    } catch (_) { setStatus('mic access denied'); return; }
    chunks = [];
    recorder = new MediaRecorder(stream);
    recorder.ondataavailable = e => { if (e.data.size) chunks.push(e.data); };
    recorder.onstop = async () => {
      recording = false; micBtn.classList.remove('recording');
      stopVad();
      stream.getTracks().forEach(t => t.stop());
      setStatus('transcribing...', true);
      try {
        const wav = await blobToWav16k(new Blob(chunks));
        const fd = new FormData();
        fd.append('file', wav, 'audio.wav');
        const r = await fetch('/stt', { method: 'POST', body: fd });
        if (!r.ok) { setStatus('stt unavailable'); return; }
        const { text } = await r.json();
        if (text && text.trim()) {
          input.value = text.trim();
          input.dispatchEvent(new Event('input', { bubbles: true }));
          input.focus();
          setStatus('');
        } else { setStatus('nothing heard'); }
      } catch (_) { setStatus('stt failed'); }
    };
    recorder.start();
    recording = true; micBtn.classList.add('recording');
    setStatus('listening — speak, then pause to send', true);
    startVad(stream);
  });

  // Decode any recorded blob and re-encode as 16 kHz mono 16-bit WAV.
  async function blobToWav16k(blob) {
    const buf = await blob.arrayBuffer();
    const AC  = window.AudioContext || window.webkitAudioContext;
    const ctx = new AC();
    const decoded = await ctx.decodeAudioData(buf);
    const mono = downmixMono(decoded);
    const res  = resample(mono, decoded.sampleRate, 16000);
    ctx.close();
    return encodeWav(res, 16000);
  }
  function downmixMono(ab) {
    const n = ab.length, out = new Float32Array(n);
    for (let c = 0; c < ab.numberOfChannels; c++) {
      const d = ab.getChannelData(c);
      for (let i = 0; i < n; i++) out[i] += d[i] / ab.numberOfChannels;
    }
    return out;
  }
  function resample(data, from, to) {
    if (from === to) return data;
    const ratio = from / to, n = Math.round(data.length / ratio), out = new Float32Array(n);
    for (let i = 0; i < n; i++) {
      const idx = i * ratio, i0 = Math.floor(idx), i1 = Math.min(i0 + 1, data.length - 1);
      out[i] = data[i0] + (data[i1] - data[i0]) * (idx - i0);
    }
    return out;
  }
  function encodeWav(samples, rate) {
    const buf = new ArrayBuffer(44 + samples.length * 2), view = new DataView(buf);
    const wr = (o, s) => { for (let i = 0; i < s.length; i++) view.setUint8(o + i, s.charCodeAt(i)); };
    wr(0, 'RIFF'); view.setUint32(4, 36 + samples.length * 2, true); wr(8, 'WAVE');
    wr(12, 'fmt '); view.setUint32(16, 16, true); view.setUint16(20, 1, true);
    view.setUint16(22, 1, true); view.setUint32(24, rate, true);
    view.setUint32(28, rate * 2, true); view.setUint16(32, 2, true); view.setUint16(34, 16, true);
    wr(36, 'data'); view.setUint32(40, samples.length * 2, true);
    let o = 44;
    for (let i = 0; i < samples.length; i++, o += 2) {
      const s = Math.max(-1, Math.min(1, samples[i]));
      view.setInt16(o, s < 0 ? s * 0x8000 : s * 0x7fff, true);
    }
    return new Blob([view], { type: 'audio/wav' });
  }
})();
