/**
 * stt.js — on-device speech-to-text (Whisper via transformers.js).
 *
 * Runs a multilingual Whisper model entirely in the browser (WebGPU, with a
 * single-threaded WASM fallback — no COOP/COEP needed). Audio never leaves the
 * device. Exposed as window.EmquestSTT (loaded as a module).
 *
 *   EmquestSTT.supported()  -> Promise<bool>
 *   EmquestSTT.enabled()    -> bool   (shares the on-device-AI preference)
 *   EmquestSTT.preload({onProgress}) -> Promise   (warm the model)
 *   EmquestSTT.transcribe(pcm16k, {language, onProgress}) -> Promise<string>
 */
import { pipeline, env } from '/static/vendor/transformers.js';

const MODEL    = 'onnx-community/whisper-small';   /* multilingual */
const PREF_KEY = 'emquest.slm.enabled';            /* shared on-device-AI toggle */

/* Self-host the ONNX runtime wasm (CSP: no external hosts); fetch weights from
 * the HF hub (CSP connect-src allows huggingface.co + *.hf.co). */
env.allowLocalModels = false;
env.allowRemoteModels = true;
env.backends.onnx.wasm.wasmPaths = '/static/vendor/ort/';
env.backends.onnx.wasm.numThreads = 1;             /* no SharedArrayBuffer / COEP */

/* Datalist language name → Whisper code (keep in sync with test helper). */
const LANG_CODES = {
    'Français': 'fr', 'Español': 'es', 'Deutsch': 'de', 'Italiano': 'it',
    'Português': 'pt', 'Nederlands': 'nl', 'Polski': 'pl', 'Türkçe': 'tr',
    'Русский': 'ru', 'العربية': 'ar', '中文': 'zh', '日本語': 'ja',
    '한국어': 'ko', 'हिन्दी': 'hi',
};
function langToWhisper(name) { return (!name || name === 'en') ? undefined : LANG_CODES[name]; }

let _support = null, _pipe = null;

async function supported() {
    if (_support !== null) return _support;
    _support = (async () => {
        try { return typeof WebAssembly === 'object'; } catch (_) { return false; }
    })();
    return _support;
}

function enabled() { try { return localStorage.getItem(PREF_KEY) !== '0'; } catch (_) { return true; } }

async function hasWebGPU() {
    try { return !!(navigator.gpu && await navigator.gpu.requestAdapter()); } catch (_) { return false; }
}

async function ensurePipe(onProgress) {
    if (_pipe) return _pipe;
    _pipe = (async () => {
        const device = (await hasWebGPU()) ? 'webgpu' : 'wasm';
        return pipeline('automatic-speech-recognition', MODEL, {
            device,
            dtype: device === 'webgpu' ? 'fp16' : 'q8',
            progress_callback: (p) => {
                if (onProgress && p && typeof p.progress === 'number') onProgress(p.progress / 100, p.status || '');
            },
        });
    })();
    return _pipe;
}

async function preload(handlers) {
    handlers = handlers || {};
    try {
        if (!enabled()) return;
        if (!(await supported())) return;
        await ensurePipe(handlers.onProgress);
    } catch (_) { /* best-effort */ }
}

async function transcribe(pcm16k, handlers) {
    handlers = handlers || {};
    if (!(await supported())) throw new Error('stt unsupported');
    const pipe = await ensurePipe(handlers.onProgress);
    const opts = { chunk_length_s: 30, stride_length_s: 5 };
    const lang = langToWhisper(handlers.language);
    if (lang) { opts.language = lang; opts.task = 'transcribe'; }
    const out = await pipe(pcm16k, opts);
    const text = (out && (Array.isArray(out) ? out[0] && out[0].text : out.text)) || '';
    return String(text).trim();
}

window.EmquestSTT = { supported, enabled, preload, transcribe, langToWhisper, MODEL };

/* Preload the model at boot when enabled + supported (accepted first-load cost
 * alongside the SLM). */
if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', () => { preload(); });
else preload();
