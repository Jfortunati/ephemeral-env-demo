import { test, expect } from '@playwright/test';

test('page loads and shows the checklist title', async ({ page }) => {
  await page.goto('/');
  await expect(page.getByTestId('page-title')).toHaveText('Release Checklist');
});

test('banner shows the expected pull request', async ({ page }) => {
  const expectedPr = process.env.EXPECTED_PR;
  test.skip(!expectedPr, 'EXPECTED_PR is not set');

  await page.goto('/');
  await expect(page.getByTestId('env-pr')).toHaveText(expectedPr!);
});

test('adding an item shows it in the list', async ({ page }) => {
  const title = `Smoke test ${Date.now()}`;

  await page.goto('/');
  await page.getByTestId('new-item-input').fill(title);
  await page.getByTestId('add-item-button').click();

  await expect(page.getByTestId('item-list')).toContainText(title);
});

test('ticking an item marks it done', async ({ page }) => {
  const title = `Tick test ${Date.now()}`;

  await page.goto('/');
  await page.getByTestId('new-item-input').fill(title);
  await page.getByTestId('add-item-button').click();

  const item = page.getByTestId('item-list').locator('li', { hasText: title });
  await item.getByRole('checkbox').check();

  await expect(item).toHaveClass(/done/);
});

test('health endpoint returns ok', async ({ request }) => {
  const response = await request.get('/healthz');
  expect(response.ok()).toBeTruthy();
  expect(await response.json()).toEqual({ status: 'ok' });
});
