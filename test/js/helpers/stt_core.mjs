/* Datalist language name → Whisper ISO code. Unknown / English → undefined
 * (Whisper auto-detects). Keep in sync with the copy inlined in stt.js. */
const LANG_CODES = {
  'Français': 'fr', 'Español': 'es', 'Deutsch': 'de', 'Italiano': 'it',
  'Português': 'pt', 'Nederlands': 'nl', 'Polski': 'pl', 'Türkçe': 'tr',
  'Русский': 'ru', 'العربية': 'ar', '中文': 'zh', '日本語': 'ja',
  '한국어': 'ko', 'हिन्दी': 'hi',
};
export function langToWhisper(name) {
  if (!name || name === 'en') return undefined;
  return LANG_CODES[name];
}

/* Linear resample a mono Float32 buffer to 16 kHz. Returns the input as-is
 * when already at 16 kHz. Simple linear interpolation is adequate for speech
 * fed to Whisper. */
export function resampleTo16k(input, sampleRate) {
  if (sampleRate === 16000) return input;
  const ratio = 16000 / sampleRate;
  const outLen = Math.round(input.length * ratio);
  const out = new Float32Array(outLen);
  for (let i = 0; i < outLen; i++) {
    const srcPos = i / ratio;
    const i0 = Math.floor(srcPos);
    const i1 = Math.min(i0 + 1, input.length - 1);
    const frac = srcPos - i0;
    out[i] = input[i0] * (1 - frac) + input[i1] * frac;
  }
  return out;
}
