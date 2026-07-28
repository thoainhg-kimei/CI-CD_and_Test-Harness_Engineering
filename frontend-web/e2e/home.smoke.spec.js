import { test, expect } from '@playwright/test';

test('homepage smoke test', async ({ page }) => {
  await page.goto('/');
  await expect(page.locator('body')).toBeVisible();
});

test('login page smoke test', async ({ page }) => {
  await page.goto('/login');
  await expect(page.locator('form')).toBeVisible();
  await expect(page.locator('form input')).toHaveCount(2);
  await expect(page.getByRole('button', { name: 'Sign In' })).toBeVisible();
});
