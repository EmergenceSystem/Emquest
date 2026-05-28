// @ts-check
const { test, expect } = require('@playwright/test');

/**
 * Full-stack end-to-end tests for EmergenceSystem.
 *
 * Prerequisites (must all be running before executing these tests):
 *   1. em_disco          — gossip port 9100, query port 9101
 *   2. em_filter_example — gossip port 9200, query port 9201
 *   3. emquest           — HTTP port 8079,   gossip port 9300
 *
 * em_pop gossip propagates within ~5 s of startup, so emquest discovers
 * em_filter_example through em_disco before the first test runs.
 *
 * Start all three:
 *   em_disco/:         rebar3 shell
 *   em_filter_example: rebar3 shell
 *   emquest/:          rebar3 shell
 * Then: cd emquest/test/e2e && npm install && npx playwright test
 */

test.describe('EmergenceSystem full-stack search', () => {

  test('query "erlang" returns at least one Erlang-related result', async ({ page }) => {
    await page.goto('/');

    // Verify page loads (empty state is visible)
    await expect(page.locator('#empty-state')).toBeVisible();

    // Submit search
    await page.fill('#query-input', 'erlang');
    await page.click('#send-btn');

    // Wait for at least one result card to appear
    const firstCard = page.locator('#results-list .item-card').first();
    await firstCard.waitFor({ state: 'visible', timeout: 30_000 });

    // Collect all visible titles
    const titles = await page.locator('#results-list .item-title').allTextContents();
    expect(titles.length).toBeGreaterThan(0);

    // At least one result must contain "Erlang" (case-insensitive)
    const hasErlang = titles.some(t => /erlang/i.test(t));
    expect(hasErlang, `Expected an Erlang result but got: ${titles.join(', ')}`).toBe(true);
  });

  test('query "emergence" returns at least one EmergenceSystem result', async ({ page }) => {
    await page.goto('/');

    await expect(page.locator('#empty-state')).toBeVisible();

    await page.fill('#query-input', 'emergence');
    await page.click('#send-btn');

    const firstCard = page.locator('#results-list .item-card').first();
    await firstCard.waitFor({ state: 'visible', timeout: 30_000 });

    const titles = await page.locator('#results-list .item-title').allTextContents();
    expect(titles.length).toBeGreaterThan(0);

    // At least one result must mention "Emergence" or "emergence"
    const hasEmergence = titles.some(t => /emergence/i.test(t));
    expect(hasEmergence, `Expected an EmergenceSystem result but got: ${titles.join(', ')}`).toBe(true);
  });

});
