/* Emquest admin console — talks to the gated /admin/* JSON routes. */

const TOKEN_KEY = 'emquest_admin_token';

function escHtml(s) {
    return String(s == null ? '' : s)
        .replace(/&/g, '&amp;').replace(/</g, '&lt;')
        .replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

function getToken() {
    const el = document.getElementById('token');
    return el ? el.value.trim() : '';
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

function tierClass(tier) {
    if (tier === 'excluded')   return 'tier tier-excluded';
    if (tier === 'quarantine') return 'tier tier-quarantine';
    return 'tier tier-normal';
}

function rowMarkup(peer) {
    const id    = peer.id;
    const trust = (typeof peer.trust === 'number') ? peer.trust.toFixed(2) : peer.trust;
    return `
        <td>${escHtml(peer.name || '(unnamed)')}</td>
        <td class="mono">${escHtml(id || '&mdash;')}</td>
        <td>${escHtml(trust)}</td>
        <td><span class="${tierClass(peer.tier)}">${escHtml(peer.tier)}</span></td>
        <td>${peer.query_port != null ? escHtml(peer.query_port) : '&mdash;'}</td>
        <td>${peer.banned ? '<span class="badge-banned">banned</span>' : ''}</td>
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
        tbody.innerHTML = '<tr><td colspan="7" class="empty">No peers.</td></tr>';
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
    const token = getToken();
    if (!token) { setStatus('enter a token first', 'err'); return; }
    try {
        await apiPost(path, token, body);
        setStatus('ok', 'ok');
        await loadPeers();
    } catch (err) {
        setStatus(err.message, 'err');
    }
}

async function loadPeers() {
    const token = getToken();
    if (!token) { setStatus('enter a token first', 'err'); return; }
    sessionStorage.setItem(TOKEN_KEY, token);
    setStatus('loading…');
    try {
        const r = await fetch('/admin/peers', { headers: { 'Authorization': 'Bearer ' + token } });
        if (r.status === 401) { setStatus('unauthorized', 'err'); renderPeers([]); return; }
        if (!r.ok) throw new Error('HTTP ' + r.status);
        const peers = await r.json();
        renderPeers(peers);
        setStatus(peers.length + ' peer' + (peers.length !== 1 ? 's' : ''), 'ok');
    } catch (err) {
        setStatus(err.message, 'err');
    }
}

function init() {
    const tokenInput = document.getElementById('token');
    const loadBtn    = document.getElementById('load-btn');
    try {
        const saved = sessionStorage.getItem(TOKEN_KEY);
        if (saved && tokenInput) tokenInput.value = saved;
    } catch (_e) { /* sessionStorage unavailable — ignore */ }

    if (loadBtn) loadBtn.addEventListener('click', loadPeers);
    if (tokenInput) tokenInput.addEventListener('keydown', (e) => {
        if (e.key === 'Enter') loadPeers();
    });
}

document.addEventListener('DOMContentLoaded', init);
