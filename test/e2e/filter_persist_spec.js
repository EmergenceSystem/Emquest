// @ts-check
const { test, expect } = require('@playwright/test');

/**
 * Per-conversation media-type filter persistence (chat UI).
 *
 * Each search is a conversation in the sidebar; the media-type checkboxes are
 * saved per conversation, so reopening a search restores exactly the boxes it
 * used — independently of any other conversation's choice.
 *
 * Prerequisites: emquest on :8079 (a running mesh is not required — a
 * conversation is created and saved on submit even with zero results).
 */
test.describe('per-conversation media filter', () => {

  test('reopening a search restores its own media-type checkboxes', async ({ page }) => {
    await page.goto('/');
    await expect(page.locator('#empty-state')).toBeVisible();

    const image = page.locator('#type-filters input[value="image"]');
    const text  = page.locator('#type-filters input[value="text"]');

    // Conversation A: image OFF, then search "alpha".
    await image.uncheck();
    await page.fill('#query-input', 'alpha');
    await page.click('#send-btn');
    const alpha = page.locator('#conv-list .conv', { hasText: 'alpha' });
    await alpha.waitFor({ state: 'visible', timeout: 30_000 });

    // Conversation B: start fresh, image ON, then search "beta".
    await page.click('#new-search-btn');
    await image.check();
    await page.fill('#query-input', 'beta');
    await page.click('#send-btn');
    const beta = page.locator('#conv-list .conv', { hasText: 'beta' });
    await beta.waitFor({ state: 'visible', timeout: 30_000 });

    // Reopen A → image restored OFF (A's own choice, not B's).
    await alpha.click();
    await expect(image).not.toBeChecked();
    await expect(text).toBeChecked();

    // Reopen B → image restored ON.
    await beta.click();
    await expect(image).toBeChecked();
  });

  test('toggling a checkbox does not re-filter cards already on screen', async ({ page }) => {
    await page.goto('/');
    await page.fill('#query-input', 'mesh');
    await page.click('#send-btn');

    // Wait until the current turn has rendered at least one card OR finished.
    const cards = page.locator('#flux-inner .turn:last-child .item-card');
    await page.waitForTimeout(14_000);
    const total = await cards.count();
    test.skip(total === 0, 'no results from the mesh — nothing to filter');

    const hiddenBefore = await page.locator('#flux-inner .turn:last-child .item-card.type-hidden').count();
    // Toggle image off AFTER results: must not hide anything now.
    await page.locator('#type-filters input[value="image"]').uncheck();
    await page.waitForTimeout(300);
    const hiddenAfter = await page.locator('#flux-inner .turn:last-child .item-card.type-hidden').count();
    expect(hiddenAfter).toBe(hiddenBefore);
  });
});
