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
const TOPICS = [
    'Erlang',
    'Claude AI',
    'distributed systems',
    'functional programming',
    'software architecture',
];

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
    TOPICS.forEach((label, i) => {
        const chip = document.createElement('button');
        chip.className = 'topic-chip' + (i === 0 ? ' active' : '');
        chip.textContent = label;
        chip.addEventListener('click', () => selectTopic(i));
        nav.appendChild(chip);
    });
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
    if (loading) return;
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
function appendCard(item, topicIndex) {
    const feed = document.getElementById('drift-feed');
    if (!feed) return;

    const card = document.createElement('article');
    card.className = `drift-card active-topic-${topicIndex % 5}`;
    card.style.animationDelay = `${Math.min((totalItems % 10) * 40, 300)}ms`;
    card.dataset.url = item.url;

    const safeUrl = escAttr(item.url);
    const label   = item.label && item.label !== 'Result' ? item.label : hostnameOf(item.url);

    card.innerHTML = `
        <div class="card-topic-tag">${escHtml(TOPICS[topicIndex])}</div>
        <div class="card-title">${escHtml(label)}</div>
        <div class="card-url">${escHtml(item.url)}</div>
        <div class="card-preview loading" data-preview-url="${safeUrl}"></div>
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
buildTopics();
initPreviewObserver();
initSentinelObserver();
initKeyboard();
initDrag();
loadBatch();
