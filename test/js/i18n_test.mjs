import { test } from 'node:test';
import assert from 'node:assert/strict';
import { catalogVersion, mergeMap, cacheValid, collectDom, applyDom, resetDom } from './helpers/i18n_core.mjs';

test('catalogVersion is stable regardless of order', () => {
  assert.equal(catalogVersion(['a', 'b', 'c']), catalogVersion(['c', 'a', 'b']));
});

test('catalogVersion changes when a string is added', () => {
  assert.notEqual(catalogVersion(['a', 'b']), catalogVersion(['a', 'b', 'c']));
});

test('mergeMap fills every source, translation wins, source fallback', () => {
  const src = ['Hello', 'Save', 'Close'];
  const xl  = { Hello: 'Bonjour', Save: 'Enregistrer' };
  assert.deepEqual(mergeMap(src, xl), { Hello: 'Bonjour', Save: 'Enregistrer', Close: 'Close' });
});

test('cacheValid requires matching version', () => {
  assert.equal(cacheValid({ ver: 'v1', map: {} }, 'v1'), true);
  assert.equal(cacheValid({ ver: 'v1', map: {} }, 'v2'), false);
  assert.equal(cacheValid(null, 'v1'), false);
});

function fakeEl(attrs, text) {
  const store = { ...attrs };
  return {
    textContent: text,
    getAttribute: (k) => (k in store ? store[k] : null),
    setAttribute: (k, v) => { store[k] = v; },
    _store: store,
  };
}

test('collectDom gathers text and named attrs as sources', () => {
  const nodes = [
    fakeEl({ 'data-i18n': '' }, 'Save'),
    fakeEl({ 'data-i18n-attr': 'placeholder', placeholder: 'Search…' }, ''),
  ];
  assert.deepEqual(collectDom(nodes).sort(), ['Save', 'Search…'].sort());
});

test('applyDom sets text and named attrs from the map', () => {
  const a = fakeEl({ 'data-i18n': '' }, 'Save');
  const b = fakeEl({ 'data-i18n-attr': 'placeholder', placeholder: 'Search…' }, '');
  applyDom([a, b], { Save: 'Enregistrer', 'Search…': 'Rechercher…' });
  assert.equal(a.textContent, 'Enregistrer');
  assert.equal(b._store.placeholder, 'Rechercher…');
});

test('attr source is stashed: re-collect returns source, reset restores it', () => {
  const el = fakeEl({ 'data-i18n-attr': 'placeholder', placeholder: 'Search…' }, '');
  applyDom([el], { 'Search…': 'Rechercher…' });
  assert.equal(el._store.placeholder, 'Rechercher…');
  assert.deepEqual(collectDom([el]), ['Search…']);      // still the English source
  resetDom([el]);
  assert.equal(el._store.placeholder, 'Search…');        // restored
});
