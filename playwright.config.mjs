import { defineConfig, devices } from '@playwright/test';

// End-to-end tests: real PicoRuby.wasm in headless Chromium. See e2e/README.md.
export default defineConfig({
  testDir: 'e2e',
  timeout: 60_000,
  retries: process.env.CI ? 1 : 0,
  reporter: process.env.CI ? [['list'], ['github']] : 'list',
  use: { ...devices['Desktop Chrome'] },
});
