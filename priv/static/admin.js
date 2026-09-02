/* Emquest admin console — talks to the gated /admin/* JSON routes. */

/* Token is persisted in IndexedDB (origin-scoped, survives across sessions)
 * instead of sessionStorage, so a returning admin is auto-recognized on
 * page load via GET /admin/me. All IndexedDB access is wrapped so a
 * failure (unsupported, private mode, blocked) degrades to "no stored
 * token" rather than throwing. */
const DB_NAME  = 'emquest_admin';
const DB_STORE = 'kv';
const DB_KEY   = 'token';

let currentToken = null;

function openDb() {
    return new Promise((resolve, reject) => {
        if (!('indexedDB' in window)) { reject(new Error('no indexedDB')); return; }
        let req;
        try {
            req = indexedDB.open(DB_NAME, 1);
        } catch (e) { reject(e); return; }
        req.onupgradeneeded = () => {
            const db = req.result;
            if (!db.objectStoreNames.contains(DB_STORE)) db.createObjectStore(DB_STORE);
        };
        req.onsuccess = () => resolve(req.result);
        req.onerror = () => reject(req.error || new Error('indexedDB open failed'));
    });
}

async function idbGet() {
    try {
        const db = await openDb();
        return await new Promise((resolve) => {
            try {
                const tx = db.transaction(DB_STORE, 'readonly');
                const rq = tx.objectStore(DB_STORE).get(DB_KEY);
                rq.onsuccess = () => resolve(rq.result == null ? null : rq.result);
                rq.onerror = () => resolve(null);
            } catch (_e) { resolve(null); }
        });
    } catch (_e) {
        return null;
    }
}

async function idbSet(value) {
    try {
        const db = await openDb();
        return await new Promise((resolve) => {
            try {
                const tx = db.transaction(DB_STORE, 'readwrite');
                tx.objectStore(DB_STORE).put(value, DB_KEY);
                tx.oncomplete = () => resolve();
                tx.onerror = () => resolve();
            } catch (_e) { resolve(); }
        });
    } catch (_e) {
        /* no-op */
    }
}

async function idbDel() {
    try {
        const db = await openDb();
        return await new Promise((resolve) => {
            try {
                const tx = db.transaction(DB_STORE, 'readwrite');
                tx.objectStore(DB_STORE).delete(DB_KEY);
                tx.oncomplete = () => resolve();
                tx.onerror = () => resolve();
            } catch (_e) { resolve(); }
        });
    } catch (_e) {
        /* no-op */
    }
}

function escHtml(s) {
    return String(s == null ? '' : s)
        .replace(/&/g, '&amp;').replace(/</g, '&lt;')
        .replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

function setStatus(msg, kind) {
    const el = document.getElementById('status-msg');
    if (!el) return;
    el.textContent = msg || '';
    el.className = kind || '';
}

function authHeaders(token) {
    return { 'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json' };
}

async function apiPost(path, token, body) {
    const r = await fetch(path, {
        method: 'POST',
        headers: authHeaders(token),
        body: JSON.stringify(body)
    });
    let payload = null;
    try { payload = await r.json(); } catch (_e) { /* ignore */ }
    if (!r.ok) {
        const msg = (payload && payload.error) ? payload.error : ('HTTP ' + r.status);
        throw new Error(msg);
    }
    return payload;
}

/* Validate a token against /admin/me. Returns the admin name on success,
 * null on 401/other failure. */
async function fetchMe(token) {
    try {
        const r = await fetch('/admin/me', { headers: { 'Authorization': 'Bearer ' + token } });
        if (!r.ok) return null;
        const payload = await r.json();
        return (payload && typeof payload.name === 'string') ? payload.name : null;
    } catch (_e) {
        return null;
    }
}

function showLoginRow() {
    const loginRow = document.getElementById('login-row');
    const greeting = document.getElementById('greeting');
    const logout   = document.getElementById('logout');
    if (loginRow) loginRow.hidden = false;
    if (greeting) { greeting.hidden = true; greeting.textContent = ''; }
    if (logout) logout.hidden = true;
}

function showGreeting(name) {
    const loginRow = document.getElementById('login-row');
    const greeting = document.getElementById('greeting');
    const logout   = document.getElementById('logout');
    if (loginRow) loginRow.hidden = true;
    if (greeting) { greeting.hidden = false; greeting.textContent = 'Connecté : ' + name; }
    if (logout) logout.hidden = false;
}

function tierClass(tier) {
    if (tier === 'excluded')   return 'tier tier-excluded';
    if (tier === 'quarantine') return 'tier tier-quarantine';
    return 'tier tier-normal';
}

function verifiedBadge(peer) {
    if (!peer.verified) return '';
    return '<span class="badge-verified" title="pubkey bound">&#10003;</span>';
}

function rootBadge(peer) {
    if (!peer.root) return '';
    return '<span class="badge-root" title="configured root pubkey">&#9733; ROOT</span>';
}

function rowMarkup(peer) {
    const id    = peer.id;
    const trust = (typeof peer.trust === 'number') ? peer.trust.toFixed(2) : peer.trust;
    return `
        <td>${escHtml(peer.name || '(unnamed)')} ${verifiedBadge(peer)} ${rootBadge(peer)}</td>
        <td class="mono">${escHtml(id || '&mdash;')}</td>
        <td>${escHtml(trust)}</td>
        <td><span class="${tierClass(peer.tier)}">${escHtml(peer.tier)}</span></td>
        <td>${peer.query_port != null ? escHtml(peer.query_port) : '&mdash;'}</td>
        <td>${peer.banned ? '<span class="badge-banned">banned</span>' : ''}</td>
        <td>${escHtml(peer.role || '&mdash;')}</td>
        <td class="mono muted">${escHtml(peer.pubkey_fp || '&mdash;')}</td>
        <td>${peer.last_seen != null ? escHtml(peer.last_seen) : '&mdash;'}</td>
        <td class="row-actions">
            <button type="button" class="ban-btn" ${peer.banned || !id ? 'disabled' : ''}>Ban</button>
            <button type="button" class="unban-btn" ${!peer.banned || !id ? 'disabled' : ''}>Unban</button>
            <input type="text" class="trust-input" placeholder="0.0-1.0" ${!id ? 'disabled' : ''}>
            <button type="button" class="trust-btn" ${!id ? 'disabled' : ''}>Set</button>
        </td>
    `;
}

function renderPeers(peers) {
    const tbody = document.getElementById('peer-rows');
    tbody.innerHTML = '';

    if (!Array.isArray(peers) || peers.length === 0) {
        tbody.innerHTML = '<tr><td colspan="10" class="empty">No peers.</td></tr>';
        return;
    }

    const sorted = peers.slice().sort((a, b) =>
        String(a.name || '').toLowerCase().localeCompare(String(b.name || '').toLowerCase()));

    for (const peer of sorted) {
        const tr = document.createElement('tr');
        tr.innerHTML = rowMarkup(peer);

        const banBtn   = tr.querySelector('.ban-btn');
        const unbanBtn = tr.querySelector('.unban-btn');
        const trustBtn = tr.querySelector('.trust-btn');
        const trustIn  = tr.querySelector('.trust-input');

        if (banBtn) banBtn.addEventListener('click', () => doAction('/admin/ban', { id: peer.id }));
        if (unbanBtn) unbanBtn.addEventListener('click', () => doAction('/admin/unban', { id: peer.id }));
        if (trustBtn) trustBtn.addEventListener('click', () => {
            const v = parseFloat(trustIn.value);
            if (Number.isNaN(v)) { setStatus('enter a numeric trust value', 'err'); return; }
            doAction('/admin/trust', { id: peer.id, trust: v });
        });

        tbody.appendChild(tr);
    }
}

async function doAction(path, body) {
    if (!currentToken) { setStatus('enter a token first', 'err'); return; }
    try {
        await apiPost(path, currentToken, body);
        setStatus('ok', 'ok');
        await loadPeers();
    } catch (err) {
        setStatus(err.message, 'err');
    }
}

async function loadPeers() {
    if (!currentToken) { setStatus('enter a token first', 'err'); return; }
    setStatus('loading…');
    try {
        const r = await fetch('/admin/peers', { headers: { 'Authorization': 'Bearer ' + currentToken } });
        if (r.status === 401) { setStatus('unauthorized', 'err'); renderPeers([]); return; }
        if (!r.ok) throw new Error('HTTP ' + r.status);
        const peers = await r.json();
        renderPeers(peers);
        setStatus(peers.length + ' peer' + (peers.length !== 1 ? 's' : ''), 'ok');
    } catch (err) {
        setStatus(err.message, 'err');
    }
}

/* Submit-token flow: validate against /admin/me, persist on success. */
async function submitToken() {
    const tokenInput = document.getElementById('token');
    const token = tokenInput ? tokenInput.value.trim() : '';
    if (!token) { setStatus('enter a token first', 'err'); return; }
    setStatus('checking…');
    const name = await fetchMe(token);
    if (!name) {
        setStatus('token invalide', 'err');
        return;
    }
    currentToken = token;
    await idbSet(token);
    showGreeting(name);
    await loadPeers();
}

async function doLogout() {
    await idbDel();
    currentToken = null;
    const tokenInput = document.getElementById('token');
    if (tokenInput) tokenInput.value = '';
    showLoginRow();
    renderPeers([]);
    setStatus('');
}

async function init() {
    const tokenInput = document.getElementById('token');
    const loadBtn    = document.getElementById('load-btn');
    const logoutBtn  = document.getElementById('logout');

    if (loadBtn) loadBtn.addEventListener('click', submitToken);
    if (tokenInput) tokenInput.addEventListener('keydown', (e) => {
        if (e.key === 'Enter') submitToken();
    });
    if (logoutBtn) logoutBtn.addEventListener('click', doLogout);

    const saved = await idbGet();
    if (saved) {
        const name = await fetchMe(saved);
        if (name) {
            currentToken = saved;
            showGreeting(name);
            await loadPeers();
            return;
        }
        /* stale token */
        await idbDel();
    }
    showLoginRow();
}

document.addEventListener('DOMContentLoaded', () => { init(); });
