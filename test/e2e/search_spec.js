// @ts-check
const { test, expect } = require('@playwright/test');

/**
 * Full-stack end-to-end tests for EmergenceSystem.
 *
 * Prerequisites (must all be running before executing these tests):
 *   1. em_disco          — gossip port 9100
 *   2. em_filter_example — gossip port 9200, query port 9201
 *   3. emquest           — HTTP port 8079, gossip port 9300
 *
 * em_filter_example corpus: integers 1–20 with one arithmetic property each.
 * Labels have no URL — they render as generic cards in emquest.
 *
 * Start all three:
 *   em_disco/:         rebar3 shell
 *   em_filter_example: rebar3 shell
 *   emquest/:          rebar3 shell
 * Then: cd emquest/test/e2e && npm install && npx playwright test
 */

test.describe('EmergenceSystem full-stack search', () => {

  test('query "1" returns numbers whose label contains "1"', async ({ page }) => {
    await page.goto('/');

    // Verify empty state before search
    await expect(page.locator('#empty-state')).toBeVisible();

    // Submit the digit query
    await page.fill('#query-input', '1');
    await page.click('#send-btn');

    // Wait for at least one result card
    const firstCard = page.locator('#results-list .item-card').first();
    await firstCard.waitFor({ state: 'visible', timeout: 30_000 });

    // Generic number cards use .item-title for the label
    const labels = await page.locator('#results-list .item-title').allTextContents();
    expect(labels.length, 'Expected at least one result').toBeGreaterThan(0);

    // At least one label must contain the digit "1"
    const hasOne = labels.some(l => l.includes('1'));
    expect(hasOne, `Expected a label with "1" but got: ${labels.join(', ')}`).toBe(true);
  });

  test('query "7" returns numbers whose label contains "7"', async ({ page }) => {
    await page.goto('/');

    await expect(page.locator('#empty-state')).toBeVisible();

    await page.fill('#query-input', '7');
    await page.click('#send-btn');

    const firstCard = page.locator('#results-list .item-card').first();
    await firstCard.waitFor({ state: 'visible', timeout: 30_000 });

    const labels = await page.locator('#results-list .item-title').allTextContents();
    expect(labels.length).toBeGreaterThan(0);

    const has7 = labels.some(l => l.includes('7'));
    expect(has7, `Expected a label with "7" but got: ${labels.join(', ')}`).toBe(true);
  });

});
