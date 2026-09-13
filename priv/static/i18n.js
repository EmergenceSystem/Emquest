/**
 * i18n.js — client-side UI localisation for the Emergence search app.
 *
 * The on-device SLM (slm.js) translates the whole UI into any language the user
 * types; translations are cached per language in localStorage (one-time cost).
 * Static markup opts in with data-i18n / data-i18n-attr; JS-built strings go
 * through t(). Exposed as window.EmquestI18n.
 */
(function () {
    const LANG_KEY  = 'emquest.lang';
    const cacheKey  = (lang) => 'emquest.i18n.' + lang;

    /* ---- pure core (keep in sync with test/js/helpers/i18n_core.mjs) ---- */
    function catalogVersion(sources) {
        const s = [...new Set(sources)].sort().join(' ');
        let h = 5381;
        for (let i = 0; i < s.length; i++) h = ((h << 5) + h + s.charCodeAt(i)) >>> 0;
        return 'v' + h.toString(36);
    }
    function mergeMap(sources, translations) {
        const out = {};
        for (const s of sources) out[s] = (translations && translations[s]) || s;
        return out;
    }
    function cacheValid(cache, ver) { return !!(cache && cache.ver === ver && cache.map); }
    function srcText(el) {
        const stashed = el.getAttribute('data-i18n-src');
        return stashed != null ? stashed : (el.textContent || '').trim();
    }
    function attrList(el) {
        return (el.getAttribute('data-i18n-attr') || '').split(',').map(s => s.trim()).filter(Boolean);
    }
    function attrSrc(el, a) {
        const stash = el.getAttribute('data-i18n-' + a + '-src');
        return stash != null ? stash : (el.getAttribute(a) || '').trim();
    }
    function domNodes() { return [...document.querySelectorAll('[data-i18n],[data-i18n-attr]')]; }
    function collectDom(nodes) {
        const set = new Set();
        for (const el of nodes) {
            if (el.getAttribute('data-i18n') !== null) { const s = srcText(el); if (s) set.add(s); }
            for (const a of attrList(el)) { const v = attrSrc(el, a); if (v) set.add(v); }
        }
        return [...set];
    }
    function applyDom(nodes, map) {
        for (const el of nodes) {
            if (el.getAttribute('data-i18n') !== null) {
                const src = srcText(el);
                if (el.getAttribute('data-i18n-src') == null) el.setAttribute('data-i18n-src', src);
                if (map[src] != null) el.textContent = map[src];
            }
            for (const a of attrList(el)) {
                const cur = el.getAttribute(a); if (cur == null) continue;
                if (el.getAttribute('data-i18n-' + a + '-src') == null) el.setAttribute('data-i18n-' + a + '-src', cur.trim());
                const src = attrSrc(el, a);
                if (map[src] != null) el.setAttribute(a, map[src]);
            }
        }
    }
    function resetDom(nodes) {
        for (const el of nodes) {
            if (el.getAttribute('data-i18n') !== null) {
                const s = el.getAttribute('data-i18n-src');
                if (s != null) el.textContent = s;
            }
            for (const a of attrList(el)) {
                const s = el.getAttribute('data-i18n-' + a + '-src');
                if (s != null) el.setAttribute(a, s);
            }
        }
    }

    /* ---- JS-string registry: strings passed to t() before any DOM scan ---- */
    const JS_STRINGS = [
        'llm offline', 'local ai', 'local · loading model…', 'local · loading model',
        'local · summarising…', 'used of', 'No results found for this query.',
        'No searches yet.',
        'Delete ALL saved searches from this device? This cannot be undone.',
        'Requires on-device AI (WebGPU)', 'Enable on-device AI above to translate',
        'Listed languages work offline; others need on-device AI (WebGPU)',
        'Apply', 'Language',
        'result', 'results', 'aggregated', 'top domain',
        'DNS record', 'DNS records', 'media item', 'media items',
    ];
    const _seen = new Set(JS_STRINGS);

    /* Bump when the curated dictionaries (i18n_dict.js) change, to invalidate
     * per-language caches that were built against the old translations. */
    const I18N_REV = '1';
    /* Normalise a source for dictionary lookup: HTML markup emits &nbsp;
     * (U+00A0) which reaches the DOM as a non-breaking space; dictionary keys
     * are written with plain spaces, so fold it before matching. */
    function norm(s) { return String(s == null ? '' : s).replace(/ /g, ' '); }
    function verOf(sources) { return catalogVersion(sources) + '.' + I18N_REV; }

    /* ---- state ---- */
    let _lang = 'en';
    try { _lang = localStorage.getItem(LANG_KEY) || 'en'; } catch (_) {}
    let _map = {};

    function current() { return _lang; }
    function t(source) {
        if (source == null) return source;
        if (!_seen.has(source)) _seen.add(source);
        if (_lang === 'en') return source;
        const v = _map[source];
        return v != null ? v : source;
    }
    function allSources() { return [...new Set([...collectDom(domNodes()), ..._seen])]; }
    function supported() {
        return (window.EmquestSLM && window.EmquestSLM.supported) ? window.EmquestSLM.supported() : Promise.resolve(false);
    }
    function readCache(lang) { try { return JSON.parse(localStorage.getItem(cacheKey(lang)) || 'null'); } catch (_) { return null; } }
    function writeCache(lang, obj) { try { localStorage.setItem(cacheKey(lang), JSON.stringify(obj)); } catch (_) {} }

    function apply() { if (_lang !== 'en') applyDom(domNodes(), _map); }

    async function setLanguage(lang, handlers) {
        handlers = handlers || {};
        lang = (lang || 'en').trim() || 'en';
        if (lang === 'en') {
            _lang = 'en'; _map = {};
            try { localStorage.setItem(LANG_KEY, 'en'); } catch (_) {}
            resetDom(domNodes());
            return;
        }
        const sources = allSources();
        const ver = verOf(sources);
        let cache = readCache(lang);
        if (!cacheValid(cache, ver)) {
            /* Curated human dictionary first (perfect, instant, no WebGPU); the
             * SLM only fills strings the dictionary does not cover. */
            const dict = (window.EmquestI18nDict && window.EmquestI18nDict[lang]) || {};
            const map = {};
            const missing = [];
            for (const s of sources) {
                const d = dict[norm(s)];
                if (d != null) map[s] = d; else missing.push(s);
            }
            if (missing.length) {
                let translations = [];
                try {
                    if (window.EmquestSLM && (await supported())
                        && window.EmquestSLM.enabled && window.EmquestSLM.enabled()) {
                        translations = await window.EmquestSLM.translate(missing, lang, handlers);
                    }
                } catch (_) { translations = []; }
                missing.forEach((s, i) => {
                    map[s] = (translations[i] != null && translations[i] !== '') ? translations[i] : s;
                });
            }
            cache = { ver, map: mergeMap(sources, map) };
            writeCache(lang, cache);
        }
        _lang = lang; _map = cache.map;
        try { localStorage.setItem(LANG_KEY, lang); } catch (_) {}
        apply();
    }

    function boot() {
        if (_lang === 'en') return;
        const ver = verOf(allSources());
        const cache = readCache(_lang);
        if (cacheValid(cache, ver)) { _map = cache.map; apply(); }
        else { _lang = 'en'; }
    }

    window.EmquestI18n = { current, t, setLanguage, apply, supported, boot,
                           _catalogVersion: catalogVersion };

    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot);
    else boot();
})();
