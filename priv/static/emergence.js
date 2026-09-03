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
(function(){
  const canvas=document.getElementById('bg-canvas'); if(!canvas) return;
  const x=canvas.getContext('2d'); let w,h,t=0;
  function rs(){w=canvas.width=canvas.offsetWidth;h=canvas.height=canvas.offsetHeight}
  rs(); addEventListener('resize',rs);
  const reduce=matchMedia('(prefers-reduced-motion:reduce)').matches;
  const N=[]; for(let i=0;i<90;i++){const ph=Math.acos(2*Math.random()-1),th=Math.random()*7;N.push([Math.sin(ph)*Math.cos(th),Math.sin(ph)*Math.sin(th),Math.cos(ph)])}
  /* drag-to-throw: grab the globe from any empty background area, fling it, and
     it keeps the speed+direction you gave it, decaying back to the gentle auto-spin. */
  const AUTO=.003; let vel=AUTO, drag=false, lastX=0;
  if(!reduce){
    document.addEventListener('pointerdown',e=>{
      if(e.target.closest('.item-card, input, textarea, button, a, .type-drawer, .search-box, .app-header')) return;
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
    setHighlightQuery(query);

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
            break;
        }

        /* ── Reorder + score cards after ranking ───────────────── */
        case 'reorder': {
            const list   = document.getElementById('results-list');
            const sids   = event.sids   || [];
            const scores = event.scores || {};
            /* Progressive passes send final:false; the last one (and legacy) finalize. */
            const isFinal = event.final !== false;

            /* Safety: empty sids = ranking failed, keep cards as-is */
            if (sids.length === 0) break;

            /* FLIP: record card positions before the DOM moves. */
            const first = new Map();
            streamCards.forEach((card) => {
                if (card.isConnected) first.set(card, card.getBoundingClientRect());
            });

            /* On the final reorder, hide deduped items (not in sids). */
            if (isFinal) {
                streamCards.forEach((card, sid) => {
                    if (!sids.includes(sid)) {
                        card.classList.add('card-removed');
                        setTimeout(() => card.remove(), 350);
                    }
                });
            }

            /* Reorder DOM + update score accent + re-number. */
            sids.forEach((sid, pos) => {
                const card = streamCards.get(sid);
                if (!card || !list) return;

                const score = scores[String(sid)] ?? 0;
                card.dataset.score = score;
                /* Only the cross-encoder's 0..3 integer scores drive the accent. */
                if (Number.isInteger(score)) {
                    card.className = card.className.replace(/\bscore-\d\b/g, '').trim();
                    card.classList.add(`score-${score}`);
                }

                const idx = card.querySelector('.item-index');
                if (idx) idx.textContent = String(pos + 1).padStart(2, '0');

                list.appendChild(card); /* move to end in ranked order */
            });

            /* FLIP: play each card from its old position to the new one (Web
               Animations API, so it never fights the cardIn CSS animation). */
            requestAnimationFrame(() => {
                const vh = window.innerHeight || 800;
                streamCards.forEach((card) => {
                    const prev = first.get(card);
                    if (!prev || !card.isConnected) return;
                    const now = card.getBoundingClientRect();
                    /* Only animate cards near the viewport — off-screen motion is
                       invisible and animating all ~200 at once is what felt janky. */
                    if (now.bottom < -vh * 0.3 || now.top > vh * 1.3) return;
                    const dx = prev.left - now.left, dy = prev.top - now.top;
                    if (Math.abs(dx) < 1 && Math.abs(dy) < 1) return;
                    const anim = card.animate(
                        [{ transform: `translate(${dx}px, ${dy}px)` },
                         { transform: 'translate(0, 0)' }],
                        { duration: 420, easing: 'cubic-bezier(0.22, 1, 0.36, 1)' }
                    );
                    /* Replace any in-flight FLIP so rapid reorders don't stack. */
                    if (card._flip) card._flip.cancel();
                    card._flip = anim;
                    anim.onfinish = () => { if (card._flip === anim) card._flip = null; };
                });
            });

            applyTypeFilter();

            /* Finalise the progress bar only on the final reorder. */
            if (isFinal) {
                finishProgress();
                setTimeout(applyTypeFilter, 400);
                const log = document.getElementById('progress-log');
                if (log) {
                    setTimeout(() => {
                        log.style.transition = 'opacity 1.2s ease';
                        log.style.opacity    = '0';
                        setTimeout(() => log.remove(), 1200);
                    }, 2000);
                }
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
    li.dataset.mtype = item.doc_type ? 'document' : (item.media_type || 'text');
    li.style.animationDelay = `${Math.min(pos * 50, 400)}ms`;

    li.innerHTML = buildCardBody(item, pos);

    /* Media thumbnails: attach load/error handlers programmatically (no
       inline on*= attributes, for CSP). The audio thumb just hides itself
       on error; the image/video thumb reuses mediaImgLoad/mediaImgError. */
    li.querySelectorAll('img.media-thumb').forEach(img => {
        if (img.classList.contains('media-thumb--audio')) {
            img.addEventListener('error', () => img.remove());
        } else {
            img.addEventListener('load', () => mediaImgLoad(img));
            img.addEventListener('error', () => mediaImgError(img));
        }
    });

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
            const kind = item.doc_type || docKind(url);
            if (kind) li.classList.add('item-card--doc');
            li.addEventListener('click', e => {
                if (e.target.closest('a')) return; /* let native link work */
                if (kind) openDocViewer(url);
                else window.open(url, '_blank', 'noopener');
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
                       class="item-title">${highlight(item.label)}</a>
                    <span class="item-url">${escHtml(item.url)}</span>
                    ${item.value ? `<p class="item-resume">${highlight(item.value)}</p>` : ''}
                </div>
                <span class="item-arrow">↗</span>
            `;
        } else {
            /* url as main element + resume */
            body = `
                <div class="item-web">
                    <a href="${escAttr(url)}" target="_blank" rel="noopener"
                       class="item-url item-url--hero">${escHtml(item.url)}</a>
                    ${item.value ? `<p class="item-resume">${highlight(item.value)}</p>` : ''}
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
                    <span class="item-domain">${highlight(item.label)}</span>
                    <span class="dns-badge">DNS</span>
                </div>
                <div class="ip-list">${badges}</div>
                ${item.value ? `<p class="item-resume">${highlight(item.value)}</p>` : ''}
            </div>
        `;
    } else {
        /* ── Generic ───────────────────────────────────────────── */
        const label = (item.label && item.label !== 'Result') ? item.label : null;
        body = `
            <div class="item-generic">
                ${label ? `<span class="item-title">${highlight(label)}</span>` : ''}
                ${item.value ? `<p class="item-resume">${highlight(item.value)}</p>` : ''}
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
    const title = (item.label && item.label !== 'Result') ? highlight(item.label) : '';
    const foot  = mediaFooter(item);
    const thumb = item.thumbnail ? safeUrl(item.thumbnail) : '';

    if (t === 'audio') {
        const src = safeUrl(item.media_url) || '';
        return `
            <div class="media-card media-audio">
                <div class="media-audio-head">
                    ${thumb ? `<img class="media-thumb media-thumb--audio" loading="lazy"
                         referrerpolicy="no-referrer" src="${escAttr(thumb)}" alt="">` : ''}
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

    /* image or video */
    const durBadge = (t === 'video' && item.duration)
        ? `<span class="media-duration">${escHtml(fmtDur(item.duration))}</span>` : '';
    const play     = (t === 'video') ? `<span class="media-play">▶</span>` : '';
    const thumbHtml = thumb
        ? `<img class="media-thumb" loading="lazy" referrerpolicy="no-referrer"
             src="${escAttr(thumb)}" alt="${escAttr(item.label || '')}">`
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

function mediaImgError(img) {
  if (img.closest('.media-image')) {
    const card = img.closest('.item-card, .drift-card');
    if (card) {
      // Drop the stream reference too, else a later reorder re-appends the broken card.
      const sid = card.dataset.sid;
      if (sid !== undefined) streamCards.delete(Number(sid));
      card.remove();
      return;
    }
  }
  img.classList.add('media-thumb--broken');
}
function mediaImgLoad(img) {
  // A 200 with no real pixels (e.g. a Cloudflare block page decoded as an image) = no thumbnail.
  if (!img.naturalWidth || img.naturalWidth < 2 || img.naturalHeight < 2) mediaImgError(img);
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
function startProgress() {
  /* the CSS bar animates on its own; reset the visible-result count */
  applyTypeFilter();
}
function finishProgress() {
  const fill = document.getElementById('pbar-fill');
  if (fill) {
    fill.style.animation = 'none';
    fill.style.transition = 'width 0.35s ease';
    fill.style.width = '100%';
  }
}

/* Persist the media-type filter choices in IndexedDB (db emergence/prefs). */
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
    await new Promise(res => {
      const req = db.transaction(_MT_STORE, 'readwrite').objectStore(_MT_STORE).put(map, _MT_KEY);
      req.onsuccess = () => res(); req.onerror = () => res();
    });
  } catch (_) {}
}
async function restoreMediaTypes() {
  try {
    const db = await _mtDbOpen();
    const vals = await new Promise(res => {
      const req = db.transaction(_MT_STORE, 'readonly').objectStore(_MT_STORE).get(_MT_KEY);
      req.onsuccess = () => res(req.result); req.onerror = () => res(undefined);
    });
    if (vals == null) return;
    const tf = document.getElementById('type-filters');
    if (!tf) return;
    const legacy = ['text', 'image', 'audio', 'video'];
    if (Array.isArray(vals)) {
      /* old format: a list of checked values; checkboxes added later
         (e.g. document) weren't options then, so default them checked. */
      tf.querySelectorAll('input').forEach(c => {
        c.checked = vals.includes(c.value) || !legacy.includes(c.value);
      });
    } else {
      /* new format: {value: checked}; a missing key defaults checked. */
      tf.querySelectorAll('input').forEach(c => { c.checked = vals[c.value] !== false; });
    }
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
  const tf   = document.getElementById('type-filters');
  const list = document.getElementById('results-list');
  if (!tf || !list) return;
  const checked = [...tf.querySelectorAll('input:checked')].map(c => c.value);
  const showAll = checked.length === 0;
  let visible = 0;
  list.querySelectorAll('li.item-card').forEach(li => {
    const t = li.dataset.mtype || 'text';
    const hidden = !showAll && !checked.includes(t);
    li.classList.toggle('type-hidden', hidden);
    if (!hidden) visible++;
  });
  const c = document.getElementById('tf-count');
  if (c) c.textContent = visible + (visible === 1 ? ' result' : ' results');
}

// Admin-only nav links (network, admin) are NOT in the public HTML. When an
// admin token exists in IndexedDB, fetch the gated /admin/nav fragment (server
// returns it only to an authenticated admin) and inject it into the header.
// So the admin surface is never advertised in the static page source. (The
// real protection is still the token gate on every /admin/* and /network/peers
// endpoint — this just avoids exposing the links to the public.)
(function(){
  const nav=document.querySelector('.sys-status'), clock=document.getElementById('clock');
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
// media-type drawer open/close
(function(){
  const pill=document.getElementById('type-pill'),dr=document.getElementById('type-drawer'),sc=document.getElementById('drawer-scrim');
  if(!pill||!dr||!sc) return;
  const open=()=>{dr.classList.add('open');sc.classList.add('open')};
  const close=()=>{dr.classList.remove('open');sc.classList.remove('open')};
  pill.addEventListener('click',open); sc.addEventListener('click',close);
  addEventListener('keydown',e=>{if(e.key==='Escape')close()});
})();
// result-card 3D tilt (delegated; skip touch/reduced-motion)
(function(){
  if(matchMedia('(prefers-reduced-motion:reduce)').matches||matchMedia('(pointer:coarse)').matches) return;
  const list=document.getElementById('results'); if(!list) return;
  list.addEventListener('mousemove',e=>{const c=e.target.closest('.item-card'); if(!c)return;
    const r=c.getBoundingClientRect(),px=(e.clientX-r.left)/r.width-.5,py=(e.clientY-r.top)/r.height-.5;
    c.style.transform=`rotateY(${px*1.6}deg) rotateX(${-py*1.6}deg)`});
  list.addEventListener('mouseout',e=>{const c=e.target.closest('.item-card'); if(c)c.style.transform=''});
})();

function ensureLightbox() {
    if (!_lightbox) {
        _lightbox = document.createElement('div');
        _lightbox.id = 'media-lightbox';
        _lightbox.className = 'lightbox';
        _lightbox.innerHTML =
            '<div class="lightbox-inner">' +
            '<button class="lightbox-close" aria-label="Close">\u2715</button>' +
            '<div class="lightbox-body"></div></div>';
        _lightbox.addEventListener('click', e => {
            if (e.target === _lightbox || e.target.closest('.lightbox-close')) closeLightbox();
        });
        document.addEventListener('keydown', e => {
            if (e.key === 'Escape' && _lightbox) closeLightbox();
        });
        document.body.appendChild(_lightbox);
    }
    return _lightbox.querySelector('.lightbox-body');
}

function closeLightbox() {
    if (!_lightbox) return;
    _lightbox.classList.remove('open');
    const b = _lightbox.querySelector('.lightbox-body');
    if (b) b.innerHTML = '';   /* stop iframes / free memory */
}

function openLightbox(src) {
    const body = ensureLightbox();
    body.innerHTML = '<img class="lightbox-img" referrerpolicy="no-referrer" alt="">' +
                     '<div class="doc-bar"><a class="doc-open" href="' + escAttr(src) +
                     '" target="_blank" rel="noopener">Open original ↗</a></div>';
    body.querySelector('img').src = src;
    _lightbox.classList.add('open');
}

/* Detect a viewable document kind from a URL's extension. */
function docKind(url) {
    const u = (url || '').split('?')[0].split('#')[0].toLowerCase();
    if (u.endsWith('.pdf')) return 'pdf';
    if (u.endsWith('.docx')) return 'docx';
    if (u.endsWith('.xlsx') || u.endsWith('.xls')) return 'xlsx';
    if (u.endsWith('.csv')) return 'csv';
    if (u.includes('/pdf/')) return 'pdf';   /* extensionless PDFs (arxiv) */
    return null;
}

const _scripts = {};
function loadScript(src) {
    return _scripts[src] || (_scripts[src] = new Promise((res, rej) => {
        const s = document.createElement('script');
        s.src = src; s.onload = res; s.onerror = rej;
        document.head.appendChild(s);
    }));
}

/* In-app document viewer: PDF via the browser's native iframe viewer,
   Word/Excel/CSV parsed client-side (mammoth / SheetJS). Falls back to
   an "open original" link when the format is unsupported or the source
   blocks cross-origin fetch (CORS). */
async function openDocViewer(url) {
    const kind = docKind(url);
    const body = ensureLightbox();
    _lightbox.classList.add('open');
    const orig = '<a class="doc-open" href="' + escAttr(url) +
                 '" target="_blank" rel="noopener">Open original \u2197</a>';

    if (kind === 'pdf') {
        body.innerHTML = '<iframe class="doc-frame" src="' + escAttr(url) +
                         '"></iframe><div class="doc-bar">' + orig + '</div>';
        return;
    }

    body.innerHTML = '<div class="doc-loading">Loading preview\u2026</div>';
    try {
        const resp = await fetch(url);
        if (!resp.ok) throw new Error('http');
        const ab = await resp.arrayBuffer();
        if (kind === 'docx') {
            await loadScript('/static/vendor/mammoth.browser.min.js');
            const r = await window.mammoth.convertToHtml({ arrayBuffer: ab });
            body.innerHTML = '<div class="doc-html">' + r.value +
                             '</div><div class="doc-bar">' + orig + '</div>';
        } else if (kind === 'xlsx' || kind === 'csv') {
            await loadScript('/static/vendor/xlsx.full.min.js');
            const wb = window.XLSX.read(ab, { type: 'array' });
            const first = wb.Sheets[wb.SheetNames[0]];
            const table = window.XLSX.utils.sheet_to_html(first);
            body.innerHTML = '<div class="doc-html doc-sheet">' + table +
                             '</div><div class="doc-bar">' + orig + '</div>';
        } else {
            throw new Error('unsupported');
        }
    } catch (e) {
        body.innerHTML = '<div class="doc-fallback"><p>Can\'t preview this file here ' +
            '(unsupported format, or the source blocks cross-origin access).</p>' +
            orig + '</div>';
    }
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

/* ── Query-term highlighting ──────────────────────────────────────── */
/* Length-preserving fold (1 folded char per input char) so <mark>
   offsets computed on the folded text align with the escaped text. */
function _fold(s) {
    return [...String(s == null ? '' : s)]
        .map(c => (c.normalize('NFD')[0] || c).toLowerCase()).join('');
}
let _hlWords = [];
function setHighlightQuery(q) {
    _hlWords = _fold(q).split(/\s+/).filter(w => w.length >= 2);
}
function highlight(text) {
    if (text == null || text === '' || _hlWords.length === 0) return escHtml(text || '');
    const esc    = escHtml(text);
    const folded = _fold(esc);          /* same length as esc (1:1) */
    const marks  = [];
    for (const w of _hlWords) {
        let i = 0;
        while ((i = folded.indexOf(w, i)) !== -1) { marks.push([i, i + w.length]); i += w.length; }
    }
    if (marks.length === 0) return esc;
    marks.sort((a, b) => a[0] - b[0]);
    let out = '', cur = 0;
    for (const [a, b] of marks) {
        if (a < cur) continue;
        out += esc.slice(cur, a) + '<mark>' + esc.slice(a, b) + '</mark>';
        cur = b;
    }
    return out + esc.slice(cur);
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

/* restore saved media-type filter on page load */
restoreMediaTypes();
