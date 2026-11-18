// Serves the E2E pages to the browser without a server: Playwright routes
//
//   http://picoruby-libs.test/loader.rb  -> loader.rb in this repository
//   http://picoruby-libs.test/<path>     -> e2e/fixtures/site/<path>
//   https://cdn.picoruby-libs.test/npm/  -> e2e/fixtures/npm/ (a fake npm CDN)
//
// and PicoRuby.wasm itself comes from jsDelivr, at PICORUBY_WASM_VERSION
// (default: the version the tests are pinned to).

import { readFile } from 'node:fs/promises';
import { dirname, extname, join, normalize } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const FIXTURES = join(ROOT, 'e2e', 'fixtures');

export const SITE = 'http://picoruby-libs.test';
export const CDN = 'https://cdn.picoruby-libs.test/npm/';
export const PINNED_PICORUBY_WASM = '4.0.5';
export const PICORUBY_WASM_VERSION = process.env.PICORUBY_WASM_VERSION || PINNED_PICORUBY_WASM;
export const PICORUBY_WASM = `https://cdn.jsdelivr.net/npm/@picoruby/wasm-wasi@${PICORUBY_WASM_VERSION}/dist`;

const TYPES = {
  '.html': 'text/html',
  '.rb': 'text/plain',
  '.json': 'application/json',
};

async function serveFile(route, dir, path, transform = (body) => body) {
  const file = normalize(join(dir, decodeURIComponent(path)));
  if (!file.startsWith(dir + '/')) return route.fulfill({ status: 403 });
  let body;
  try {
    body = await readFile(file);
  } catch {
    return route.fulfill({ status: 404, body: 'not found' });
  }
  const type = TYPES[extname(file)] || 'application/octet-stream';
  return route.fulfill({ status: 200, contentType: type, body: transform(body) });
}

export async function serve(page) {
  await page.route(`${SITE}/**`, (route) => {
    const path = new URL(route.request().url()).pathname;
    if (path === '/loader.rb') return serveFile(route, ROOT, 'loader.rb');
    return serveFile(route, join(FIXTURES, 'site'), path.slice(1), (body) =>
      path.endsWith('.html')
        ? body.toString('utf8').replaceAll('{{PICORUBY_WASM}}', PICORUBY_WASM)
        : body,
    );
  });
  await page.route(`${CDN}**`, (route) => {
    const path = new URL(route.request().url()).pathname.replace(/^\/npm\//, '');
    return serveFile(route, join(FIXTURES, 'npm'), path);
  });
}
