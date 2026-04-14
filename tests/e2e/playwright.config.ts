// ============================================================================
// tests/e2e/playwright.config.ts
//
// Stack-agnostic Playwright config. Everything configurable comes from
// environment variables so the same file runs against any preview URL
// with any auth header scheme. See tests/e2e/specs/smoke.spec.ts for the
// contract endpoints the default specs probe.
// ============================================================================

import { defineConfig, devices } from '@playwright/test';

const baseURL = process.env.BASE_URL ?? 'https://preview.example.internal';
const isCI    = !!process.env.CI;

const extraHTTPHeaders: Record<string, string> = process.env.EXTRA_HTTP_HEADERS
  ? JSON.parse(process.env.EXTRA_HTTP_HEADERS)
  : {};

export default defineConfig({
  testDir: './specs',
  fullyParallel: true,
  forbidOnly: isCI,
  retries: isCI ? 1 : 0,
  workers: isCI ? 2 : undefined,
  timeout: 60_000,
  expect: { timeout: 10_000 },
  reporter: [
    ['line'],
    ['html', { open: 'never', outputFolder: 'playwright-report' }],
    ['junit', { outputFile: 'test-results/junit.xml' }],
  ],
  use: {
    baseURL,
    trace: 'retain-on-failure',
    screenshot: 'only-on-failure',
    video: 'retain-on-failure',
    extraHTTPHeaders,
    ignoreHTTPSErrors: !isCI,
  },
  projects: [
    { name: 'chromium', use: { ...devices['Desktop Chrome'] } },
  ],
});
