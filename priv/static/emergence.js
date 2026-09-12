/**
 * emergence.js — Emquest chat-style client (SSE streaming)
 *
 * Layout: fixed sidebar (search history) | scrollable flux of "turns" |
 * bottom composer. Each search is a turn: a user bubble + an assistant
 * bubble (synthesis slot + streamed result cards).
 *
 * The synthesis slot is where an LLM answer streams in once the backend
 * emits `answer` events; until then it shows a deterministic summary and
 * an "llm offline" badge.
 *
 * Conversations persist in IndexedDB (db `emquest_chat`, separate from the
 * base `emergence`/prefs store). Only text + metadata count against the
 * memory budget — image bytes are never stored; thumbnails lazy-fetch from
 * their URL when a conversation is reopened.
 *
 * SSE events: status | item | reorder | answer | error
 */

const MEM_BUDGET = 40 * 1024 * 1024;   /* 40 MB before purge */
const COMPRESS_AT = 0.80;              /* compress oldest turns at 80% */

/* ================================================================== */
/* Moderation report button                                           */
/* ================================================================== */
function reportResult(item, btn) {
    if (!item || !item.source_id) return;
    try {
        fetch("/report", { method: "POST", headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ signer_id: item.source_id, url: item.url || "", reason: "user_flag" }) });
    } catch (e) {}
    if (btn) { btn.textContent = "⚑ reported"; btn.disabled = true; btn.classList.add("reported"); }
}
function addReportBtn(card, item) {
    if (!item || !item.source_id) return;
    const b = document.createElement("button");
    b.type = "button"; b.className = "report-btn"; b.textContent = "⚑";
    b.title = "Report this result"; b.setAttribute("aria-label", "Report this result");
    b.addEventListener("click", e => { e.stopPropagation(); reportResult(item, b); });
    card.appendChild(b);
}

/* ================================================================== */
/* Ambient canvas — vector mesh globe (drag-to-throw)                 */
/* ================================================================== */
(function(){
  const canvas=document.getElementById('bg-canvas'); if(!canvas) return;
  const x=canvas.getContext('2d'); let w,h,t=0;
  function rs(){w=canvas.width=canvas.offsetWidth;h=canvas.height=canvas.offsetHeight}
  rs(); addEventListener('resize',rs);
  const reduce=matchMedia('(prefers-reduced-motion:reduce)').matches;
  const N=[]; for(let i=0;i<90;i++){const ph=Math.acos(2*Math.random()-1),th=Math.random()*7;N.push([Math.sin(ph)*Math.cos(th),Math.sin(ph)*Math.sin(th),Math.cos(ph)])}
  const AUTO=.003; let vel=AUTO, drag=false, lastX=0;
  if(!reduce){
    document.addEventListener('pointerdown',e=>{
      if(e.target.closest('.item-card, input, textarea, button, a, .type-drawer, .search-box, .topbar, .sidebar')) return;
      drag=true; lastX=e.clientX; vel=0;
    });
    document.addEventListener('pointermove',e=>{ if(!drag) return; const dx=e.clientX-lastX; lastX=e.clientX; vel=dx*.0006; t+=vel; });
    document.addEventListener('pointerup',()=>{ drag=false; });
    document.addEventListener('pointercancel',()=>{ drag=false; });
  }
  function frame(){
    if(!reduce && !drag){ vel=vel*.94 + AUTO*.06; t+=vel; }
    x.clearRect(0,0,w,h);
    const cx=w*.8,cy=h*.34,R=Math.min(w,h)*.34;
    const pr=N.map(([a,b,cc])=>{const X=a*Math.cos(t)-cc*Math.sin(t),Z=a*Math.sin(t)+cc*Math.cos(t);return[cx+X*R,cy+b*R,(Z+1)/2]});
    x.lineWidth=1.1;
    for(let i=0;i<pr.length;i++)for(let j=i+1;j<pr.length;j++){const d=Math.hypot(pr[i][0]-pr[j][0],pr[i][1]-pr[j][1]);if(d<82){x.strokeStyle='rgba(0,255,160,'+(1-d/82)*.42*((pr[i][2]+pr[j][2])/2)+')';x.beginPath();x.moveTo(pr[i][0],pr[i][1]);x.lineTo(pr[j][0],pr[j][1]);x.stroke()}}
    for(const p of pr){x.fillStyle='rgba(0,255,170,'+(.25+p[2]*.75)+')';x.beginPath();x.arc(p[0],p[1],1+p[2]*1.8,0,7);x.fill()}
    if(!reduce) requestAnimationFrame(frame);
  }
  frame();
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
/* Peer count                                                         */
/* ================================================================== */
async function refreshPeerCount() {
    try {
        const r = await fetch('/network/peers');
        if (!r.ok) return;
        const peers = await r.json();
        const n  = Array.isArray(peers) ? peers.length : 0;
        const el = document.getElementById('footer-agent-count');
        if (el) el.textContent = `${n} peer${n !== 1 ? 's' : ''} · network ↗`;
    } catch (_) {}
}
refreshPeerCount();
setInterval(refreshPeerCount, 15000);

/* ================================================================== */
/* Conversation store (IndexedDB: db `emquest_chat`)                  */
/* ================================================================== */
const CDB_NAME = 'emquest_chat', CDB_VER = 1;
let _cdb = null;
function openCDB() {
    if (_cdb) return _cdb;
    _cdb = new Promise((res, rej) => {
        const r = indexedDB.open(CDB_NAME, CDB_VER);
        r.onupgradeneeded = () => {
            const db = r.result;
            if (!db.objectStoreNames.contains('conversations')) db.createObjectStore('conversations', { keyPath: 'id' });
            if (!db.objectStoreNames.contains('turns')) {
                const s = db.createObjectStore('turns', { keyPath: ['convId', 'seq'] });
                s.createIndex('conv', 'convId', { unique: false });
            }
            if (!db.objectStoreNames.contains('meta')) db.createObjectStore('meta');
        };
        r.onsuccess = () => res(r.result);
        r.onerror = () => rej(r.error);
    });
    return _cdb;
}
function cRun(store, mode, fn) {
    return openCDB().then(db => new Promise((res, rej) => {
        const tx = db.transaction(store, mode);
        const req = fn(tx.objectStore(store));
        tx.oncomplete = () => res(req ? req.result : undefined);
        tx.onerror = () => rej(tx.error);
        tx.onabort = () => rej(tx.error);
    }));
}
const cGet    = (s, k)    => cRun(s, 'readonly',  os => os.get(k));
const cGetAll = (s)       => cRun(s, 'readonly',  os => os.getAll());
const cPut    = (s, v, k) => cRun(s, 'readwrite', os => (k === undefined ? os.put(v) : os.put(v, k)));
const cDel    = (s, k)    => cRun(s, 'readwrite', os => os.delete(k));
const turnsFor = (id) => cRun('turns', 'readonly', os => os.index('conv').getAll(id)).then(a => (a || []).sort((x, y) => x.seq - y.seq));
const getUsage = () => cGet('meta', 'usage').then(v => (typeof v === 'number' ? v : 0));
const setUsage = (n) => cPut('meta', Math.max(0, n | 0), 'usage');
function byteLen(o) { try { return JSON.stringify(o).length; } catch (_) { return 0; } }

/* ================================================================== */
/* Conversation state + sidebar                                       */
/* ================================================================== */
let currentConvId = null;
let currentTurn = null;
let streamCards = new Map();

const AI_AVATAR =
    '<div class="ai-avatar"><div class="logo-mark">'
    + '<span class="logo-dot"></span><span class="logo-dot"></span><span class="logo-dot"></span>'
    + '</div></div>';

const fluxInner = () => document.getElementById('flux-inner');
const fluxEl    = () => document.getElementById('flux');
const truncate  = (s, n) => { s = String(s || ''); return s.length > n ? s.slice(0, n - 1) + '…' : s; };
const nearBottom = (el) => el.scrollHeight - el.scrollTop - el.clientHeight < 160;
function scrollFluxToBottom() { const f = fluxEl(); if (f) f.scrollTop = f.scrollHeight; }

function relTime(ts) {
    const s = Math.max(0, (Date.now() - ts) / 1000);
    if (s < 60) return 'just now';
    if (s < 3600) return Math.floor(s / 60) + ' min ago';
    if (s < 86400) return Math.floor(s / 3600) + ' h ago';
    if (s < 172800) return 'yesterday';
    return Math.floor(s / 86400) + ' d ago';
}
function fmtSize(b) {
    if (b < 1024 * 1024) return Math.round(b / 1024) + ' KB';
    const mb = b / (1024 * 1024);
    return (mb < 10 ? mb.toFixed(1) : Math.round(mb)) + ' MB';
}

async function createConversation(query) {
    const id = 'c' + Date.now().toString(36) + Math.random().toString(36).slice(2, 6);
    const now = Date.now();
    await cPut('conversations', { id, title: truncate(query, 60), createdAt: now, updatedAt: now, bytes: 0, seq: 0 });
    currentConvId = id;
    await renderSidebar();
    return id;
}

async function renderSidebar() {
    const list = document.getElementById('conv-list');
    if (!list) return;
    let convs = [];
    try { convs = await cGetAll('conversations'); } catch (_) {}
    convs.sort((a, b) => b.updatedAt - a.updatedAt);
    list.innerHTML = convs.length
        ? convs.map(c => `<div class="conv${c.id === currentConvId ? ' active' : ''}" data-id="${escAttr(c.id)}" title="${escAttr(c.title)}">${escHtml(c.title)}<span class="conv-date">${escHtml(relTime(c.updatedAt))}</span><button class="conv-del" data-id="${escAttr(c.id)}" title="Delete this search" aria-label="Delete this search">✕</button></div>`).join('')
        : '<div class="conv-empty">No searches yet.</div>';
    updateMemBar();
}
async function updateMemBar() {
    const fill = document.getElementById('mem-fill'), text = document.getElementById('mem-text');
    let usage = 0;
    try { usage = await getUsage(); } catch (_) {}
    const pct = Math.min(100, Math.round(usage / MEM_BUDGET * 100));
    if (fill) { fill.style.width = pct + '%'; fill.classList.toggle('warn', pct >= COMPRESS_AT * 100); }
    if (text) text.textContent = fmtSize(usage) + ' / 40 MB';
}
function setActiveConv(id) {
    document.querySelectorAll('#conv-list .conv').forEach(el => el.classList.toggle('active', el.dataset.id === id));
}
function clearFlux() {
    const inner = fluxInner();
    if (inner) inner.querySelectorAll('.turn').forEach(t => t.remove());
    currentTurn = null; streamCards = new Map();
}
function showEmpty(show) { const e = document.getElementById('empty-state'); if (e) e.hidden = !show; }

async function loadConversation(id) {
    const conv = await cGet('conversations', id);
    if (!conv) return;
    currentConvId = id;
    clearFlux(); showEmpty(false);
    const turns = await turnsFor(id);
    for (const rec of turns) renderSavedTurn(rec);
    setActiveConv(id);
    scrollFluxToBottom();
}
function newConversation() {
    currentConvId = null;
    clearFlux(); showEmpty(true); setActiveConv(null);
    document.getElementById('query-input')?.focus();
}

/* ================================================================== */
/* Turn DOM                                                            */
/* ================================================================== */
function newTurn(query) {
    const el = document.createElement('div');
    el.className = 'turn';
    el.innerHTML =
        `<div class="bubble-user"><div class="u">${escHtml(query)}</div></div>`
        + `<div class="bubble-ai">${AI_AVATAR}<div class="ai-body">`
        +   `<div class="synthesis"><div class="syn-label">SYNTHESIS <span class="syn-badge-off">llm offline</span></div>`
        +   `<div class="syn-text muted">…</div></div>`
        +   `<div class="progress-log"><div class="pbar"><div class="pbar-fill"></div></div><span class="pbar-count"></span></div>`
        +   `<div class="res-label" hidden>RESULTS</div>`
        +   `<ul class="items-list"></ul>`
        + `</div></div>`;
    fluxInner().appendChild(el);
    return {
        el, query,
        listEl: el.querySelector('.items-list'),
        synthEl: el.querySelector('.synthesis'),
        synthTextEl: el.querySelector('.syn-text'),
        badgeEl: el.querySelector('.syn-badge-off'),
        resLabel: el.querySelector('.res-label'),
        progressLog: el.querySelector('.progress-log'),
        pbarFill: el.querySelector('.pbar-fill'),
        pbarCount: el.querySelector('.pbar-count'),
        items: new Map(), order: [], scores: {},
    };
}

function renderSavedTurn(rec) {
    const el = document.createElement('div');
    el.className = 'turn';
    const userBubble = rec.image
        ? `<div class="bubble-user bubble-user--image"><div class="u"><span class="up-icon">🖼</span>${escHtml(truncate(rec.query, 64))}</div></div>`
        : `<div class="bubble-user"><div class="u">${escHtml(rec.query)}</div></div>`;
    el.innerHTML = userBubble
        + `<div class="bubble-ai">${AI_AVATAR}<div class="ai-body">`
        +   `<div class="synthesis"><div class="syn-label">SYNTHESIS <span class="syn-badge-off">llm offline</span></div>`
        +   `<div class="syn-text">${escHtml(rec.synthesis || '')}</div></div>`
        +   (rec.items && rec.items.length ? `<div class="res-label">RESULTS · ${rec.items.length}</div><ul class="items-list"></ul>` : '')
        + `</div></div>`;
    fluxInner().appendChild(el);
    const list = el.querySelector('.items-list');
    if (list && rec.items) rec.items.forEach((item, i) => {
        const card = buildCard(item, 'saved-' + i, i);
        addReportBtn(card, item);
        const sc = item.score ?? 0;
        if (Number.isInteger(sc)) card.classList.add('score-' + sc);
        list.appendChild(card);
    });
}

/* ================================================================== */
/* Composer wiring                                                     */
/* ================================================================== */
const queryInput = document.getElementById('query-input');
queryInput?.addEventListener('input', function () {
    this.style.height = 'auto';
    this.style.height = Math.min(this.scrollHeight, 160) + 'px';
});
queryInput?.addEventListener('keydown', e => {
    if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); submitQuery(); }
});
document.getElementById('send-btn')?.addEventListener('click', submitQuery);
document.getElementById('new-search-btn')?.addEventListener('click', newConversation);
document.getElementById('conv-list')?.addEventListener('click', e => {
    const del = e.target.closest('.conv-del');
    if (del) { e.stopPropagation(); onDeleteConv(del.dataset.id); return; }
    const row = e.target.closest('.conv');
    if (row && row.dataset.id) loadConversation(row.dataset.id);
});

/* Delete a search — no confirmation. */
async function onDeleteConv(id) {
    if (!id) return;
    try { await deleteConversation(id); } catch (_) {}
    if (id === currentConvId) { currentConvId = null; clearFlux(); showEmpty(true); }
    await renderSidebar();
}

/* ================================================================== */
/* Submit                                                             */
/* ================================================================== */
async function submitQuery() {
    const query = (queryInput?.value || '').trim();
    if (!query) return;
    setHighlightQuery(query);

    const imgUrl = extractImageUrl(query);
    if (imgUrl) {
        queryInput.value = ''; queryInput.style.height = 'auto';
        runMedia(fetch('/media', {
            method: 'POST', headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ url: imgUrl }),
        }), imgUrl);
        return;
    }

    if (!currentConvId) await createConversation(query);
    queryInput.value = ''; queryInput.style.height = 'auto';
    showEmpty(false);

    const btn = document.getElementById('send-btn');
    const t = newTurn(query);
    currentTurn = t;
    streamCards = new Map();
    scrollFluxToBottom();

    btn.classList.add('loading');
    btn.disabled = true;
    initTypeFilters();
    startProgress();

    try {
        const resp = await fetch('/query', {
            method: 'POST', headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ query }),
        });
        if (!resp.ok) throw new Error(`HTTP ${resp.status}`);
        const reader = resp.body.getReader();
        const decoder = new TextDecoder();
        let buffer = '';
        while (true) {
            const { done, value } = await reader.read();
            if (done) break;
            buffer += decoder.decode(value, { stream: true });
            const parts = buffer.split('\n\n');
            buffer = parts.pop();
            for (const part of parts) {
                const line = part.trim();
                if (line.startsWith('data: ')) {
                    try { handleEvent(t, JSON.parse(line.slice(6))); }
                    catch (e) { console.warn('[emquest] parse error', e); }
                }
            }
        }
    } catch (err) {
        console.error('[emquest]', err);
        showTurnError(t, err.message);
    } finally {
        btn.classList.remove('loading');
        btn.disabled = false;
        finishProgress(t);
        fadeOut(t.progressLog);
        renderSynthesis(t);
        persistTurn(t);
    }
}

/* ================================================================== */
/* SSE event handler (scoped to the current turn)                     */
/* ================================================================== */
function handleEvent(t, event) {
    switch (event.type) {

        case 'status':
            break;

        case 'item': {
            const card = buildCard(event.item, event.sid, t.items.size);
            addReportBtn(card, event.item);
            t.listEl.appendChild(card);
            streamCards.set(event.sid, card);
            t.items.set(event.sid, event.item);
            if (t.resLabel) t.resLabel.hidden = false;
            if (t.pbarCount) t.pbarCount.textContent = t.items.size;
            applyTypeFilter();
            if (nearBottom(fluxEl())) scrollFluxToBottom();
            break;
        }

        case 'reorder': {
            const sids = event.sids || [];
            const scores = event.scores || {};
            const isFinal = event.final !== false;
            if (sids.length === 0) break;
            t.order = sids; t.scores = scores;

            const first = new Map();
            streamCards.forEach((card) => { if (card.isConnected) first.set(card, card.getBoundingClientRect()); });

            if (isFinal) {
                streamCards.forEach((card, sid) => {
                    if (!sids.includes(sid)) { card.classList.add('card-removed'); setTimeout(() => card.remove(), 350); }
                });
            }
            sids.forEach((sid, pos) => {
                const card = streamCards.get(sid);
                if (!card) return;
                const score = scores[String(sid)] ?? 0;
                card.dataset.score = score;
                if (Number.isInteger(score)) {
                    card.className = card.className.replace(/\bscore-\d\b/g, '').trim();
                    card.classList.add(`score-${score}`);
                }
                const idx = card.querySelector('.item-index');
                if (idx) idx.textContent = String(pos + 1).padStart(2, '0');
                t.listEl.appendChild(card);
            });
            requestAnimationFrame(() => {
                const vh = window.innerHeight || 800;
                streamCards.forEach((card) => {
                    const prev = first.get(card);
                    if (!prev || !card.isConnected) return;
                    const now = card.getBoundingClientRect();
                    if (now.bottom < -vh * 0.3 || now.top > vh * 1.3) return;
                    const dx = prev.left - now.left, dy = prev.top - now.top;
                    if (Math.abs(dx) < 1 && Math.abs(dy) < 1) return;
                    const anim = card.animate(
                        [{ transform: `translate(${dx}px, ${dy}px)` }, { transform: 'translate(0, 0)' }],
                        { duration: 420, easing: 'cubic-bezier(0.22, 1, 0.36, 1)' });
                    if (card._flip) card._flip.cancel();
                    card._flip = anim;
                    anim.onfinish = () => { if (card._flip === anim) card._flip = null; };
                });
            });
            applyTypeFilter();
            if (isFinal) { finishProgress(t); setTimeout(applyTypeFilter, 400); }
            break;
        }

        /* LLM answer streaming into the synthesis slot. */
        case 'answer': {
            if (t.synthTextEl) {
                t._answered = true;
                if (t.badgeEl) t.badgeEl.remove();
                t.synthTextEl.classList.remove('muted');
                t.synthTextEl.textContent = event.message || '';
            }
            break;
        }

        case 'error':
            showTurnError(t, event.message);
            break;
    }
}

/* Deterministic synthesis until the LLM fills the slot. */
function renderSynthesis(t) {
    if (!t.synthTextEl || t._answered) return;
    const ordered = (t.order.length ? t.order : [...t.items.keys()]);
    const items = ordered.map(sid => t.items.get(sid)).filter(Boolean);
    const n = items.length;
    if (n === 0) { t.synthTextEl.textContent = 'No results found for this query.'; t.synthTextEl.classList.remove('muted'); return; }
    const domains = {}; let dns = 0, media = 0;
    for (const it of items) {
        if (it.url) { const hh = hostnameOf(it.url); if (hh) domains[hh] = (domains[hh] || 0) + 1; }
        if (Array.isArray(it.ips) && it.ips.length) dns++;
        if ((it.media_type && it.media_type !== 'text') || it.doc_type) media++;
    }
    const top = Object.entries(domains).sort((a, b) => b[1] - a[1])[0];
    const bits = [`${n} result${n !== 1 ? 's' : ''} aggregated`];
    if (top) bits.push(`top domain ${top[0]}`);
    if (dns) bits.push(`${dns} DNS record${dns !== 1 ? 's' : ''}`);
    if (media) bits.push(`${media} media item${media !== 1 ? 's' : ''}`);
    t.synthTextEl.textContent = bits.join(' · ') + '.';
    t.synthTextEl.classList.remove('muted');
}

async function persistTurn(t) {
    if (t._saved) return;
    t._saved = true;
    try {
        if (!currentConvId) return;
        const conv = await cGet('conversations', currentConvId);
        if (!conv) return;
        const ordered = (t.order.length ? t.order : [...t.items.keys()]);
        const items = ordered.map(sid => { const it = t.items.get(sid); return it ? stripItem(it, t.scores[String(sid)]) : null; }).filter(Boolean);
        const seq = conv.seq || 0;
        const rec = { convId: currentConvId, seq, query: t.query, ts: Date.now(), synthesis: t.synthTextEl ? t.synthTextEl.textContent : '', items };
        const bytes = byteLen(rec);
        await cPut('turns', rec);
        conv.seq = seq + 1; conv.updatedAt = Date.now(); conv.bytes = (conv.bytes || 0) + bytes;
        await cPut('conversations', conv);
        await setUsage((await getUsage()) + bytes);
        await renderSidebar();
        setActiveConv(currentConvId);
        await enforceBudget();
    } catch (e) { console.warn('[emquest] persist failed', e); }
}

/* Keep only text + URLs — never image bytes. Thumbnails re-fetch lazily. */
function stripItem(it, score) {
    const o = {};
    for (const k of ['media_type', 'doc_type', 'label', 'url', 'value', 'thumbnail', 'media_url', 'source', 'source_id', 'license', 'author', 'duration']) {
        if (it[k] != null && it[k] !== '') o[k] = it[k];
    }
    if (Array.isArray(it.ips) && it.ips.length) o.ips = it.ips;
    o.score = (score ?? it.score ?? 0);
    return o;
}

function showTurnError(t, msg) {
    const body = t.el.querySelector('.ai-body');
    if (!body) return;
    if (t.progressLog) t.progressLog.remove();
    const w = document.createElement('div'); w.innerHTML = renderError(msg);
    body.appendChild(w.firstElementChild);
}

/* ================================================================== */
/* Memory budget: compress oldest turns, then purge oldest convs      */
/* ================================================================== */
async function enforceBudget() {
    let usage = await getUsage();
    if (usage <= MEM_BUDGET * COMPRESS_AT) return;
    const turns = (await cGetAll('turns')).filter(r => !r.compressed).sort((a, b) => a.ts - b.ts);
    for (const rec of turns) {
        if (usage <= MEM_BUDGET * COMPRESS_AT) break;
        const before = byteLen(rec);
        rec.items = (rec.items || []).slice(0, 3).map(it => ({ media_type: it.media_type, label: it.label, url: it.url, score: it.score }));
        rec.compressed = true;
        await cPut('turns', rec);
        const freed = before - byteLen(rec);
        usage = Math.max(0, usage - freed);
        await setUsage(usage);
        const conv = await cGet('conversations', rec.convId);
        if (conv) { conv.bytes = Math.max(0, (conv.bytes || 0) - freed); await cPut('conversations', conv); }
    }
    if (usage > MEM_BUDGET) {
        const convs = (await cGetAll('conversations')).sort((a, b) => a.updatedAt - b.updatedAt);
        for (const c of convs) {
            if (usage <= MEM_BUDGET) break;
            if (c.id === currentConvId) continue;
            await deleteConversation(c.id);
            usage = await getUsage();
        }
        await renderSidebar();
    }
    updateMemBar();
}
async function deleteConversation(id) {
    const turns = await turnsFor(id);
    let freed = 0;
    for (const rec of turns) { freed += byteLen(rec); await cDel('turns', [id, rec.seq]); }
    await cDel('conversations', id);
    await setUsage((await getUsage()) - freed);
}

/* ================================================================== */
/* Progress bar                                                        */
/* ================================================================== */
function startProgress() { applyTypeFilter(); }
function finishProgress(t) {
    const fill = t && t.pbarFill;
    if (fill) { fill.style.animation = 'none'; fill.style.transition = 'width 0.35s ease'; fill.style.width = '100%'; }
}
function fadeOut(node) {
    if (!node) return;
    setTimeout(() => { node.style.transition = 'opacity 1.2s ease'; node.style.opacity = '0'; setTimeout(() => node.remove(), 1200); }, 1200);
}

/* ================================================================== */
/* Card builder                                                        */
/* ================================================================== */
function buildCard(item, sid, pos) {
    const li = document.createElement('li');
    li.className = `item-card score-${item.score ?? 0}`;
    li.dataset.sid = sid;
    li.dataset.mtype = item.doc_type ? 'document' : (item.media_type || 'text');
    li.style.animationDelay = `${Math.min(pos * 50, 400)}ms`;
    li.innerHTML = buildCardBody(item, pos);

    li.querySelectorAll('img.media-thumb').forEach(img => {
        if (img.classList.contains('media-thumb--audio')) img.addEventListener('error', () => img.remove());
        else { img.addEventListener('load', () => mediaImgLoad(img)); img.addEventListener('error', () => mediaImgError(img)); }
    });

    if (item.media_type === 'image') {
        const full = safeUrl(item.media_url) || safeUrl(item.thumbnail);
        if (full) { li.classList.add('item-card--media'); li.addEventListener('click', e => { if (e.target.closest('a')) return; openLightbox(full); }); }
    } else if (item.media_type === 'video') {
        const u = safeUrl(item.url) || safeUrl(item.media_url);
        if (u) { li.classList.add('item-card--media'); li.addEventListener('click', e => { if (e.target.closest('a, audio')) return; window.open(u, '_blank', 'noopener'); }); }
    } else if (item.media_type === 'audio') {
        li.classList.add('item-card--media'); initAudioPlayer(li);
    } else if (item.url) {
        const url = safeUrl(item.url);
        if (url) {
            li.classList.add('item-card--link');
            const kind = item.doc_type || docKind(url);
            if (kind) li.classList.add('item-card--doc');
            li.addEventListener('click', e => { if (e.target.closest('a')) return; if (kind) openDocViewer(url); else window.open(url, '_blank', 'noopener'); });
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
        const url = safeUrl(item.url) || '#';
        const hasTitle = item.label && item.label !== 'Result' && item.label !== item.url && item.label !== hostnameOf(item.url);
        if (hasTitle) {
            body = `
                <div class="item-web">
                    <a href="${escAttr(url)}" target="_blank" rel="noopener" class="item-title">${highlight(item.label)}</a>
                    <span class="item-url">${escHtml(item.url)}</span>
                    ${item.value ? `<p class="item-resume">${highlight(item.value)}</p>` : ''}
                </div>
                <span class="item-arrow">↗</span>`;
        } else {
            body = `
                <div class="item-web">
                    <a href="${escAttr(url)}" target="_blank" rel="noopener" class="item-url item-url--hero">${escHtml(item.url)}</a>
                    ${item.value ? `<p class="item-resume">${highlight(item.value)}</p>` : ''}
                </div>
                <span class="item-arrow">↗</span>`;
        }
    } else if (Array.isArray(item.ips) && item.ips.length) {
        const badges = item.ips.map(ip => `<span class="ip-badge">${escHtml(String(ip))}</span>`).join('');
        body = `
            <div class="item-dns">
                <div class="item-dns-header"><span class="item-domain">${highlight(item.label)}</span><span class="dns-badge">DNS</span></div>
                <div class="ip-list">${badges}</div>
                ${item.value ? `<p class="item-resume">${highlight(item.value)}</p>` : ''}
            </div>`;
    } else {
        const label = (item.label && item.label !== 'Result') ? item.label : null;
        body = `
            <div class="item-generic">
                ${label ? `<span class="item-title">${highlight(label)}</span>` : ''}
                ${item.value ? `<p class="item-resume">${highlight(item.value)}</p>` : ''}
            </div>`;
    }
    return `<span class="item-index">${escHtml(num)}</span><div class="item-body">${body}</div>`;
}

function buildMediaBody(item) {
    const t = item.media_type;
    const title = (item.label && item.label !== 'Result') ? highlight(item.label) : '';
    const foot = mediaFooter(item);
    const thumb = item.thumbnail ? safeUrl(item.thumbnail) : '';
    if (t === 'audio') {
        const src = safeUrl(item.media_url) || '';
        return `
            <div class="media-card media-audio">
                <div class="media-audio-head">
                    ${thumb ? `<img class="media-thumb media-thumb--audio" loading="lazy" referrerpolicy="no-referrer" src="${escAttr(thumb)}" alt="">` : ''}
                    <div class="media-meta">
                        ${title ? `<span class="item-title">${title}</span>` : ''}
                        ${item.value ? `<p class="item-resume">${highlight(item.value)}</p>` : ''}
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
    const durBadge = (t === 'video' && item.duration) ? `<span class="media-duration">${escHtml(fmtDur(item.duration))}</span>` : '';
    const play = (t === 'video') ? `<span class="media-play">▶</span>` : '';
    const thumbHtml = thumb
        ? `<img class="media-thumb" loading="lazy" referrerpolicy="no-referrer" src="${escAttr(thumb)}" alt="${escAttr(item.label || '')}">`
        : `<span class="media-thumb media-thumb--placeholder" data-type="${escAttr(t)}"></span>`;
    return `
        <div class="media-card media-${escAttr(t)}">
            <div class="media-thumb-wrap">${thumbHtml}${play}${durBadge}</div>
            <div class="media-meta">
                ${title ? `<span class="item-title">${title}</span>` : ''}
                ${item.value ? `<p class="item-resume">${highlight(item.value)}</p>` : ''}
                ${foot}
            </div>
        </div>`;
}

function mediaFooter(item) {
    const bits = [];
    if (item.source) bits.push(escHtml(item.source));
    if (item.license) bits.push(escHtml(item.license));
    if (item.author) bits.push(escHtml(item.author));
    return bits.length ? `<span class="media-license">${bits.join(' · ')}</span>` : '';
}
function fmtDur(s) { s = parseInt(s, 10) || 0; const m = Math.floor(s / 60), ss = String(s % 60).padStart(2, '0'); return `${m}:${ss}`; }
function mediaImgError(img) {
    if (img.closest('.media-image')) {
        const card = img.closest('.item-card, .drift-card');
        if (card) { const sid = card.dataset.sid; if (sid !== undefined) streamCards.delete(Number(sid)); card.remove(); return; }
    }
    img.classList.add('media-thumb--broken');
}
function mediaImgLoad(img) { if (!img.naturalWidth || img.naturalWidth < 2 || img.naturalHeight < 2) mediaImgError(img); }

let _lightbox = null;
function initAudioPlayer(root) {
    const el = root.querySelector('.aplayer'), audio = root.querySelector('audio.aplayer-audio');
    const btn = root.querySelector('.aplayer-play'), bar = root.querySelector('.aplayer-bar');
    const fill = root.querySelector('.aplayer-fill'), tEl = root.querySelector('.aplayer-time');
    if (!el || !audio || !btn) return;
    const fmt = s => { s = Math.floor(s || 0); return Math.floor(s / 60) + ':' + String(s % 60).padStart(2, '0'); };
    btn.addEventListener('click', e => { e.stopPropagation(); if (audio.paused) audio.play(); else audio.pause(); });
    audio.addEventListener('play', () => el.classList.add('playing'));
    audio.addEventListener('pause', () => el.classList.remove('playing'));
    audio.addEventListener('ended', () => el.classList.remove('playing'));
    audio.addEventListener('loadedmetadata', () => { if (tEl) tEl.textContent = '0:00 / ' + fmt(audio.duration); });
    audio.addEventListener('timeupdate', () => {
        const d = audio.duration || 0, c = audio.currentTime || 0;
        if (fill) fill.style.width = d ? (c / d * 100) + '%' : '0%';
        if (tEl) tEl.textContent = fmt(c) + (d ? ' / ' + fmt(d) : '');
    });
    if (bar) bar.addEventListener('click', e => {
        e.stopPropagation();
        const r = bar.getBoundingClientRect(), p = Math.min(1, Math.max(0, (e.clientX - r.left) / r.width));
        if (audio.duration) audio.currentTime = p * audio.duration;
    });
    const volBtn = root.querySelector('.aplayer-vol-btn'), vol = root.querySelector('.aplayer-vol'), dl = root.querySelector('.aplayer-dl');
    if (vol) vol.addEventListener('input', e => { e.stopPropagation(); audio.volume = parseFloat(vol.value); audio.muted = audio.volume === 0; el.classList.toggle('muted', audio.muted); });
    if (volBtn) volBtn.addEventListener('click', e => { e.stopPropagation(); audio.muted = !audio.muted; el.classList.toggle('muted', audio.muted); if (vol) vol.value = audio.muted ? 0 : (audio.volume || 1); });
    if (dl) dl.addEventListener('click', e => e.stopPropagation());
}

/* ================================================================== */
/* Media-type filter — acts only on the current turn                  */
/* ================================================================== */
const _MT_DB = 'emergence', _MT_STORE = 'prefs', _MT_KEY = 'mediaTypes';
function _mtDbOpen() {
    return new Promise((res, rej) => {
        const r = indexedDB.open(_MT_DB, 1);
        r.onupgradeneeded = () => r.result.createObjectStore(_MT_STORE);
        r.onsuccess = () => res(r.result);
        r.onerror = () => rej(r.error);
    });
}
async function persistMediaTypes() {
    try {
        const tf = document.getElementById('type-filters');
        if (!tf) return;
        const map = {};
        tf.querySelectorAll('input').forEach(c => { map[c.value] = c.checked; });
        const db = await _mtDbOpen();
        await new Promise(res => { const req = db.transaction(_MT_STORE, 'readwrite').objectStore(_MT_STORE).put(map, _MT_KEY); req.onsuccess = () => res(); req.onerror = () => res(); });
    } catch (_) {}
}
async function restoreMediaTypes() {
    try {
        const db = await _mtDbOpen();
        const vals = await new Promise(res => { const req = db.transaction(_MT_STORE, 'readonly').objectStore(_MT_STORE).get(_MT_KEY); req.onsuccess = () => res(req.result); req.onerror = () => res(undefined); });
        if (vals == null) return;
        const tf = document.getElementById('type-filters');
        if (!tf) return;
        const legacy = ['text', 'image', 'audio', 'video'];
        if (Array.isArray(vals)) tf.querySelectorAll('input').forEach(c => { c.checked = vals.includes(c.value) || !legacy.includes(c.value); });
        else tf.querySelectorAll('input').forEach(c => { c.checked = vals[c.value] !== false; });
        applyTypeFilter();
    } catch (_) {}
}
let _typeFiltersInit = false;
function initTypeFilters() {
    if (_typeFiltersInit) return;
    const tf = document.getElementById('type-filters');
    if (tf) { tf.addEventListener('change', () => { applyTypeFilter(); persistMediaTypes(); }); _typeFiltersInit = true; }
}
function applyTypeFilter() {
    const tf = document.getElementById('type-filters');
    const c = document.getElementById('tf-count');
    const list = currentTurn && currentTurn.listEl;
    if (!tf || !list) { if (c) c.textContent = ''; return; }
    const checked = [...tf.querySelectorAll('input:checked')].map(x => x.value);
    const showAll = checked.length === 0;
    let visible = 0;
    list.querySelectorAll('li.item-card').forEach(li => {
        const ty = li.dataset.mtype || 'text';
        const hidden = !showAll && !checked.includes(ty);
        li.classList.toggle('type-hidden', hidden);
        if (!hidden) visible++;
    });
    if (c) c.textContent = visible ? visible + (visible === 1 ? ' result' : ' results') : '';
}

/* ================================================================== */
/* Admin-only nav links (injected when an admin token exists)         */
/* ================================================================== */
(function(){
  const nav=document.querySelector('.topbar'), clock=document.getElementById('clock');
  if(!nav) return;
  function idbToken(){return new Promise(res=>{try{
    const req=indexedDB.open('emquest_admin',1);
    req.onupgradeneeded=()=>{try{req.result.createObjectStore('kv')}catch(e){}};
    req.onsuccess=()=>{try{const g=req.result.transaction('kv','readonly').objectStore('kv').get('token');
      g.onsuccess=()=>res(g.result||null); g.onerror=()=>res(null);}catch(e){res(null)}};
    req.onerror=()=>res(null);
  }catch(e){res(null)}});}
  idbToken().then(token=>{ if(!token) return;
    fetch('/admin/nav',{headers:{authorization:'Bearer '+token}})
      .then(r=>r.ok?r.text():null)
      .then(html=>{ if(!html) return; const tmp=document.createElement('div'); tmp.innerHTML=html;
        Array.from(tmp.children).forEach(el=>nav.insertBefore(el, clock)); })
      .catch(()=>{});
  });
})();

/* result-card 3D tilt (delegated on the flux; skip touch/reduced-motion) */
(function(){
  if(matchMedia('(prefers-reduced-motion:reduce)').matches||matchMedia('(pointer:coarse)').matches) return;
  const list=document.getElementById('flux'); if(!list) return;
  list.addEventListener('mousemove',e=>{const c=e.target.closest('.item-card'); if(!c)return;
    const r=c.getBoundingClientRect(),px=(e.clientX-r.left)/r.width-.5,py=(e.clientY-r.top)/r.height-.5;
    c.style.transform=`rotateY(${px*1.6}deg) rotateX(${-py*1.6}deg)`});
  list.addEventListener('mouseout',e=>{const c=e.target.closest('.item-card'); if(c)c.style.transform=''});
})();

/* ================================================================== */
/* Lightbox + document viewer                                         */
/* ================================================================== */
function ensureLightbox() {
    if (!_lightbox) {
        _lightbox = document.createElement('div');
        _lightbox.id = 'media-lightbox';
        _lightbox.className = 'lightbox';
        _lightbox.innerHTML = '<div class="lightbox-inner"><button class="lightbox-close" aria-label="Close">✕</button><div class="lightbox-body"></div></div>';
        _lightbox.addEventListener('click', e => { if (e.target === _lightbox || e.target.closest('.lightbox-close')) closeLightbox(); });
        document.addEventListener('keydown', e => { if (e.key === 'Escape' && _lightbox) closeLightbox(); });
        document.body.appendChild(_lightbox);
    }
    return _lightbox.querySelector('.lightbox-body');
}
function closeLightbox() { if (!_lightbox) return; _lightbox.classList.remove('open'); const b = _lightbox.querySelector('.lightbox-body'); if (b) b.innerHTML = ''; }
function openLightbox(src) {
    const body = ensureLightbox();
    body.innerHTML = '<img class="lightbox-img" referrerpolicy="no-referrer" alt="">' +
        '<div class="doc-bar"><a class="doc-open" href="' + escAttr(src) + '" target="_blank" rel="noopener">Open original ↗</a></div>';
    body.querySelector('img').src = src;
    _lightbox.classList.add('open');
}
function docKind(url) {
    const u = (url || '').split('?')[0].split('#')[0].toLowerCase();
    if (u.endsWith('.pdf')) return 'pdf';
    if (u.endsWith('.docx')) return 'docx';
    if (u.endsWith('.xlsx') || u.endsWith('.xls')) return 'xlsx';
    if (u.endsWith('.csv')) return 'csv';
    if (u.includes('/pdf/')) return 'pdf';
    return null;
}
const _scripts = {};
function loadScript(src) {
    return _scripts[src] || (_scripts[src] = new Promise((res, rej) => { const s = document.createElement('script'); s.src = src; s.onload = res; s.onerror = rej; document.head.appendChild(s); }));
}
async function openDocViewer(url) {
    const kind = docKind(url);
    const body = ensureLightbox();
    _lightbox.classList.add('open');
    const orig = '<a class="doc-open" href="' + escAttr(url) + '" target="_blank" rel="noopener">Open original ↗</a>';
    if (kind === 'pdf') { body.innerHTML = '<iframe class="doc-frame" src="' + escAttr(url) + '"></iframe><div class="doc-bar">' + orig + '</div>'; return; }
    body.innerHTML = '<div class="doc-loading">Loading preview…</div>';
    try {
        const resp = await fetch(url);
        if (!resp.ok) throw new Error('http');
        const ab = await resp.arrayBuffer();
        if (kind === 'docx') {
            await loadScript('/static/vendor/mammoth.browser.min.js');
            const r = await window.mammoth.convertToHtml({ arrayBuffer: ab });
            body.innerHTML = '<div class="doc-html">' + r.value + '</div><div class="doc-bar">' + orig + '</div>';
        } else if (kind === 'xlsx' || kind === 'csv') {
            await loadScript('/static/vendor/xlsx.full.min.js');
            const wb = window.XLSX.read(ab, { type: 'array' });
            const first = wb.Sheets[wb.SheetNames[0]];
            const table = window.XLSX.utils.sheet_to_html(first);
            body.innerHTML = '<div class="doc-html doc-sheet">' + table + '</div><div class="doc-bar">' + orig + '</div>';
        } else { throw new Error('unsupported'); }
    } catch (e) {
        body.innerHTML = '<div class="doc-fallback"><p>Can\'t preview this file here (unsupported format, or the source blocks cross-origin access).</p>' + orig + '</div>';
    }
}

/* ================================================================== */
/* Error                                                              */
/* ================================================================== */
function renderError(msg) { return `<div class="error-card"><span class="error-icon">⚠</span><span>${escHtml(msg || 'Unexpected error.')}</span></div>`; }

/* ================================================================== */
/* Utilities                                                          */
/* ================================================================== */
function escHtml(s) {
    if (s == null) return '';
    return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}
function _fold(s) { return [...String(s == null ? '' : s)].map(c => (c.normalize('NFD')[0] || c).toLowerCase()).join(''); }
let _hlWords = [];
function setHighlightQuery(q) { _hlWords = _fold(q).split(/\s+/).filter(w => w.length >= 2); }
function highlight(text) {
    if (text == null || text === '' || _hlWords.length === 0) return escHtml(text || '');
    const esc = escHtml(text), folded = _fold(esc), marks = [];
    for (const w of _hlWords) { let i = 0; while ((i = folded.indexOf(w, i)) !== -1) { marks.push([i, i + w.length]); i += w.length; } }
    if (marks.length === 0) return esc;
    marks.sort((a, b) => a[0] - b[0]);
    let out = '', cur = 0;
    for (const [a, b] of marks) { if (a < cur) continue; out += esc.slice(cur, a) + '<mark>' + esc.slice(a, b) + '</mark>'; cur = b; }
    return out + esc.slice(cur);
}
function escAttr(s) { return s ? String(s).replace(/"/g, '%22') : '#'; }
function safeUrl(s) { if (!s) return null; const t = String(s).trim(); return /^https?:\/\//i.test(t) ? t : null; }
function hostnameOf(url) { try { return new URL(url).hostname; } catch (_) { return url; } }

/* ================================================================== */
/* File / image media → velora (rendered inside a turn)               */
/* ================================================================== */
const IMG_EXT = /\.(jpe?g|png|webp|gif|tiff?|jp2|bmp)(\?|#|$)/i;
const URL_RE = /https?:\/\/[^\s]+/i;
let _rasterSeq = 0;
function extractImageUrl(text) { const m = text.match(URL_RE); return (m && IMG_EXT.test(m[0])) ? m[0] : null; }

document.getElementById('add-btn')?.addEventListener('click', () => document.getElementById('media-file')?.click());
document.getElementById('media-file')?.addEventListener('change', function () {
    const f = this.files && this.files[0];
    this.value = '';
    if (!f) return;
    if (!f.type.startsWith('image/') && !IMG_EXT.test(f.name)) {
        newMediaTurn(f.name, { image: true }).innerHTML = '<div class="media-msg err">Only images are supported for now.</div>';
        return;
    }
    const fd = new FormData();
    fd.append('file', f, f.name);
    runMedia(fetch('/media', { method: 'POST', body: fd }), f.name);
});

function labelShort(s) {
    let t = String(s).split('#')[0].split('?')[0];
    if (/^https?:\/\//i.test(t)) { const p = t.split('/').filter(Boolean); t = p[p.length - 1] || t; }
    return t.length > 64 ? t.slice(0, 61) + '…' : t;
}
function newMediaTurn(label, opts) {
    opts = opts || {};
    showEmpty(false);
    const el = document.createElement('div');
    el.className = 'turn';
    const full = String(label), short = labelShort(full);
    el.innerHTML =
        `<div class="bubble-user${opts.image ? ' bubble-user--image' : ''}" title="${escAttr(full)}"><div class="u">${opts.image ? '<span class="up-icon">🖼</span>' : ''}${escHtml(short)}</div></div>`
        + `<div class="bubble-ai">${AI_AVATAR}<div class="ai-body"></div></div>`;
    fluxInner().appendChild(el);
    scrollFluxToBottom();
    return el.querySelector('.ai-body');
}
async function runMedia(fetchPromise, label) {
    if (!currentConvId) await createConversation(label || 'image');
    const body = newMediaTurn(label || 'image', { image: true });
    body.innerHTML = '<div class="progress-log"><div class="progress-line"><span class="progress-arrow">›</span> velora is rendering the image…</div></div>';
    try {
        const resp = await fetchPromise;
        const data = await resp.json();
        if (!resp.ok || data.error) { body.innerHTML = `<div class="media-msg err">${escHtml(data.error || ('HTTP ' + resp.status))}</div>`; return; }
        const card = await pollMediaPrepare(data);
        showRaster(body, card);
    } catch (e) { body.innerHTML = `<div class="media-msg err">${escHtml(String((e && e.message) || e))}</div>`; }
}
async function pollMediaPrepare(resp) {
    if (!resp || resp.status !== 'processing') return resp;
    for (let i = 0; i < 200; i++) {
        await new Promise(f => setTimeout(f, 1500));
        let st;
        try { st = await (await fetch(resp.poll)).json(); } catch (_) { continue; }
        if (st.status === 'done') return st;
        if (st.status === 'error') throw new Error(st.error || 'render failed');
        if (st.status === 'not_found') throw new Error('render expired');
    }
    throw new Error('render timed out');
}
function showRaster(body, card) {
    if (typeof L === 'undefined') { body.innerHTML = '<div class="media-msg err">map unavailable</div>'; return; }
    const mapId = 'raster-map-' + (++_rasterSeq);
    const nz = card.maxNativeZoom || 19;
    const stats = card.stats ? 'NDVI mean ' + (+card.stats.mean).toFixed(3) : '';
    body.innerHTML =
        '<ul class="items-list"><li class="item-card item-raster">'
        + '<div class="raster-head"><span class="raster-badge">🛰 VELORA</span><span class="raster-id">#' + escHtml(card.id || '') + '</span>'
        + (stats ? '<span class="raster-stats">' + escHtml(stats) + '</span>' : '') + '</div>'
        + '<div id="' + mapId + '" class="raster-map"></div></li></ul>';
    const map = L.map(mapId, { attributionControl: false, minZoom: 0, maxZoom: nz + 8 });
    const b = card.bounds ? L.latLngBounds(card.bounds) : null;
    L.tileLayer(card.tiles, { bounds: b, noWrap: true, maxNativeZoom: nz, maxZoom: nz + 8, tileSize: 256 }).addTo(map);
    if (b) map.fitBounds(b); else map.setView([0, 0], 2);
}

/* ================================================================== */
/* Voice search (local STT)                                           */
/* ================================================================== */
(function () {
  const micBtn = document.getElementById('mic-btn');
  const input  = document.getElementById('query-input');
  const status = document.getElementById('meta-status');
  if (!micBtn || !input) return;
  let recorder = null, chunks = [], stream = null, recording = false;
  let vadRAF = null, vadCtx = null;
  const setStatus = (m, rec) => { if (!status) return; status.textContent = m || ''; status.classList.toggle('rec', !!rec); };
  function stopVad() { if (vadRAF) { cancelAnimationFrame(vadRAF); vadRAF = null; } if (vadCtx) { try { vadCtx.close(); } catch (_) {} vadCtx = null; } }
  function startVad(mediaStream) {
    const AC = window.AudioContext || window.webkitAudioContext;
    vadCtx = new AC();
    if (vadCtx.state === 'suspended') { try { vadCtx.resume(); } catch (_) {} }
    const src = vadCtx.createMediaStreamSource(mediaStream);
    const an = vadCtx.createAnalyser(); an.fftSize = 1024; src.connect(an);
    const buf = new Float32Array(an.fftSize);
    const SILENCE_MS = 1200, MAX_MS = 15000, MIN_MS = 700, CAL_MS = 350;
    let noise = 0.005, calN = 0, spoke = false, silenceStart = 0;
    const t0 = performance.now();
    const tick = () => {
      if (!recording || !recorder) return;
      an.getFloatTimeDomainData(buf);
      let sum = 0; for (let i = 0; i < buf.length; i++) sum += buf[i] * buf[i];
      const rms = Math.sqrt(sum / buf.length);
      const now = performance.now(), elapsed = now - t0;
      if (elapsed < CAL_MS) { noise = (noise * calN + rms) / (calN + 1); calN++; }
      const speechThr = Math.max(0.02, noise * 3), silenceThr = Math.max(0.012, noise * 2);
      if (rms > speechThr) { spoke = true; silenceStart = 0; setStatus('recording — pause to send', true); }
      else if (spoke && rms < silenceThr) { if (!silenceStart) silenceStart = now; else if (now - silenceStart > SILENCE_MS && elapsed > MIN_MS) { recorder.stop(); return; } }
      else if (spoke) { silenceStart = 0; }
      if (elapsed > MAX_MS) { recorder.stop(); return; }
      vadRAF = requestAnimationFrame(tick);
    };
    vadRAF = requestAnimationFrame(tick);
  }
  micBtn.addEventListener('click', async () => {
    if (recording) { recorder && recorder.stop(); return; }
    try { stream = await navigator.mediaDevices.getUserMedia({ audio: true }); }
    catch (_) { setStatus('mic access denied'); return; }
    chunks = [];
    recorder = new MediaRecorder(stream);
    recorder.ondataavailable = e => { if (e.data.size) chunks.push(e.data); };
    recorder.onstop = async () => {
      recording = false; micBtn.classList.remove('recording');
      stopVad(); stream.getTracks().forEach(t => t.stop());
      setStatus('transcribing...', true);
      try {
        const wav = await blobToWav16k(new Blob(chunks));
        const fd = new FormData(); fd.append('file', wav, 'audio.wav');
        const r = await fetch('/stt', { method: 'POST', body: fd });
        if (!r.ok) { setStatus('stt unavailable'); return; }
        const { text } = await r.json();
        if (text && text.trim()) { input.value = text.trim(); input.dispatchEvent(new Event('input', { bubbles: true })); input.focus(); setStatus(''); }
        else { setStatus('nothing heard'); }
      } catch (_) { setStatus('stt failed'); }
    };
    recorder.start();
    recording = true; micBtn.classList.add('recording');
    setStatus('listening — speak, then pause to send', true);
    startVad(stream);
  });
  async function blobToWav16k(blob) {
    const buf = await blob.arrayBuffer();
    const AC = window.AudioContext || window.webkitAudioContext;
    const ctx = new AC();
    const decoded = await ctx.decodeAudioData(buf);
    const mono = downmixMono(decoded), res = resample(mono, decoded.sampleRate, 16000);
    ctx.close();
    return encodeWav(res, 16000);
  }
  function downmixMono(ab) { const n = ab.length, out = new Float32Array(n); for (let c = 0; c < ab.numberOfChannels; c++) { const d = ab.getChannelData(c); for (let i = 0; i < n; i++) out[i] += d[i] / ab.numberOfChannels; } return out; }
  function resample(data, from, to) { if (from === to) return data; const ratio = from / to, n = Math.round(data.length / ratio), out = new Float32Array(n); for (let i = 0; i < n; i++) { const idx = i * ratio, i0 = Math.floor(idx), i1 = Math.min(i0 + 1, data.length - 1); out[i] = data[i0] + (data[i1] - data[i0]) * (idx - i0); } return out; }
  function encodeWav(samples, rate) {
    const buf = new ArrayBuffer(44 + samples.length * 2), view = new DataView(buf);
    const wr = (o, s) => { for (let i = 0; i < s.length; i++) view.setUint8(o + i, s.charCodeAt(i)); };
    wr(0, 'RIFF'); view.setUint32(4, 36 + samples.length * 2, true); wr(8, 'WAVE');
    wr(12, 'fmt '); view.setUint32(16, 16, true); view.setUint16(20, 1, true);
    view.setUint16(22, 1, true); view.setUint32(24, rate, true);
    view.setUint32(28, rate * 2, true); view.setUint16(32, 2, true); view.setUint16(34, 16, true);
    wr(36, 'data'); view.setUint32(40, samples.length * 2, true);
    let o = 44;
    for (let i = 0; i < samples.length; i++, o += 2) { const s = Math.max(-1, Math.min(1, samples[i])); view.setInt16(o, s < 0 ? s * 0x8000 : s * 0x7fff, true); }
    return new Blob([view], { type: 'audio/wav' });
  }
})();

/* ================================================================== */
/* Init                                                                */
/* ================================================================== */
initTypeFilters();
restoreMediaTypes();
renderSidebar();
