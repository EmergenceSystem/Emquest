// @ts-check
const { defineConfig } = require('@playwright/test');

module.exports = defineConfig({
  testDir: '.',
  testMatch: ['**/*_spec.js'],
  timeout: 60_000,
  expect: { timeout: 30_000 },
  use: {
    baseURL: 'http://localhost:8079',
    headless: true,
  },
  reporter: [['list']],
});
