/**
 * emergence.js — Emquest Browser Client
 *
 * Responsibilities:
 *   1. Auto-resize textarea as the user types.
 *   2. Submit queries via POST /query and render the structured response.
 *   3. Render a generic { answer, items } contract — never tied to a
 *      specific agent type.  New agents require zero changes here.
 *   4. Ambient canvas background (animated dot grid).
 *   5. Clock, scroll-shadow on header, agent count in footer.
 */

/* ================================================================== */
/* 1. Ambient canvas background                                       */
/* ================================================================== */

(function initCanvas() {
    const canvas = document.getElementById('bg-canvas');
    if (!canvas) return;

    const ctx    = canvas.getContext('2d');
    const COLS   = 40;     // approximate columns of dots
    const COLOR  = '0, 220, 100';
    let   dots   = [];
    let   raf;

    function resize() {
        canvas.width  = window.innerWidth;
        canvas.height = window.innerHeight;
        buildDots();
    }

    function buildDots() {
        dots = [];
        const spacing = canvas.width / COLS;
        const rows    = Math.ceil(canvas.height / spacing) + 1;
        for (let r = 0; r <= rows; r++) {
            for (let c = 0; c <= COLS; c++) {
                dots.push({
                    x:     c * spacing,
                    y:     r * spacing,
                    phase: Math.random() * Math.PI * 2,
                    speed: 0.4 + Math.random() * 0.6,
                });
            }
        }
    }

    function draw(ts) {
        ctx.clearRect(0, 0, canvas.width, canvas.height);
        const t = ts * 0.001;
        dots.forEach(d => {
            const alpha = 0.08 + 0.07 * Math.sin(t * d.speed + d.phase);
            ctx.beginPath();
            ctx.arc(d.x, d.y, 1.5, 0, Math.PI * 2);
            ctx.fillStyle = `rgba(${COLOR}, ${alpha})`;
            ctx.fill();
        });
        raf = requestAnimationFrame(draw);
    }

    window.addEventListener('resize', resize);
    resize();
    raf = requestAnimationFrame(draw);
})();

/* ================================================================== */
/* 2. Clock                                                           */
/* ================================================================== */

function updateClock() {
    const el = document.getElementById('clock');
    if (!el) return;
    const n = new Date();
    const pad = v => String(v).padStart(2, '0');
    el.textContent =
        `${n.getFullYear()}-${pad(n.getMonth()+1)}-${pad(n.getDate())} `
        + `${pad(n.getHours())}:${pad(n.getMinutes())}:${pad(n.getSeconds())}`;
}

setInterval(updateClock, 1000);
updateClock();

/* ================================================================== */
/* 3. Header scroll-shadow                                            */
/* ================================================================== */

window.addEventListener('scroll', () => {
    document.getElementById('app-header')
        .classList.toggle('scrolled', window.scrollY > 8);
}, { passive: true });

/* ================================================================== */
/* 4. Agent count in footer (polling /registry)                       */
/* ================================================================== */

async function refreshAgentCount() {
    try {
        const r = await fetch('http://localhost:8080/registry');
        if (!r.ok) return;
        const data  = await r.json();
        const count = (data.agents || []).length;
        const el    = document.getElementById('footer-agent-count');
        if (el) el.textContent = `${count} agent${count !== 1 ? 's' : ''} connected`;
    } catch (_) {
        /* disco unreachable — footer stays as-is */
    }
}

refreshAgentCount();
setInterval(refreshAgentCount, 15000);

/* ================================================================== */
/* 5. Textarea auto-resize                                            */
/* ================================================================== */

const queryInput = document.getElementById('query-input');

queryInput.addEventListener('input', function () {
    this.style.height = 'auto';
    this.style.height = Math.min(this.scrollHeight, 120) + 'px';
});

/* ================================================================== */
/* 6. Submit logic                                                    */
/* ================================================================== */

queryInput.addEventListener('keydown', function (e) {
    if (e.key === 'Enter' && !e.shiftKey) {
        e.preventDefault();
        submitQuery();
    }
});

document.getElementById('send-btn').addEventListener('click', submitQuery);

/**
 * Reads the textarea value, POSTs to /query, and renders the result.
 */
async function submitQuery() {
    const query = queryInput.value.trim();
    if (!query) return;

    const btn        = document.getElementById('send-btn');
    const metaStatus = document.getElementById('meta-status');
    const results    = document.getElementById('results');
    const emptyState = document.getElementById('empty-state');

    // UI: loading state
    btn.classList.add('loading');
    btn.disabled = true;
    metaStatus.className = 'meta-status';
    metaStatus.textContent = 'querying agents…';

    // Hide empty state, show skeleton
    emptyState.hidden = true;
    results.hidden    = false;
    results.innerHTML = renderSkeleton();

    try {
        const resp = await fetch('/query', {
            method:  'POST',
            headers: { 'Content-Type': 'application/json' },
            body:    JSON.stringify({ query }),
        });

        if (!resp.ok) throw new Error(`HTTP ${resp.status}`);

        const data = await resp.json();
        results.innerHTML = renderResponse(data);
        metaStatus.textContent = '';

        // Scroll results into view on mobile
        results.scrollIntoView({ behavior: 'smooth', block: 'start' });

    } catch (err) {
        console.error('[emquest] Query failed:', err);
        results.innerHTML = renderError(err.message);
        metaStatus.className  = 'meta-status error';
        metaStatus.textContent = 'request failed';
    } finally {
        btn.classList.remove('loading');
        btn.disabled = false;
    }
}

/* ================================================================== */
/* 7. Renderers                                                       */
/* ================================================================== */

/**
 * Renders the full structured response: answer card + optional items.
 *
 * Contract:
 *   { answer: string, items?: Array<{ label, value, url? }> }
 *
 * This renderer is intentionally generic — it does not know about
 * agent types.  The LLM (queen) decides what goes in answer / items.
 *
 * @param {Object} data - The parsed JSON response from /query.
 * @returns {string} HTML string.
 */
function renderResponse(data) {
    const parts = [];

    // ── Answer card ─────────────────────────────────────────────
    if (data.answer) {
        parts.push(`
            <div class="answer-card">
                <div class="answer-label">SYNTHESIS</div>
                <p class="answer-text">${escapeHtml(data.answer)}</p>
            </div>
        `);
    }

    // ── Items section ────────────────────────────────────────────
    const items = data.items;
    if (Array.isArray(items) && items.length > 0) {
        const itemsHtml = items.map((item, i) => renderItem(item, i)).join('');
        parts.push(`
            <div class="items-section">
                <div class="items-label">RESULTS</div>
                <ul class="items-list">${itemsHtml}</ul>
            </div>
        `);
    }

    // ── Fallback if both are absent ──────────────────────────────
    if (parts.length === 0) {
        parts.push(renderError('No results returned.'));
    }

    return parts.join('');
}

/**
 * Renders a single result item.
 *
 * Each item has: label (required), value (optional), url (optional).
 * When url is present, the label becomes a clickable link.
 *
 * @param {{ label: string, value?: string, url?: string }} item
 * @param {number} index - Zero-based index for display number.
 * @returns {string} HTML string for a <li>.
 */
function renderItem(item, index) {
    const num   = String(index + 1).padStart(2, '0');
    const label = item.label || '';
    const value = item.value || '';
    const url   = item.url && item.url !== 'null' ? item.url : null;

    // Label is a link when url is present
    const labelHtml = url
        ? `<a href="${escapeAttr(url)}" target="_blank" rel="noopener"
               class="item-label">${escapeHtml(label)}</a>`
        : `<span class="item-label">${escapeHtml(label)}</span>`;

    const arrowHtml = url
        ? `<span class="item-arrow" aria-hidden="true">↗</span>`
        : '';

    return `
        <li class="item-card">
            <span class="item-index">${escapeHtml(num)}</span>
            <div class="item-body">
                ${labelHtml}
                ${value ? `<p class="item-value">${escapeHtml(value)}</p>` : ''}
            </div>
            ${arrowHtml}
        </li>
    `;
}

/**
 * Renders a loading skeleton (shown while the query is in flight).
 * @returns {string} HTML string.
 */
function renderSkeleton() {
    return `
        <div class="skeleton">
            <div class="skeleton-answer">
                <div class="skeleton-line long"></div>
                <div class="skeleton-line full"></div>
                <div class="skeleton-line short"></div>
            </div>
            <div class="skeleton-answer">
                <div class="skeleton-line full"></div>
                <div class="skeleton-line long"></div>
            </div>
        </div>
    `;
}

/**
 * Renders an error card.
 * @param {string} message
 * @returns {string} HTML string.
 */
function renderError(message) {
    return `
        <div class="error-card">
            <span class="error-icon">⚠</span>
            <span>${escapeHtml(message || 'An unexpected error occurred.')}</span>
        </div>
    `;
}

/* ================================================================== */
/* 8. Utilities                                                       */
/* ================================================================== */

/**
 * Escapes a string for safe insertion into HTML text content.
 * @param {string} str
 * @returns {string}
 */
function escapeHtml(str) {
    if (str === null || str === undefined) return '';
    return String(str)
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;')
        .replace(/'/g, '&#39;');
}

/**
 * Escapes a string for safe use in an HTML attribute value.
 * Only allows http/https URLs; strips everything else.
 * @param {string} str
 * @returns {string}
 */
function escapeAttr(str) {
    if (!str) return '#';
    const s = String(str).trim();
    // Reject non-http(s) schemes to prevent javascript: injection
    if (!/^https?:\/\//i.test(s)) return '#';
    return s.replace(/"/g, '%22');
}
