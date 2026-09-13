// @ts-check
const { test, expect } = require('@playwright/test');

/**
 * On-device-translation UI end-to-end tests for EmergenceSystem.
 *
 * i18n.js drives the whole-UI translation flow: applying a language calls
 * window.EmquestSLM.translate() for every data-i18n string, caches the
 * resulting map in localStorage keyed by language, and re-applies it from
 * cache on boot() for subsequent page loads.
 *
 * These tests stub window.EmquestSLM via page.addInitScript so the SLM
 * itself (WebGPU availability, model download, real inference) is never
 * exercised — the stub's translate() just prefixes each source string with
 * "<lang>·", which is enough to prove the wiring end-to-end. The stub must
 * be installed with addInitScript (not a page.evaluate after load) so it
 * exists in the page's global scope before i18n.js's own boot() runs and
 * before emergence.js reads window.EmquestSLM.supported() to enable the
 * settings-modal language field.
 *
 * Prerequisites: emquest running on :8079 (baseURL, see playwright.config.js).
 * A live mesh (em_disco / em_filter_example) is not required — these tests
 * only touch the settings modal and static UI chrome.
 */

test.describe('on-device UI translation', () => {

  test.beforeEach(async ({ page }) => {
    await page.addInitScript(() => {
      window.EmquestSLM = {
        supported: async () => true,
        enabled: () => true,
        translate: async (arr, lang) => arr.map(s => lang + '·' + s),
        summarize: async () => '',
        setEnabled() {},
        preload: async () => {},
        isTextItem: () => true,
      };
    });
  });

  test('applies a chosen language to the UI', async ({ page }) => {
    await page.goto('/');

    await page.click('#settings-btn');
    await page.fill('#set-lang', 'TEST');
    await page.click('#set-lang-apply');

    const heading = page.locator('h1[data-i18n]');
    await expect(heading).toHaveText(/^TEST·/);
  });

  test('persists the language across reload', async ({ page }) => {
    await page.goto('/');

    await page.click('#settings-btn');
    await page.fill('#set-lang', 'TEST');
    await page.click('#set-lang-apply');

    const heading = page.locator('h1[data-i18n]');
    await expect(heading).toHaveText(/^TEST·/);

    // The stubbed SLM remains available after reload (addInitScript re-runs
    // on every navigation), but boot() must apply the cached translation
    // map from localStorage without reopening settings or calling
    // translate() again — either way, the heading should read as translated.
    await page.reload();

    await expect(heading).toHaveText(/^TEST·/);
  });

});
