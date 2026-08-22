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
        <div class="progress-log" id="progress-log"></div>
        <ul class="items-list" id="results-list"></ul>
    `;

    hideAnswerPanel();

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
        case 'status': {
            const log = document.getElementById('progress-log');
            if (!log) return;
            const line = document.createElement('div');
            line.className = 'progress-line';
            line.innerHTML = `<span class="progress-arrow">›</span>${escHtml(event.message)}`;
            log.appendChild(line);
            line.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
            break;
        }

        /* ── Stream one result card immediately ────────────────── */
        case 'item': {
            const list = document.getElementById('results-list');
            if (!list) return;
            const card = buildCard(event.item, event.sid, streamCards.size);
            list.appendChild(card);
            streamCards.set(event.sid, card);
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

            /* Hide progress log now that ranking is done → cards float up */
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
    li.style.animationDelay = `${Math.min(pos * 50, 400)}ms`;

    li.innerHTML = buildCardBody(item, pos);

    /* Clickable whole card for web results */
    if (item.url) {
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

    if (item.url) {
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
