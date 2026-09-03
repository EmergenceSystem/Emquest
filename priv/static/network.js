/* ── Canvas ───────────────────────────────────────────────────────── */
(function () {
    const canvas = document.getElementById('bg-canvas');
    const ctx    = canvas.getContext('2d');
    let dots = [];

    function resize() {
        canvas.width  = window.innerWidth;
        canvas.height = window.innerHeight;
        const spacing = canvas.width / 36;
        const rows    = Math.ceil(canvas.height / spacing) + 1;
        dots = [];
        for (let r = 0; r <= rows; r++)
            for (let c = 0; c <= 36; c++)
                dots.push({
                    x: c * spacing, y: r * spacing,
                    phase: Math.random() * Math.PI * 2,
                    speed: 0.3 + Math.random() * 0.5
                });
    }

    function draw(ts) {
        ctx.clearRect(0, 0, canvas.width, canvas.height);
        const t = ts * 0.001;
        dots.forEach(d => {
            const a = 0.04 + 0.04 * Math.sin(t * d.speed + d.phase);
            ctx.beginPath();
            ctx.arc(d.x, d.y, 1.4, 0, Math.PI * 2);
            ctx.fillStyle = `rgba(0,220,100,${a})`;
            ctx.fill();
        });
        requestAnimationFrame(draw);
    }

    window.addEventListener('resize', resize);
    resize();
    requestAnimationFrame(draw);
})();

/* ── Clock ────────────────────────────────────────────────────────── */
function tick() {
    const el = document.getElementById('clock');
    if (!el) return;
    const n = new Date(), p = v => String(v).padStart(2, '0');
    el.textContent =
        `${n.getFullYear()}-${p(n.getMonth()+1)}-${p(n.getDate())} `
        + `${p(n.getHours())}:${p(n.getMinutes())}:${p(n.getSeconds())}`;
}
setInterval(tick, 1000);
tick();

/* ── Peers ────────────────────────────────────────────────────────── */
function escHtml(s) {
    return String(s || '')
        .replace(/&/g,'&amp;').replace(/</g,'&lt;')
        .replace(/>/g,'&gt;').replace(/"/g,'&quot;');
}

/* ── Peers (keyed reconciliation — no full rebuild) ────────────────── */

function peerKey(p) {
    return (p.name || '?') + '|' + (p.host || '?') + '|'
         + (p.query_port != null ? p.query_port : '');
}

function sortPeers(peers) {
    return peers.slice().sort((a, b) => {
        const ka = (a.name || a.host || '').toLowerCase();
        const kb = (b.name || b.host || '').toLowerCase();
        if (ka !== kb) return ka < kb ? -1 : 1;
        return (a.host || '').localeCompare(b.host || '');
    });
}

function peerSignature(p) {
    return (p.routable ? 'r' : 'g') + '|' + p.host + '|'
         + p.query_port + '|' + (p.name || '');
}

function cardMarkup(peer) {
    const routable    = peer.routable;
    const addr        = routable ? (peer.host + ':' + peer.query_port)
                                 : String(peer.host);
    const displayName = peer.name ? peer.name : addr;
    return `
        <div class="agent-name">
            <span class="agent-dot${routable ? '' : ' agent-dot--gossip'}"></span>
            ${escHtml(displayName)}
        </div>
        <div class="caps">
            <span class="cap${routable ? '' : ' cap--gossip'}">${routable ? 'routable' : 'gossip only'}</span>
        </div>
        ${routable ? `<div class="agent-addr">${escHtml(addr)}</div>` : ''}
    `;
}

let cardIndex = new Map();

function renderPeers(peers) {
    const grid   = document.getElementById('agents-grid');
    const statP  = document.getElementById('stat-peers');
    const statR  = document.getElementById('stat-routable');
    const footer = document.getElementById('footer-count');

    const routableCount = peers.filter(p => p.routable).length;
    statP.textContent  = peers.length;
    statR.textContent  = routableCount;
    footer.textContent = peers.length + ' peer' + (peers.length !== 1 ? 's' : '')
                       + ' discovered';

    grid.querySelectorAll('.grid-placeholder').forEach(el => el.remove());

    if (peers.length === 0) {
        for (const [, el] of cardIndex) el.remove();
        cardIndex.clear();
        const ph = document.createElement('div');
        ph.className = 'grid-placeholder';
        ph.style.cssText = 'color:var(--muted);font-size:0.8rem;grid-column:1/-1';
        ph.textContent = 'No peers discovered yet — gossip is running.';
        grid.appendChild(ph);
        return;
    }

    const sorted = sortPeers(peers);
    const wanted = new Set(sorted.map(peerKey));

    for (const [key, el] of cardIndex) {
        if (!wanted.has(key)) { el.remove(); cardIndex.delete(key); }
    }

    let prev = null;
    for (const peer of sorted) {
        const key = peerKey(peer);
        const sig = peerSignature(peer);
        let card  = cardIndex.get(key);
        if (card) {
            if (card.dataset.sig !== sig) {
                card.className = 'agent-card' + (peer.routable ? '' : ' agent-card--gossip');
                card.innerHTML = cardMarkup(peer);
                card.dataset.sig = sig;
            }
        } else {
            card = document.createElement('div');
            card.className   = 'agent-card' + (peer.routable ? '' : ' agent-card--gossip');
            card.dataset.sig = sig;
            card.innerHTML   = cardMarkup(peer);
            cardIndex.set(key, card);
        }
        const target = prev ? prev.nextSibling : grid.firstChild;
        if (card !== target) grid.insertBefore(card, target);
        prev = card;
    }
}

function showError(msg) {
    const grid   = document.getElementById('agents-grid');
    const statP  = document.getElementById('stat-peers');
    const statR  = document.getElementById('stat-routable');
    const footer = document.getElementById('footer-count');
    if (grid) {
        for (const [, el] of cardIndex) el.remove();
        cardIndex.clear();
        grid.querySelectorAll('.grid-placeholder').forEach(el => el.remove());
        const err = document.createElement('div');
        err.className = 'grid-placeholder error-msg';
        err.style.gridColumn = '1/-1';
        err.innerHTML = '<span>⚠</span><span>Could not load peers: '
                      + escHtml(msg) + '</span>';
        grid.appendChild(err);
    }
    if (statP)  statP.textContent  = '—';
    if (statR)  statR.textContent  = '—';
    if (footer) footer.textContent = 'peer table unavailable';
}

/* Read the admin bearer token from the same IndexedDB store the admin console
   uses, so a signed-in admin sees the mesh here without re-entering it. */
function idbToken() {
    return new Promise((resolve) => {
        try {
            const req = indexedDB.open('emquest_admin', 1);
            req.onupgradeneeded = () => { try { req.result.createObjectStore('kv'); } catch (e) {} };
            req.onsuccess = () => {
                try {
                    const tx = req.result.transaction('kv', 'readonly');
                    const g = tx.objectStore('kv').get('token');
                    g.onsuccess = () => resolve(g.result || null);
                    g.onerror = () => resolve(null);
                } catch (e) { resolve(null); }
            };
            req.onerror = () => resolve(null);
        } catch (e) { resolve(null); }
    });
}

async function loadPeers() {
    try {
        const token = await idbToken();
        const headers = token ? { authorization: 'Bearer ' + token } : {};
        const r = await fetch('/network/peers', { headers });
        if (r.status === 401) { showError('Admin token required — sign in at /admin first.'); return; }
        if (!r.ok) throw new Error(`HTTP ${r.status}`);
        const peers = await r.json();
        renderPeers(Array.isArray(peers) ? peers : []);
    } catch (err) {
        showError(err.message);
    }
}

loadPeers();
setInterval(loadPeers, 15000);
