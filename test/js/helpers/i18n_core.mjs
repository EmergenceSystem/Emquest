/* Deterministic djb2 hash of the sorted, joined source set. */
export function catalogVersion(sources) {
  const s = [...new Set(sources)].sort().join(' ');
  let h = 5381;
  for (let i = 0; i < s.length; i++) h = ((h << 5) + h + s.charCodeAt(i)) >>> 0;
  return 'v' + h.toString(36);
}

/* Build source->text map: every source present, translation wins, else source. */
export function mergeMap(sources, translations) {
  const out = {};
  for (const s of sources) out[s] = (translations && translations[s]) || s;
  return out;
}

/* A cache object {ver,map} is usable only when its version matches. */
export function cacheValid(cache, ver) {
  return !!(cache && cache.ver === ver && cache.map);
}

/* An element's original source text: prefer a stashed data-i18n-src (set on
 * first apply) so re-translation always starts from English, else current. */
function srcText(el) {
  const stashed = el.getAttribute('data-i18n-src');
  return stashed != null ? stashed : (el.textContent || '').trim();
}
function attrList(el) {
  const spec = el.getAttribute('data-i18n-attr') || '';
  return spec.split(',').map(s => s.trim()).filter(Boolean);
}

/* An attribute's original source value: prefer a stashed data-i18n-<attr>-src
 * (set on first apply) so re-translation always starts from English, else current. */
function attrSrc(el, a) {
  const stash = el.getAttribute('data-i18n-' + a + '-src');
  return stash != null ? stash : (el.getAttribute(a) || '').trim();
}

/* Collect every translatable source string from the given elements. */
export function collectDom(nodes) {
  const set = new Set();
  for (const el of nodes) {
    if (el.getAttribute('data-i18n') !== null) { const s = srcText(el); if (s) set.add(s); }
    for (const a of attrList(el)) { const v = attrSrc(el, a); if (v) set.add(v); }
  }
  return [...set];
}

/* Apply a source->text map to the given elements (text + named attrs). */
export function applyDom(nodes, map) {
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

/* Restore text and attributes back to their stashed English source. */
export function resetDom(nodes) {
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
