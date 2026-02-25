/**
 * emergence.js — Emquest Browser Client (SSE streaming)
 *
 * Reads a Server-Sent Events stream from POST /query.
 * Events:
 *   {type: "status",  message: "..."}  → appended to progress log
 *   {type: "results", items: [...]}    → replaces progress log with results
 *   {type: "error",   message: "..."}  → shows error card
 *
 * Item rendering is type-aware but fully generic:
 *   item.url present  → web result  (link + resume)
 *   item.ips present  → DNS result  (IP badge list)
 *   neither           → generic     (label + value)
 *
 * score (0-3) from the LLM drives a visual relevance indicator.
 */

/* ================================================================== */
/* Ambient canvas background                                          */
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
                dots.push({ x: c * spacing, y: r * spacing,
                             phase: Math.random() * Math.PI * 2,
                             speed: 0.4 + Math.random() * 0.6 });
    }

    function draw(ts) {
        ctx.clearRect(0, 0, canvas.width, canvas.height);
        const t = ts * 0.001;
        dots.forEach(d => {
            const a = 0.06 + 0.06 * Math.sin(t * d.speed + d.phase);
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
/* Agent count (footer)                                               */
/* ================================================================== */
async function refreshAgentCount() {
    try {
        const r = await fetch('http://localhost:8080/registry');
        if (!r.ok) return;
        const d = await r.json();
        const n = (d.agents || []).length;
        const el = document.getElementById('footer-agent-count');
        if (el) el.textContent = `${n} agent${n !== 1 ? 's' : ''} connected`;
    } catch (_) {}
}
refreshAgentCount();
setInterval(refreshAgentCount, 15000);

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

async function submitQuery() {
    const query = queryInput?.value.trim();
    if (!query) return;

    const btn     = document.getElementById('send-btn');
    const results = document.getElementById('results');
    const empty   = document.getElementById('empty-state');

    btn.classList.add('loading');
    btn.disabled = true;
    empty.hidden   = true;
    results.hidden = false;

    /* Show live progress log */
    results.innerHTML = `<div class="progress-log" id="progress-log"></div>`;

    try {
        const resp = await fetch('/query', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ query }),
        });

        if (!resp.ok) throw new Error(`HTTP ${resp.status}`);

        /* Read the SSE stream line by line */
        const reader  = resp.body.getReader();
        const decoder = new TextDecoder();
        let   buffer  = '';

        while (true) {
            const { done, value } = await reader.read();
            if (done) break;
            buffer += decoder.decode(value, { stream: true });
            /* SSE events are separated by \n\n */
            const parts = buffer.split('\n\n');
            buffer = parts.pop();       // keep incomplete tail
            for (const part of parts) {
                const line = part.trim();
                if (line.startsWith('data: ')) {
                    handleEvent(JSON.parse(line.slice(6)), results);
                }
            }
        }
    } catch (err) {
        console.error('[emquest]', err);
        results.innerHTML = renderError(err.message);
    } finally {
        btn.classList.remove('loading');
        btn.disabled = false;
    }
}

/* ================================================================== */
/* SSE event handler                                                  */
/* ================================================================== */

/**
 * Dispatches an incoming SSE event to the appropriate renderer.
 * @param {{ type: string, message?: string, items?: Array }} event
 * @param {HTMLElement} container
 */
function handleEvent(event, container) {
    switch (event.type) {

        case 'status': {
            /* Append a line to the live progress log */
            const log = document.getElementById('progress-log');
            if (!log) return;
            const line = document.createElement('div');
            line.className = 'progress-line';
            line.innerHTML = `<span class="progress-arrow">›</span> ${escHtml(event.message)}`;
            log.appendChild(line);
            line.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
            break;
        }

        case 'answer': {
            /* Show the LLM answer card above results (created lazily) */
            let card = document.getElementById('answer-card');
            if (!card) {
                card = document.createElement('div');
                card.id        = 'answer-card';
                card.className = 'answer-card';
                card.innerHTML = `<div class="answer-label">ANSWER</div>
                                  <p class="answer-text" id="answer-text"></p>`;
                container.innerHTML = '';
                container.appendChild(card);
                /* Placeholder for results that will follow */
                const list = document.createElement('div');
                list.id = 'results-placeholder';
                container.appendChild(list);
            }
            document.getElementById('answer-text').textContent = event.message;
            break;
        }

        case 'results': {
            /* Inject results — either into placeholder or replace everything */
            const placeholder = document.getElementById('results-placeholder');
            const html = renderResults(event.items || []);
            if (placeholder) {
                placeholder.outerHTML = html;
            } else {
                container.innerHTML = html;
            }
            break;
        }

        case 'error': {
            container.innerHTML = renderError(event.message);
            break;
        }
    }
}

/* ================================================================== */
/* Renderers                                                          */
/* ================================================================== */

/**
 * Renders the full results list.
 * Items are already sorted by queen (most relevant first, score 3→0).
 * Nothing is hidden.
 */
function renderResults(items) {
    if (!items.length) return renderError('No results found.');

    const itemsHtml = items.map((item, i) => renderItem(item, i)).join('');
    return `<ul class="items-list">${itemsHtml}</ul>`;
}

/**
 * Renders one result item.
 *
 * Type detection:
 *   item.url   → web result  → title as link + resume text
 *   item.ips   → DNS result  → IP badges
 *   neither    → generic     → label + value
 *
 * score (0-3) drives the left-border accent colour.
 */
function renderItem(item, index) {
    const num   = String(index + 1).padStart(2, '0');
    const score = item.score ?? 0;
    const scoreClass = ['score-0', 'score-1', 'score-2', 'score-3'][score] ?? 'score-0';

    let bodyHtml = '';

    if (item.url) {
        /* ── Web result ─────────────────────────────────────────── */
        bodyHtml = `
            <a href="${escAttr(item.url)}" target="_blank" rel="noopener"
               class="item-label item-link">${escHtml(item.label)}</a>
            <p class="item-url-display">${escHtml(item.url)}</p>
            ${item.value ? `<p class="item-value">${escHtml(item.value)}</p>` : ''}
        `;
    } else if (Array.isArray(item.ips) && item.ips.length) {
        /* ── DNS result ─────────────────────────────────────────── */
        const ipBadges = item.ips
            .map(ip => `<span class="ip-badge">${escHtml(String(ip))}</span>`)
            .join('');
        bodyHtml = `
            <span class="item-label">${escHtml(item.label)}</span>
            <div class="ip-list">${ipBadges}</div>
            ${item.value ? `<p class="item-value">${escHtml(item.value)}</p>` : ''}
        `;
    } else {
        /* ── Generic result ─────────────────────────────────────── */
        bodyHtml = `
            <span class="item-label">${escHtml(item.label)}</span>
            ${item.value ? `<p class="item-value">${escHtml(item.value)}</p>` : ''}
        `;
    }

    /* Whole card is clickable when a URL is present */
    const clickable = item.url ? `onclick="window.open('${escAttr(item.url)}','_blank','noopener')"
                                  style="cursor:pointer"` : '';

    return `
        <li class="item-card ${scoreClass}"
            style="animation-delay:${index * 60}ms"
            ${clickable}>
            <span class="item-index">${escHtml(num)}</span>
            <div class="item-body">${bodyHtml}</div>
            ${item.url ? `<span class="item-arrow">↗</span>` : ''}
        </li>
    `;
}

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
        .replace(/&/g,'&amp;').replace(/</g,'&lt;')
        .replace(/>/g,'&gt;').replace(/"/g,'&quot;')
        .replace(/'/g,'&#39;');
}
function escAttr(s) {
    if (!s) return '#';
    const t = String(s).trim();
    return /^https?:\/\//i.test(t) ? t.replace(/"/g,'%22') : '#';
}
