import { defineConfig } from '@playwright/test';

export default defineConfig({
  testDir: './tests',
  workers: 1,
  timeout: 60_000,
  use: { baseURL: 'http://127.0.0.1:4000', viewport: { width: 1440, height: 1000 }, trace: 'retain-on-failure' },
});
