import { test } from 'node:test';
import assert from 'node:assert/strict';
import { langToWhisper, resampleTo16k } from './helpers/stt_core.mjs';

test('maps datalist language names to Whisper codes', () => {
  assert.equal(langToWhisper('Français'), 'fr');
  assert.equal(langToWhisper('Español'), 'es');
  assert.equal(langToWhisper('Deutsch'), 'de');
  assert.equal(langToWhisper('Italiano'), 'it');
  assert.equal(langToWhisper('Português'), 'pt');
});

test('unknown / English → undefined (auto-detect)', () => {
  assert.equal(langToWhisper('en'), undefined);
  assert.equal(langToWhisper('Klingon'), undefined);
  assert.equal(langToWhisper(''), undefined);
  assert.equal(langToWhisper(null), undefined);
});

test('resampleTo16k keeps same data when already 16k', () => {
  const x = Float32Array.from([0, 0.5, -0.5, 1, -1]);
  const out = resampleTo16k(x, 16000);
  assert.equal(out.length, x.length);
  assert.equal(out[0], 0); assert.equal(out[3], 1);
});

test('resampleTo16k halves length from 32k and stays in range', () => {
  const n = 3200; const x = new Float32Array(n).map((_, i) => Math.sin(i / 5));
  const out = resampleTo16k(x, 32000);
  assert.ok(Math.abs(out.length - 1600) <= 1);
  for (const v of out) assert.ok(v >= -1.001 && v <= 1.001);
});
