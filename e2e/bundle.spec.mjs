import { execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { expect, test } from '@playwright/test';
import { CDN, PICORUBY_WASM, SITE, serve } from './server.mjs';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const FIXTURE = join(ROOT, 'e2e', 'fixtures', 'bundle');

test('a script bundled by `picoruby-libs bundle` runs as text/ruby without the loader', async ({ page }) => {
  const out = mkdtempSync(join(tmpdir(), 'picoruby-libs-e2e-'));
  try {
    execFileSync('ruby', [
      join(ROOT, 'bin', 'picoruby-libs'), 'bundle', join(FIXTURE, 'app.rb'),
      '--importmap', join(FIXTURE, 'importmap.json'),
      '--cdn', pathToFileURL(join(ROOT, 'e2e', 'fixtures', 'npm')).href + '/',
      '--no-lockfile',
      '-o', join(out, 'app.bundle.rb'),
    ]);
    const bundled = readFileSync(join(out, 'app.bundle.rb'));

    const logs = [];
    const errors = [];
    const requests = [];
    page.on('console', (msg) => {
      if (msg.type() === 'error') errors.push(msg.text());
      else if (msg.text().startsWith('E2E ')) logs.push(msg.text().slice(4));
    });
    page.on('pageerror', (err) => errors.push(err.message));
    page.on('request', (req) => requests.push(req.url()));
    await serve(page);
    await page.route(`${SITE}/app.bundle.rb`, (route) => route.fulfill({ contentType: 'text/plain', body: bundled }));
    await page.goto(`${SITE}/bundle.html`);

    const expected = ['greet: HELLO, BUNDLE! (greeter 1.0.0)', 'await: after a Promise', 'done'];
    try {
      await expect.poll(() => expected.filter((line) => !logs.includes(line)), { timeout: 30_000 }).toEqual([]);
    } catch (err) {
      err.message += `\nPicoRuby printed ${JSON.stringify(logs)}; errors: ${JSON.stringify(errors)}`;
      throw err;
    }
    expect(errors).toEqual([]);
    // Only the page, the bundle and PicoRuby.wasm itself: no loader, no CDN.
    expect(requests.filter((url) => !url.startsWith(PICORUBY_WASM))).toEqual([
      `${SITE}/bundle.html`,
      `${SITE}/app.bundle.rb`,
    ]);
    expect(requests.some((url) => url.startsWith(CDN))).toBe(false);
  } finally {
    rmSync(out, { recursive: true, force: true });
  }
});
