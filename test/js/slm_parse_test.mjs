import { test } from 'node:test';
import assert from 'node:assert/strict';
import { parseTranslation } from './helpers/slm_parse.mjs';

test('keeps order and count', () => {
  const src = ['Hello', 'Search', 'Save'];
  const raw = 'Bonjour\nRecherche\nEnregistrer';
  assert.deepEqual(parseTranslation(raw, src), ['Bonjour', 'Recherche', 'Enregistrer']);
});

test('per-line fallback to source on blank/missing', () => {
  const src = ['Hello', 'Search', 'Save'];
  const raw = 'Bonjour\n\n';
  assert.deepEqual(parseTranslation(raw, src), ['Bonjour', 'Search', 'Save']);
});

test('strips leading numbering the model may add', () => {
  const src = ['Hello', 'Search'];
  const raw = '1. Bonjour\n2) Recherche';
  assert.deepEqual(parseTranslation(raw, src), ['Bonjour', 'Recherche']);
});

test('extra lines are ignored', () => {
  const src = ['Hello'];
  const raw = 'Bonjour\nHere is your translation';
  assert.deepEqual(parseTranslation(raw, src), ['Bonjour']);
});
