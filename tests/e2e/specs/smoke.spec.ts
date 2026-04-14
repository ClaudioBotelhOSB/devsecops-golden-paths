// ============================================================================
// tests/e2e/specs/smoke.spec.ts
//
// Stack-agnostic preview smoke. The only assumption is: the workload under
// test exposes a health endpoint and a readiness endpoint at HTTP paths
// that the user supplies via environment variables. Everything else is
// optional and driven by env.
//
// Configuration (all optional):
//   HEALTH_ENDPOINT        default '/healthz'
//   READINESS_ENDPOINT     default '/readyz'
//   SMOKE_API_PATH         default '/'
//   SMOKE_API_METHOD       default 'GET' (GET|POST)
//   SMOKE_API_BODY         JSON string for POST, default {}
//   UI_SMOKE_ENABLED       default 'false'
//   UI_SMOKE_PATH          default '/'
// ============================================================================

import { test, expect } from '@playwright/test';

const healthPath    = process.env.HEALTH_ENDPOINT    ?? '/healthz';
const readinessPath = process.env.READINESS_ENDPOINT ?? '/readyz';
const smokeApiPath  = process.env.SMOKE_API_PATH     ?? '/';
const smokeApiMethod = (process.env.SMOKE_API_METHOD ?? 'GET').toUpperCase();
const smokeApiBody  = process.env.SMOKE_API_BODY
  ? JSON.parse(process.env.SMOKE_API_BODY)
  : undefined;
const uiSmokePath    = process.env.UI_SMOKE_PATH ?? '/';
const uiSmokeEnabled = process.env.UI_SMOKE_ENABLED === 'true';

test('health endpoint responds', async ({ request }) => {
  const res = await request.get(healthPath);
  expect(res.status()).toBeLessThan(400);
});

test('readiness endpoint responds', async ({ request }) => {
  const res = await request.get(readinessPath);
  expect(res.status()).toBeLessThan(400);
});

test('configured API contract responds', async ({ request }) => {
  const res = smokeApiMethod === 'POST'
    ? await request.post(smokeApiPath, { data: smokeApiBody ?? {} })
    : await request.get(smokeApiPath);

  expect(res.status()).toBeLessThan(400);
});

test('configured UI path loads', async ({ page }) => {
  test.skip(!uiSmokeEnabled, 'UI smoke disabled for this service');
  await page.goto(uiSmokePath);
  await expect(page.locator('body')).toBeVisible();
});
