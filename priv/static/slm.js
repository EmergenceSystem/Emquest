/**
 * slm.js — on-device result summariser (WebGPU + WebLLM).
 *
 * Runs a small instruct model entirely in the browser: the query and the
 * retrieved snippets never leave the device. WebGPU only — callers must
 * check supported() and fall back to the deterministic summary otherwise.
 *
 * Exposed as window.EmquestSLM (loaded as a module, so emergence.js — a
 * classic script — can call it without importing anything).
 *
 *   EmquestSLM.supported()  -> Promise<bool>   WebGPU + adapter present
 *   EmquestSLM.enabled()    -> bool            user opted in (persisted)
 *   EmquestSLM.setEnabled(v)
 *   EmquestSLM.summarize(query, items, { onProgress, onToken }) -> Promise<string>
 */

const MODEL   = 'Qwen2.5-0.5B-Instruct-q4f16_1-MLC';  /* ~350 MB, cached after first load */
const PREF_KEY = 'emquest.slm.enabled';
const MAX_ITEMS = 6;      /* snippets fed to the model */
const MAX_TOKENS = 200;   /* answer length cap        */

let _webllm = null;   /* the imported library                 */
let _engine = null;   /* Promise<engine> once init started    */
let _support = null;  /* memoised WebGPU support probe        */

/* ── Capability probe ─────────────────────────────────────────────── */
async function supported() {
    if (_support !== null) return _support;
    _support = (async () => {
        try {
            if (!('gpu' in navigator) || !navigator.gpu) return false;
            const adapter = await navigator.gpu.requestAdapter();
            return !!adapter;             /* null = blocklisted GPU/driver */
        } catch (_) { return false; }
    })();
    return _support;
}

/* ── Preference (localStorage; on by default, '0' = user turned it off) */
function enabled() { try { return localStorage.getItem(PREF_KEY) !== '0'; } catch (_) { return true; } }
function setEnabled(v) { try { localStorage.setItem(PREF_KEY, v ? '1' : '0'); } catch (_) {} }

/* Text-bearing results are the only ones worth summarising. */
function isTextItem(it) {
    const m = it && it.media_type;
    return !m || m === 'text' || m === 'document' || !!(it && it.doc_type);
}

/* ── Engine (lazy, one-time; streams download progress) ───────────── */
async function ensureEngine(onProgress) {
    if (_engine) return _engine;
    _engine = (async () => {
        if (!_webllm) _webllm = await import('/static/vendor/web-llm.js');
        return _webllm.CreateMLCEngine(MODEL, {
            initProgressCallback: (r) => {
                /* r.progress in [0,1]; r.text is a human phase string */
                if (onProgress) onProgress(r && typeof r.progress === 'number' ? r.progress : 0, r && r.text || '');
            },
        });
    })();
    return _engine;
}

/* Warm the engine early (called on DOMContentLoaded). No-op when disabled/
 * unsupported/already started. Never throws. */
async function preload(handlers) {
    handlers = handlers || {};
    try {
        if (!enabled()) return;
        if (!(await supported())) return;
        await ensureEngine(handlers.onProgress);
    } catch (_) { /* swallow: preload is best-effort */ }
}

/* ── Prompt building ──────────────────────────────────────────────── */
function clip(s, n) { s = String(s == null ? '' : s); return s.length > n ? s.slice(0, n - 1) + '…' : s; }

function buildMessages(query, items, lang) {
    const lines = items.slice(0, MAX_ITEMS).map((it, i) => {
        const title = clip(it.label || it.title || '(untitled)', 120);
        const body  = clip(it.value || it.resume || it.snippet || '', 240);
        const host  = (() => { try { return it.url ? new URL(it.url).hostname : ''; } catch (_) { return ''; } })();
        return `[${i + 1}] ${title}${host ? ' — ' + host : ''}${body ? '\n    ' + body : ''}`;
    });
    let system =
        'You summarise web-search results. Using ONLY the numbered results, '
        + 'write 2 to 3 short sentences that answer the query. Cite sources inline '
        + 'as [n]. Do not invent facts. If the results do not answer the query, say '
        + 'the results are insufficient.';
    if (lang && lang !== 'en') system += ` Write the answer in ${lang}.`;
    const user = `Query: ${query}\n\nResults:\n${lines.join('\n')}`;
    return [{ role: 'system', content: system }, { role: 'user', content: user }];
}

/* ── Summarise (streams tokens via onToken; resolves full text) ───── */
async function summarize(query, items, handlers) {
    handlers = handlers || {};
    if (!enabled()) throw new Error('slm disabled');
    if (!(await supported())) throw new Error('webgpu unsupported');
    if (!items || !items.length) throw new Error('no items');

    /* Text results first; fall back to whatever exists if none are text. */
    const textItems = items.filter(isTextItem);
    const feed = textItems.length ? textItems : items;

    const engine = await ensureEngine(handlers.onProgress);
    const lang = (window.EmquestI18n && window.EmquestI18n.current && window.EmquestI18n.current()) || 'en';
    const stream = await engine.chat.completions.create({
        messages: buildMessages(query, feed, lang),
        stream: true, temperature: 0.2, max_tokens: MAX_TOKENS,
    });

    let out = '';
    for await (const chunk of stream) {
        if (handlers.signal && handlers.signal.aborted) break;
        const d = chunk.choices && chunk.choices[0] && chunk.choices[0].delta
            ? (chunk.choices[0].delta.content || '') : '';
        if (d) { out += d; if (handlers.onToken) handlers.onToken(d); }
    }
    return out.trim();
}

/* Translate an array of UI strings into `lang`, preserving order/count and
 * placeholders. Returns a same-length array (source fallback per line). */
async function translate(texts, lang, handlers) {
    handlers = handlers || {};
    if (!enabled()) throw new Error('slm disabled');
    if (!(await supported())) throw new Error('webgpu unsupported');
    if (!Array.isArray(texts) || !texts.length) return [];

    const engine = await ensureEngine(handlers.onProgress);
    const system =
        `Translate the UI text into ${lang}. Reply with ONLY the translation — no `
        + 'quotes, no notes, no repetition, no explanation. Preserve placeholders '
        + '({x}, %s, [1]), HTML entities (&nbsp;), URLs and numbers exactly. Keep it '
        + 'short and idiomatic for a UI.';

    /* One request per string: a shared batch lets a single runaway generation
     * (the 0.5B model can loop on a long input) starve the whole set, so we
     * bound each string's tokens by its own length and reject runaway/garbage
     * output (falling back to the source for that line only). */
    const out = [];
    for (let i = 0; i < texts.length; i++) {
        if (handlers.signal && handlers.signal.aborted) break;
        const src = String(texts[i] == null ? '' : texts[i]);
        let translated = src;
        if (src.trim()) {
            const cap = Math.min(400, Math.max(24, Math.ceil(src.length / 2) + 24));
            try {
                const resp = await engine.chat.completions.create({
                    messages: [{ role: 'system', content: system },
                               { role: 'user', content: src.replace(/\n/g, ' ') }],
                    stream: false, temperature: 0.1, max_tokens: cap,
                });
                const raw = (resp && resp.choices && resp.choices[0] && resp.choices[0].message
                    ? (resp.choices[0].message.content || '') : '').trim();
                /* reject empty or runaway output (loop/hallucination) */
                if (raw && raw.length <= src.length * 6 + 40) translated = raw;
            } catch (_) { /* keep source for this line */ }
        }
        out.push(translated);
        if (handlers.onProgress) handlers.onProgress((i + 1) / texts.length, 'translating');
    }
    return out;
}

window.EmquestSLM = { supported, enabled, setEnabled, summarize, translate, preload, isTextItem, MODEL };

/* Preload the model as early as possible so the first translate/summarise is
 * responsive. Runs only when the user has it enabled and WebGPU is present. */
if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', () => { preload(); });
} else { preload(); }
