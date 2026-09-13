/* Parse a translation reply into a same-length array aligned to `src`. */
export function parseTranslation(raw, src) {
  const lines = String(raw == null ? '' : raw).split(/\r?\n/);
  const cleaned = lines.map(l => l.replace(/^\s*\d+[.)]\s*/, '').trim());
  const out = [];
  for (let i = 0; i < src.length; i++) {
    const v = cleaned[i];
    out.push(v && v.length ? v : src[i]);
  }
  return out;
}
